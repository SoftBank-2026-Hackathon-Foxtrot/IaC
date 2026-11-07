import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

from provisioner.readiness import AppChecker, NoRedirect
from provisioner.store import SCHEMA, Store
import test_provisioner as helpers
from test_provisioner import body


class AppCheckerTest(unittest.TestCase):
    def setUp(self):
        self.checker = AppChecker({"deadlineSeconds": 0})
        self.checker.opener = Mock()
        self.handoff = {"compute": {"private_ip": "10.20.0.10"}, "app": {"url": "https://old.example.com"}}

    def test_direct_vm_readiness_instead_of_public_load_balancer(self):
        response = Mock(status=200)
        self.checker.opener.open.return_value.__enter__ = Mock(return_value=response)
        self.checker.opener.open.return_value.__exit__ = Mock(return_value=False)
        result = self.checker.check(self.handoff, {"port": 8000, "health_path": "/readyz"})
        self.assertEqual(result["status"], "READY")
        self.assertEqual(result["url"], "http://10.20.0.10:8000/readyz")
        self.assertEqual(result["observedAt"], result["lastSuccessAt"])

    def test_errors_are_not_app_readiness(self):
        for error in [HTTPError("url", 503, "unavailable", {}, None), URLError("timeout")]:
            self.checker.opener.open.side_effect = error
            result = self.checker.check(self.handoff, {"port": 80})
            self.assertEqual(result["status"], "NOT_READY")
            self.assertEqual(result["attempts"], 1)
            self.assertIsNone(result["lastSuccessAt"])
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "https://another-host"))

    def test_no_evidence_is_unknown(self):
        self.assertEqual(self.checker.check({}, {"port": 80})["status"], "UNKNOWN")
        self.assertEqual(self.checker.check({}, None)["status"], "NOT_CONFIGURED")
        self.checker.opener.open.assert_not_called()


class ReadinessLifecycleTest(unittest.TestCase):
    setUp = helpers.ServiceTest.setUp
    tearDown = helpers.ServiceTest.tearDown
    drain = helpers.ServiceTest.drain

    def test_reporting_failure_does_not_change_successful_deployment(self):
        self.service.config = {**self.service.config, "observations": {"controlPlaneUrl": "http://cp.internal:8000"}}
        with patch.dict("os.environ", {"OBSERVATION_TOKEN": "test-secret"}), patch(
            "tools.report_observations.request", side_effect=URLError("unavailable")
        ):
            _, created = self.service.create(body(workflowId="workflow-123"))
            self.drain()
        env = self.service.get(created["environmentId"])
        self.assertEqual(env["status"], "READY")
        self.assertEqual(env["readiness"]["reporting"]["status"], "FAILED")
        self.assertNotIn("test-secret", json.dumps(env))

    def test_apply_and_app_check_are_independent_and_recheck_does_not_apply(self):
        self.service.checker = Mock()
        self.service.checker.check.return_value = {"status": "NOT_READY", "observedAt": "2026-01-01T00:00:00+00:00", "reason": "HTTP 503"}
        _, created = self.service.create(body())
        env_id = created["environmentId"]
        self.service.run_next()  # apply finishes before the separate app job
        env = self.service.get(env_id)
        self.assertEqual(env["status"], "INFRA_READY")
        self.assertEqual(env["readiness"]["infrastructure"]["status"], "READY")
        self.assertEqual(env["readiness"]["application"]["status"], "PENDING")
        self.drain()
        env = self.service.get(env_id)
        self.assertEqual(env["status"], "APP_NOT_READY")
        self.assertEqual(self.service.job(created["jobId"])["status"], "SUCCEEDED")
        applied = list(self.tf.calls)
        self.service.checker.check.return_value = {"status": "READY", "observedAt": "2026-01-01T00:00:01+00:00"}
        self.service.check_app(env_id)
        self.drain()
        self.assertEqual(self.service.get(env_id)["status"], "READY")
        self.assertEqual(self.tf.calls, applied)

    def test_recovery_during_app_check_keeps_infrastructure_evidence(self):
        _, created = self.service.create(body())
        self.service.run_next()
        job = self.service.store.next_queued()
        self.assertEqual(job["kind"], "CHECK_APP")
        self.service.store.update_job(job["id"], status="RUNNING")
        self.service.recover()
        env = self.service.get(created["environmentId"])
        self.assertEqual(env["status"], "INFRA_READY")
        self.assertEqual(env["readiness"]["infrastructure"]["status"], "READY")
        self.assertEqual(env["readiness"]["application"]["status"], "UNKNOWN")

    def test_gcp_update_does_not_add_aws_input_and_preserves_workflow(self):
        _, created = self.service.create(body(cloud="gcp", workflowId="workflow-123"))
        self.drain()
        self.service.update(created["environmentId"], {"app": {"port": 8000}})
        stored = self.service.store.environment(created["environmentId"])
        self.assertNotIn("final_snapshot_identifier", stored["tfvars"])
        self.assertEqual(stored["request"]["workflowId"], "workflow-123")

    def test_existing_environment_can_bind_workflow_without_redeployment(self):
        _, created = self.service.create(body())
        self.drain()
        calls = list(self.tf.calls)
        code, env = self.service.bind_workflow(created["environmentId"], {"workflowId": "workflow-existing"})
        self.assertEqual((code, env["workflowId"]), (200, "workflow-existing"))
        self.assertEqual(self.tf.calls, calls)


class StoreUpgradeTest(unittest.TestCase):
    def test_legacy_ready_has_no_invented_app_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "p.db"
            old = sqlite3.connect(path)
            old.executescript(SCHEMA)
            old.execute("INSERT INTO environments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        ("old", "org", "aws", "app", "dep", "READY", "{}", "{}", None, "{}", None, "then", "then"))
            old.commit()
            old.close()
            store = Store(path)
            env = store.environment("old")
            self.assertEqual(env["status"], "INFRA_READY")
            self.assertIsNone(env["readiness"])
            store.db.close()
