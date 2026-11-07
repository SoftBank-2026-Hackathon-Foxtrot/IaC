"""Environment lifecycle: accept a request, then plan → apply (or destroy) in one background worker.

Status of an environment:
  PLANNING → PLANNED (mode=plan, waiting for /apply) → APPLYING → READY
  any step can end in FAILED; a job cut off by a restart ends in NEEDS_RECONCILIATION
  READY/PLANNED/FAILED → DESTROYING → DESTROYED

Jobs run one at a time. Terraform holds the state lock, and one worker keeps the cloud calls
and the log readable; environment creation takes minutes either way."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import secrets
import threading
import uuid

from . import spec
from .store import Store
from .terraform import Terraform, TerraformError


class Conflict(Exception):
    """409 with a machine-readable code."""

    def __init__(self, code: str, message: str, **extra):
        super().__init__(message)
        self.code, self.extra = code, extra


class NotFound(Exception):
    pass


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


class Service:
    def __init__(self, store: Store, terraform: Terraform, catalog: dict, config: dict):
        self.store, self.tf, self.catalog, self.config = store, terraform, catalog, config
        self.wake = threading.Event()
        self.today = lambda: dt.date.today()

    # --- requests ---------------------------------------------------------------------------
    def create(self, body: dict, idempotency_key: str | None = None) -> tuple[int, dict]:
        digest = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        if idempotency_key:
            seen = self.store.remembered(idempotency_key)
            if seen:
                if seen[0] != digest:
                    raise Conflict("IDEMPOTENCY_CONFLICT", "this Idempotency-Key was used with a different body")
                return seen[1], seen[2]
        req = spec.parse(body, self.catalog, self.config)
        existing = self.store.active_environment(req["org"]["id"], req["cloud"], req["template"])
        if existing:
            raise Conflict("ENVIRONMENT_EXISTS", "this org already has an active environment of this app on this cloud",
                           environmentId=existing["id"])
        suffix = secrets.token_hex(2)
        tfvars = spec.render(req, self.catalog, self.config, suffix, self.today())
        env_id = f"env-{uuid.uuid4().hex[:12]}"
        stamp = now()
        self.store.insert_environment({
            "id": env_id, "org_id": req["org"]["id"], "cloud": req["cloud"], "template": req["template"],
            "deployment_id": tfvars["deployment_id"], "status": "PLANNING", "request": req, "tfvars": tfvars,
            "plan": None, "handoff": None, "created_at": stamp, "updated_at": stamp})
        job = self._enqueue(env_id, "PLAN" if req["mode"] == "plan" else "PLAN_APPLY")
        response = {"environmentId": env_id, "jobId": job, "deploymentId": tfvars["deployment_id"], "status": "PLANNING"}
        if idempotency_key:
            self.store.remember(idempotency_key, digest, 202, response)
        return 202, response

    def apply(self, env_id: str) -> tuple[int, dict]:
        env = self._get(env_id)
        if env["status"] != "PLANNED":
            raise Conflict("INVALID_STATE", f"only a PLANNED environment can be applied (now {env['status']})")
        self._not_busy(env_id)
        self.store.update_environment(env_id, now(), status="APPLYING")
        return 202, {"environmentId": env_id, "jobId": self._enqueue(env_id, "APPLY"), "status": "APPLYING"}

    def update(self, env_id: str, body: dict) -> tuple[int, dict]:
        """Change a READY (or FAILED) environment in place: new app settings, sizing or access.

        The body takes the same app / sizing / access fields as creation; they are merged into the
        stored request. Org, cloud, template and target stay. Changing the app replaces the VM."""
        env = self._get(env_id)
        if env["status"] not in ("READY", "FAILED"):
            raise Conflict("INVALID_STATE", f"only a READY or FAILED environment can be updated (now {env['status']})")
        self._not_busy(env_id)
        spec.require(type(body) is dict and not (body.keys() - {"app", "sizing", "access"}), "update takes app, sizing and access only")
        stored = env["request"]
        merged = {
            "org": stored["org"], "cloud": stored["cloud"], "target": stored["target"],
            "app": {"template": stored["template"], **stored["app"], **body.get("app", {})},
            "sizing": {**stored["sizing"], **body.get("sizing", {})},
            "access": {**stored["access"], **body.get("access", {})},
        }
        req = spec.parse(merged, self.catalog, self.config)
        suffix = env["deployment_id"].rsplit("-", 1)[1]  # keep the same resources
        tfvars = spec.render(req, self.catalog, self.config, suffix, self.today())
        tfvars["final_snapshot_identifier"] = env["tfvars"].get("final_snapshot_identifier", tfvars.get("final_snapshot_identifier"))
        tfvars["metadata"] = env["tfvars"]["metadata"]  # tags stay as created
        self.store.update_environment(env_id, now(), request=req, tfvars=tfvars, status="PLANNING", error=None)
        return 202, {"environmentId": env_id, "jobId": self._enqueue(env_id, "PLAN_APPLY"), "status": "PLANNING"}

    def destroy(self, env_id: str) -> tuple[int, dict]:
        env = self._get(env_id)
        if env["status"] in ("DESTROYED", "DESTROYING"):
            return 200, self.view(env)
        if env["status"] == "NEEDS_RECONCILIATION":
            raise Conflict("NEEDS_RECONCILIATION", "a job was cut off; check the cloud and the state before destroying")
        self._not_busy(env_id)
        self.store.update_environment(env_id, now(), status="DESTROYING")
        return 202, {"environmentId": env_id, "jobId": self._enqueue(env_id, "DESTROY"), "status": "DESTROYING"}

    def view(self, env: dict) -> dict:
        handoff = env["handoff"] or {}
        return {
            "environmentId": env["id"], "org": env["request"]["org"], "cloud": env["cloud"], "template": env["template"],
            "deploymentId": env["deployment_id"], "status": env["status"], "error": env["error"],
            "plan": env["plan"], "appUrl": handoff.get("app", {}).get("url"), "handoff": env["handoff"],
            "createdAt": env["created_at"], "updatedAt": env["updated_at"],
        }

    def get(self, env_id: str) -> dict:
        return self.view(self._get(env_id))

    def job(self, job_id: str) -> dict:
        job = self.store.job(job_id)
        if not job:
            raise NotFound(job_id)
        env = self.store.environment(job["environment_id"])
        log = self.tf.log_path(env["id"])
        tail = log.read_text()[-4000:] if log.exists() else ""
        return {"jobId": job["id"], "environmentId": job["environment_id"], "kind": job["kind"], "status": job["status"],
                "error": job["error"], "createdAt": job["created_at"], "startedAt": job["started_at"],
                "finishedAt": job["finished_at"], "logTail": tail}

    # --- worker -----------------------------------------------------------------------------
    def recover(self) -> None:
        """A job that was running when the process stopped may have changed the cloud halfway."""
        for job in self.store.interrupted():
            self.store.update_job(job["id"], status="NEEDS_RECONCILIATION", finished_at=now(),
                                  error="process stopped while the job was running")
            self.store.update_environment(job["environment_id"], now(), status="NEEDS_RECONCILIATION",
                                          error="process stopped while a job was running")

    def run_forever(self, stop: threading.Event) -> None:
        while not stop.is_set():
            if not self.run_next():
                self.wake.wait(2)
                self.wake.clear()

    def run_next(self) -> bool:
        job = self.store.next_queued()
        if not job:
            return False
        self.execute(job)
        return True

    def execute(self, job: dict) -> None:
        env = self.store.environment(job["environment_id"])
        cloud, env_id = env["cloud"], env["id"]
        self.store.update_job(job["id"], status="RUNNING", started_at=now())
        try:
            if job["kind"] in ("PLAN", "PLAN_APPLY"):
                plan = self.tf.plan(env_id, cloud, env["tfvars"])
                self.store.update_environment(env_id, now(), plan=plan, status="PLANNED" if job["kind"] == "PLAN" else "APPLYING")
            if job["kind"] in ("APPLY", "PLAN_APPLY"):
                handoff = self.tf.apply(env_id, cloud, "reviewed.tfplan")
                self.store.update_environment(env_id, now(), handoff=handoff, status="READY", error=None)
            if job["kind"] == "DESTROY":
                plan = self.tf.plan(env_id, cloud, env["tfvars"], destroy=True)
                self.tf.apply(env_id, cloud, plan["plan"])
                self.store.update_environment(env_id, now(), status="DESTROYED", handoff=None, error=None)
        except (TerraformError, OSError, ValueError) as exc:
            message = str(exc)[-2000:]
            self.store.update_job(job["id"], status="FAILED", error=message, finished_at=now())
            self.store.update_environment(env_id, now(), status="FAILED", error=message)
            return
        self.store.update_job(job["id"], status="SUCCEEDED", finished_at=now())

    # --- helpers ----------------------------------------------------------------------------
    def _enqueue(self, env_id: str, kind: str) -> str:
        job_id = f"job-{uuid.uuid4().hex[:12]}"
        self.store.insert_job({"id": job_id, "environment_id": env_id, "kind": kind, "status": "QUEUED", "created_at": now()})
        self.wake.set()
        return job_id

    def _get(self, env_id: str) -> dict:
        env = self.store.environment(env_id)
        if not env:
            raise NotFound(env_id)
        return env

    def _not_busy(self, env_id: str) -> None:
        if self.store.busy(env_id):
            raise Conflict("RESOURCE_BUSY", "a job for this environment is still queued or running")
