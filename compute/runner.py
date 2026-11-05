"""Run the COMPUTE preparation steps on a registered target VM, using local Docker."""
import argparse
import hashlib
import http.client
import json
import re
import subprocess
import sys
import time
from pathlib import Path


def docker(*args, timeout=30):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Docker errors can include part of the deployment configuration.
        raise RuntimeError(f"Docker {args[0]} failed. Inspect the target VM before retrying.")
    return result.stdout.strip()


def load_binding(path):
    binding = json.loads(path.read_text(encoding="utf-8-sig"))
    required = {"targetRef", "imageId", "configVersion", "envFile", "command", "port", "readinessPath"}
    if not isinstance(binding, dict) or binding.keys() != required:
        raise ValueError("Use the registered target binding fields from binding.example.json")
    if not re.fullmatch(r"resource:[a-z0-9][a-z0-9-]{0,62}", binding["targetRef"]):
        raise ValueError("Invalid targetRef")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", binding["imageId"]):
        raise ValueError("Expected a full Docker image ID from the source")
    if not binding["configVersion"] or not isinstance(binding["configVersion"], str):
        raise ValueError("Pin an immutable configuration version")
    if not isinstance(binding["command"], list) or not all(isinstance(v, str) and v for v in binding["command"]):
        raise ValueError("command must be an argument list")
    if type(binding["port"]) is not int or not 1 <= binding["port"] <= 65535:
        raise ValueError("Invalid app port")
    if not re.fullmatch(r"/[A-Za-z0-9/_.-]*", binding["readinessPath"]):
        raise ValueError("Invalid readiness path")
    env_file = (path.parent / binding["envFile"]).resolve(strict=True)
    if not env_file.is_file():
        raise ValueError("Missing registered environment file")
    return binding, env_file


def observe_web(container, binding):
    mapping = docker("port", container, f'{binding["port"]}/tcp')
    match = re.fullmatch(r"127\.0\.0\.1:(\d+)", mapping)
    if not match:
        raise RuntimeError("Expected a VM-local probe port")
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        conn = http.client.HTTPConnection("127.0.0.1", int(match[1]), timeout=2)
        try:
            conn.request("GET", binding["readinessPath"])
            if conn.getresponse().status == 200:
                return
        except (OSError, http.client.HTTPException):
            pass
        finally:
            conn.close()
        time.sleep(1)
    raise RuntimeError("Web readiness timed out. Container retained for inspection.")


def execute(action, path, target_ref):
    if action not in ("PREPARE", "START_SYNC"):
        raise ValueError("Unsupported COMPUTE action")
    binding, env_file = load_binding(path)
    if binding["targetRef"] != target_ref:
        raise ValueError("Plan targetRef differs from the registered VM binding")
    image = binding["imageId"]
    if docker("image", "inspect", "--format", "{{.Id}}", image) != image:
        raise ValueError("Source image is missing on the target")
    result = {"targetRef": target_ref, "imageId": image, "configVersion": binding["configVersion"]}
    if action == "PREPARE":
        return {**result, "check": "local-image-and-config-present"}

    # configVersion covers secret versions. Keep the contents of envFile off the wire.
    revision = hashlib.sha256(json.dumps(binding, sort_keys=True).encode()).hexdigest()
    name = "foxtrot-stage-" + target_ref.removeprefix("resource:")
    existing = docker("ps", "-aq", "--no-trunc", "--filter", f"name=^/{name}$")
    if existing:
        owner = docker("inspect", "--format", '{{index .Config.Labels "foxtrot.stage.revision"}}', existing)
        if owner != revision or docker("inspect", "--format", "{{.Image}}", existing) != image:
            raise RuntimeError("Target already has another container. Reconcile the deployment.")
        container = existing
    else:
        container = docker("create", "--pull=never", "--name", name,
                           "--label", f"foxtrot.stage.revision={revision}",
                           "--env-file", str(env_file), "--publish", f'127.0.0.1::{binding["port"]}',
                           image, *binding["command"])
    state = docker("inspect", "--format", "{{.State.Status}}", container)
    if state == "created":
        docker("start", container)
    elif state != "running":
        raise RuntimeError(f"Container is {state}. Inspect it before retrying.")
    observe_web(container, binding)
    return {**result, "containerId": container, "check": "target-web-probe-passed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["PREPARE", "START_SYNC"])
    parser.add_argument("--target-ref", required=True)
    parser.add_argument("--binding", required=True, type=Path, help="Operator-owned local binding file")
    args = parser.parse_args()
    try:
        print(json.dumps(execute(args.action, args.binding, args.target_ref)))
    except (OSError, ValueError, TypeError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(str(exc) if not isinstance(exc, subprocess.TimeoutExpired) else "Docker timed out. Reconcile the target.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
