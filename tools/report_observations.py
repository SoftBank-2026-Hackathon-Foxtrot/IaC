#!/usr/bin/env python3
"""Send bounded preparation evidence to the control plane. No provisioning side effects."""

import argparse
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


def timestamp(value):
    at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if at.tzinfo is None or at > datetime.now(timezone.utc):
        raise ValueError("Use the original timezone-aware measurement time")
    return at.isoformat()


def plan_counts(plan):
    # terraform show -json PLANFILE. Never forward values, sensitive outputs or addresses.
    if not plan.get("format_version") or not isinstance(plan.get("resource_changes"), list):
        raise ValueError("Expected terraform show -json output with resource_changes")
    counts = dict.fromkeys(("create", "update", "delete", "replace"), 0)
    for resource in plan["resource_changes"]:
        actions = resource["change"]["actions"]
        if "create" in actions and "delete" in actions:
            counts["replace"] += 1
        elif actions in (["create"], ["update"], ["delete"]):
            counts[actions[0]] += 1
    return counts


def infra_report(workflow, job, plan, handoff=None):
    if job.get("migration_id") != workflow or job.get("type") not in ("PLAN", "APPLY"):
        raise ValueError("Job must belong to this workflow and be PLAN or APPLY")
    if job.get("status") not in ("QUEUED", "RUNNING", "SUCCEEDED", "FAILED", "UNKNOWN"):
        raise ValueError("Unsupported job status")
    # The repository examples lack observed_at and cannot be submitted as completed work.
    observed_at = timestamp(job["observed_at"])
    data = {"workflowId": workflow, "stage": job["type"], "status": job["status"],
            "jobId": job["id"], "observedAt": observed_at, "changes": plan_counts(plan)}
    for source, target in (("requested_at", "requestedAt"), ("started_at", "startedAt"),
                           ("finished_at", "finishedAt")):
        data[target] = timestamp(job[source]) if job.get(source) else None
    if job["status"] == "SUCCEEDED" and not data["finishedAt"]:
        raise ValueError("Successful jobs require their real finished_at")
    if handoff:
        if (handoff.get("migration_id") != workflow or job["type"] != "APPLY"
                or job["status"] != "SUCCEEDED" or handoff.get("readiness") != "INFRA_APPLIED"):
            raise ValueError("Handoff requires a successful APPLY for the same workflow")
        data.update(targetRef=handoff["target"]["id"], cloud=handoff["target"]["cloud"],
                    vmId=handoff["outputs"]["compute"]["id"])
    return {"resource": "INFRA", "data": data}


def compute_report(workflow, migration):
    if migration.get("workflowId") != workflow or migration.get("kind") != "COMPUTE":
        raise ValueError("Compute migration belongs to a different workflow")
    details = migration.get("details", {}).get("compute", {})
    data = {"workflowId": workflow, "migrationId": migration["migrationId"],
            "stage": migration["lifecycle"], "status": migration["health"],
            "observedAt": timestamp(migration["observed"]["observedAt"])}
    for field in ("targetRef", "vmId", "imageId", "configVersion", "containerId", "check"):
        data[field] = details.get(field)
    fields = ("operationId", "migrationId", "action", "status", "requestedAt", "startedAt", "finishedAt")
    data["operations"] = [{key: op.get(key) for key in fields} for op in details.get("operations", [])[:20]]
    return {"resource": "COMPUTE", "data": data}


def request(url, token, body=None):
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or parsed.username or parsed.password:
        raise ValueError("Use an HTTP(S) endpoint without embedded credentials")
    req = Request(url, data=json.dumps(body).encode() if body is not None else None,
                  headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urlopen(req, timeout=10) as response:
        return json.load(response)


def load(path):
    return json.loads(Path(path).read_text()) if path else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--control-plane", required=True, help="Backend base URL, including /api if gateway requires it")
    parser.add_argument("--token-env", default="OBSERVATION_TOKEN")
    commands = parser.add_subparsers(dest="resource", required=True)
    infra = commands.add_parser("infra")
    infra.add_argument("--job-json", required=True)
    infra.add_argument("--plan-json", required=True)
    infra.add_argument("--handoff-json")
    compute = commands.add_parser("compute")
    compute.add_argument("--adapter-url", required=True)
    compute.add_argument("--migration-id", required=True)
    compute.add_argument("--adapter-token-env", default="COMPUTE_TOKEN")
    compute.add_argument("--watch", action="store_true", help="Poll every five seconds until interrupted")
    args = parser.parse_args()
    url = args.control_plane.rstrip("/") + "/internal/workflows/" + quote(args.workflow, safe="") + "/preparation"
    while True:
        if args.resource == "infra":
            report = infra_report(args.workflow, load(args.job_json), load(args.plan_json), load(args.handoff_json))
        else:
            migration = request(args.adapter_url.rstrip("/") + "/v1/migrations/" + quote(args.migration_id, safe=""),
                                os.environ[args.adapter_token_env])
            report = compute_report(args.workflow, migration)
        request(url, os.environ[args.token_env], report)
        print(f"{report['resource']} observation recorded for {args.workflow}", flush=True)
        if args.resource != "compute" or not args.watch:
            return
        time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as error:
        # Avoid echoing request headers, output files or provider error bodies.
        raise SystemExit(f"Observation report failed ({type(error).__name__}); verify inputs and connectivity") from None
