"""Bounded checks of the deployed app, separate from Terraform completion.

Probe the VM's private address directly: a Cloudflare URL could still serve the old VM.
Only the configured readiness endpoint's HTTP 200 is evidence; redirects never count.
"""

import ipaddress
from http.client import HTTPException
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class AppChecker:
    def __init__(self, config=None, node_checker=None):
        self.node_checker = node_checker
        config = config or {}
        self.deadline = max(0, min(float(config.get("deadlineSeconds", 180)), 900))
        self.interval = max(0.01, min(float(config.get("intervalSeconds", 5)), 30))
        self.timeout = max(0.01, min(float(config.get("requestTimeoutSeconds", 3)), 10))
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def check_onprem(self, handoff, binding):
        if not binding:
            return {"status": "NOT_CONFIGURED", "observedAt": now(), "reason": "No app binding configured"}
        result = self.check(
            {"compute": {"private_ip": handoff["compute"]["privateAddress"]}},
            {"port": binding["port"], "health_path": binding["healthPath"]},
            expected_identity=binding["expectedServedBy"],
            allow_loopback=handoff.get("network", {}).get("scope") == "LOCAL_ONLY")
        result["probeScope"] = "LOCAL_ONLY" if handoff.get("network", {}).get("scope") == "LOCAL_ONLY" else "MANAGEMENT_TO_TARGET"
        result["hostId"] = binding["hostId"]
        return result

    def check(self, handoff, app, *, expected_identity=None, allow_loopback=False):
        if not app:
            return {"status": "NOT_CONFIGURED", "observedAt": now(), "reason": "No app image configured"}
        if (handoff.get("compute") or {}).get("runtime") == "ON_PREM" and self.node_checker:
            return self.node_checker(handoff)
        try:
            host = ipaddress.ip_address(handoff["compute"]["private_ip"])
            if (host.is_loopback and not allow_loopback) or host.is_link_local or host.is_unspecified or host.version != 4:
                raise ValueError("invalid target")
            port = app.get("port", 80)
            path = app.get("health_path", "/readyz")
            if not isinstance(port, int) or not 1 <= port <= 65535 or not path.startswith("/") or path.startswith("//"):
                raise ValueError("invalid readiness endpoint")
        except (KeyError, ValueError, TypeError):
            return {"status": "UNKNOWN", "observedAt": now(), "reason": "Missing or invalid VM readiness endpoint"}
        url = f"http://{host}:{port}{path}"
        started, end, attempts = now(), time.monotonic() + self.deadline, 0
        last_success = None
        while True:
            attempts += 1
            result = {"status": "NOT_READY", "startedAt": started, "observedAt": now(),
                      "url": url, "attempts": attempts, "httpStatus": None, "lastSuccessAt": last_success,
                      "scope": "APP_HTTP_READINESS"}
            try:
                req = Request(url, headers={"Cache-Control": "no-cache, no-store"})
                with self.opener.open(req, timeout=min(self.timeout, max(0.01, end - time.monotonic()))) as response:
                    result["httpStatus"] = response.status
                    result["status"] = "READY" if response.status == 200 else "NOT_READY"
                    result["reason"] = None if response.status == 200 else "Unexpected HTTP status"
                    if expected_identity is not None and response.getheader("X-Served-By") != expected_identity:
                        result.update(status="NOT_READY", reason="Target app identity did not match the registered binding")
            except HTTPError as exc:
                result.update(httpStatus=exc.code, reason="Unexpected HTTP status")
                exc.close()
            except (URLError, OSError, TimeoutError, HTTPException):
                result["reason"] = "App endpoint unreachable or timed out"
            result["observedAt"] = now()
            if result["status"] == "READY":
                result["lastSuccessAt"] = result["observedAt"]
                return result
            if time.monotonic() >= end:
                return result
            time.sleep(min(self.interval, max(0, end - time.monotonic())))
