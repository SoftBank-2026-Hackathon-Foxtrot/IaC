"""Turn an environment request (org, cloud, app) into reviewed Terraform inputs.

The request names who the environment is for and which cloud it goes to. Everything else
(network plan, sizing baseline, registry image, account/project) comes from the server's
config, so a caller cannot pick an unreviewed account, image or size. The result is checked by
the same validator the CLI uses (tools/render_inputs.py)."""

from __future__ import annotations

import copy
import datetime as dt
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import render_inputs as inputs  # noqa: E402


class RequestError(ValueError):
    """The request cannot be turned into an environment (400)."""


ORG_ID = re.compile(r"^[a-z][a-z0-9-]{1,30}[a-z0-9]$")
SUFFIX = re.compile(r"^[a-f0-9]{4}$")
APP_FIELDS = {  # request (camelCase) -> Terraform app object
    "image": "image", "apiWorkers": "api_workers", "workerCount": "worker_count", "seedDemoData": "seed_demo_data",
    "env": "env", "apiEnv": "api_env", "workerEnv": "worker_env", "secretEnv": "secret_env",
    "tunnelSecret": "tunnel_secret", "port": "port",
}
ACCESS_FIELDS = {
    "aws": {"replicationCidrs": "replication_cidrs", "proxyCidrs": "proxy_cidrs", "migrationSourceCidrs": "migration_source_cidrs",
            "cloudflareTunnel": "enable_cloudflare_tunnel", "webIngressCidrs": "web_ingress_cidrs"},
    "gcp": {"dbAuthorizedNetworks": "db_authorized_networks", "proxyCidrs": "proxy_cidrs",
            "cloudflareTunnel": "enable_cloudflare_tunnel", "webIngressCidrs": "web_ingress_cidrs"},
}


def require(condition, message):
    if not condition:
        raise RequestError(message)


def deployment_id(org_id: str, cloud: str, suffix: str) -> str:
    """Short, label-safe and unique per environment: <org up to 10>-<cloud>-<4 hex>."""
    require(SUFFIX.match(suffix) is not None, "suffix must be 4 hex characters")
    slug = org_id[:10].rstrip("-")
    return f"{slug}-{cloud}-{suffix}"


def parse(request: dict, catalog: dict, config: dict) -> dict:
    """Check the request's shape and return its normalised form (no cloud calls)."""
    require(type(request) is dict, "body must be a JSON object")
    require(not (request.keys() - {"org", "cloud", "app", "target", "sizing", "access", "mode"}), "unknown top-level field")
    org = request.get("org")
    require(type(org) is dict and type(org.get("id")) is str and ORG_ID.match(org["id"]) is not None,
            "org.id: 3-32 lowercase letters, digits or hyphens, starting with a letter")
    require(not (org.keys() - {"id", "name"}), "org: only id and name")
    cloud = request.get("cloud")
    require(cloud in config["clouds"], f"cloud: one of {sorted(config['clouds'])}")
    app = request.get("app") or {}
    require(type(app) is dict, "app must be an object")
    template = app.get("template", "chiikawa-groupbuy")
    require(template in catalog["templates"], f"app.template: one of {sorted(catalog['templates'])}")
    require(not (app.keys() - set(APP_FIELDS) - {"template"}), "app: unknown field")
    mode = request.get("mode", "apply")
    require(mode in ("apply", "plan"), "mode: apply or plan")
    for field in ("target", "sizing", "access"):
        require(type(request.get(field, {})) is dict, f"{field} must be an object")
    require(not (request.get("access", {}).keys() - ACCESS_FIELDS[cloud].keys()), f"access: allowed fields for {cloud} are {sorted(ACCESS_FIELDS[cloud])}")
    return {"org": {"id": org["id"], "name": org.get("name", org["id"])}, "cloud": cloud, "template": template,
            "app": {k: v for k, v in app.items() if k != "template"}, "target": request.get("target", {}),
            "sizing": request.get("sizing", {}), "access": request.get("access", {}), "mode": mode}


def render(req: dict, catalog: dict, config: dict, suffix: str, today: dt.date) -> dict:
    """Terraform inputs for this request. Raises RequestError on anything not allowed."""
    cloud, cloud_conf = req["cloud"], config["clouds"][req["cloud"]]
    template = catalog["templates"][req["template"]]
    dep = deployment_id(req["org"]["id"], cloud, suffix)

    app = copy.deepcopy(template.get("app", {}))
    image = req["app"].get("image") or cloud_conf.get("images", {}).get(req["template"])
    require(image is not None, f"no {cloud} image configured for {req['template']}; pass app.image")
    allowed_prefixes = cloud_conf.get("imagePrefixes")
    if req["app"].get("image") and allowed_prefixes:
        require(any(image.startswith(p) for p in allowed_prefixes), "app.image: registry repository is not allowed")
    port = req["app"].get("port", app.get("port", 80))
    require(type(port) is int and 1 <= port <= 65535, "app.port: an integer port")
    for key, value in req["app"].items():
        app[APP_FIELDS[key]] = value
    app["image"] = image

    tfvars = copy.deepcopy(cloud_conf["baseline"])
    target = req["target"]
    region = target.get("region", cloud_conf["region"])
    require(region in cloud_conf.get("regions", [cloud_conf["region"]]), "target.region is not allowed")
    if cloud == "aws":
        account = target.get("accountId", cloud_conf["accounts"][0])
        require(account in cloud_conf["accounts"], "target.accountId is not allowed")
        require(not (target.keys() - {"accountId", "region"}), "target: accountId and region only")
        tfvars.update(account_id=account, final_snapshot_identifier=f"{dep}-final")
        if region != cloud_conf["region"]:
            tfvars["network"]["availability_zones"] = [f"{region}a", f"{region}c"]
    else:
        project = target.get("projectId", cloud_conf["projects"][0])
        require(project in cloud_conf["projects"], "target.projectId is not allowed")
        require(not (target.keys() - {"projectId", "region", "zone"}), "target: projectId, region and zone only")
        zone = target.get("zone", cloud_conf["zone"] if region == cloud_conf["region"] else f"{region}-a")
        tfvars.update(project_id=project, zone=zone)
    tfvars.update(
        deployment_id=dep,
        region=region,
        bucket_name=f"foxtrot-{dep}",
        database_name="app",
        deletion_protection=config.get("deletionProtection", False),
        force_destroy_storage=config.get("forceDestroyStorage", True),
        metadata={
            "project": "foxtrot", "environment": "poc", "owner": req["org"]["id"][:63],
            "cost_center": req["org"]["id"][:63], "workload": req["template"][:63], "migration_id": "none",
            "data_class": "internal", "expires_on": (today + dt.timedelta(days=config.get("expiresInDays", 30))).isoformat(),
        },
        app=app,
    )
    for key, field in ACCESS_FIELDS[cloud].items():
        if key in req["access"]:
            tfvars[field] = req["access"][key]
    try:
        if req["sizing"]:
            return inputs.merge_overrides(cloud, tfvars, req["sizing"])
        inputs.validate_config(cloud, tfvars)
    except ValueError as exc:
        raise RequestError(str(exc)) from exc
    return tfvars
