import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

from tools.report_observations import compute_report, infra_report, plan_counts


class ObservationReportTests(unittest.TestCase):
    def test_replacements_are_not_double_counted(self):
        plan = {"format_version": "1.2", "resource_changes": [
            {"change": {"actions": actions}} for actions in (["delete", "create"], ["create"], ["no-op"], ["update"])]}
        self.assertEqual(plan_counts(plan), {"create": 1, "update": 1, "delete": 0, "replace": 1})

    def test_examples_do_not_prove_completed_infrastructure(self):
        example = json.loads((Path(__file__).parents[1] / "contracts/examples/plan-job-response.json").read_text())
        with self.assertRaises(KeyError):
            infra_report(example["migration_id"], example, {})

    def test_compute_report_does_not_expose_environment_or_refresh_evidence(self):
        at = "2025-01-01T00:00:00+00:00"
        state = {"workflowId": "w", "migrationId": "m", "kind": "COMPUTE", "lifecycle": "SYNCING", "health": "OK",
                 "observed": {"observedAt": at}, "details": {"compute": {"imageId": "sha256:x", "env": {"TOKEN": "secret"}}}}
        report = compute_report("w", state)
        self.assertEqual(report["data"]["observedAt"], at)
        self.assertNotIn("secret", str(report))
        with self.assertRaises(ValueError):
            compute_report("different", state)

    def test_success_requires_finished_at(self):
        job = {"id": "job", "migration_id": "w", "type": "APPLY", "status": "SUCCEEDED",
               "observed_at": datetime.now(timezone.utc).isoformat()}
        with self.assertRaises(ValueError):
            infra_report("w", job, {"format_version": "1.2", "resource_changes": []})
