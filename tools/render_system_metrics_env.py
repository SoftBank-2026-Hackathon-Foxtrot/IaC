"""Print non-secret OTEL env for an explicitly registered existing app. No cloud writes."""

import argparse
import re
from pathlib import Path
from urllib.parse import urlsplit

import yaml


def render(seed, environment_id, endpoint, role, network_scope):
    address = urlsplit(endpoint)
    if (
        address.scheme not in {"http", "https"}
        or not address.hostname
        or address.username
        or address.password
        or address.query
        or address.fragment
        or any(char.isspace() for char in endpoint)
    ):
        raise ValueError("Use an OTLP HTTP base URL without credentials or query")
    if role not in {"api", "worker"} or network_scope not in {
        "container",
        "app-instance",
    }:
        raise ValueError("Invalid role or network scope")
    registrations = seed.get("systemDeployments", [])
    ids = [row["environmentId"] for row in registrations]
    identities = [
        (r["ownerId"], r["deploymentId"], r["environment"]) for r in registrations
    ]
    if len(set(ids)) != len(ids) or len(set(identities)) != len(identities):
        raise ValueError("Duplicate shared deployment registration")
    target = next(
        (row for row in registrations if row["environmentId"] == environment_id), None
    )
    if target is None:
        raise ValueError("Deployment is not registered in systemDeployments")
    if not re.fullmatch(r"env-[a-f0-9]{12}", environment_id):
        raise ValueError("Invalid environment ID")
    if target["environment"] not in seed["environments"]:
        raise ValueError("Deployment environment is absent from the seed")
    identities = {
        "OTEL_APPLICATION_ID": seed["application"],
        "OTEL_OWNER_ID": target["ownerId"],
        "OTEL_DEPLOYMENT_ID": target["deploymentId"],
        "OTEL_DEPLOYMENT_ENVIRONMENT": target["environment"],
    }
    if any(
        not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", value)
        for value in identities.values()
    ):
        raise ValueError("Invalid telemetry identity")
    return {
        **identities,
        "OTEL_SYSTEM_METRICS": "container",
        "OTEL_APP_ROLE": role,
        "OTEL_NETWORK_SCOPE": network_scope,
        "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint.rstrip("/"),
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=Path, required=True)
    parser.add_argument("--environment-id", required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--role", choices=("api", "worker"), required=True)
    parser.add_argument(
        "--network-scope", choices=("container", "app-instance"), required=True
    )
    args = parser.parse_args()
    try:
        values = render(
            yaml.safe_load(args.seed.read_text()),
            args.environment_id,
            args.endpoint,
            args.role,
            args.network_scope,
        )
    except (
        KeyError,
        ValueError,
        TypeError,
        AttributeError,
        OSError,
        yaml.YAMLError,
    ) as exc:
        parser.exit(2, f"Cannot render telemetry configuration: {exc}\n")
    print("\n".join(f"{key}={value}" for key, value in values.items()))


if __name__ == "__main__":
    main()
