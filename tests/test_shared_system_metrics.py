import copy
import unittest
from pathlib import Path

import yaml

from tools.render_system_metrics_env import render


class SharedSystemMetricsTests(unittest.TestCase):
    def setUp(self):
        self.seed = yaml.safe_load(
            (
                Path(__file__).parents[1] / "environments/platform/aws/seed.yaml"
            ).read_text()
        )

    def test_registered_clouds_use_exact_persisted_identity(self):
        for target in self.seed["systemDeployments"]:
            for role in ("api", "worker"):
                env = render(
                    self.seed,
                    target["environmentId"],
                    "http://collector:4318",
                    role,
                    "container",
                )
                self.assertEqual(env["OTEL_APPLICATION_ID"], "chiikawa")
                self.assertEqual(env["OTEL_OWNER_ID"], target["ownerId"])
                self.assertEqual(env["OTEL_DEPLOYMENT_ID"], target["deploymentId"])
                self.assertEqual(
                    env["OTEL_DEPLOYMENT_ENVIRONMENT"], target["environment"]
                )
                self.assertEqual(env["OTEL_APP_ROLE"], role)
                self.assertEqual(env["OTEL_SYSTEM_METRICS"], "container")
                self.assertNotIn("OTEL_EXPORTER_OTLP_HEADERS", env)
                self.assertNotIn("OTEL_SERVICE_INSTANCE_ID", env)

    def test_missing_duplicate_unknown_environment_and_injected_identity_fail(self):
        target = self.seed["systemDeployments"][0]
        cases = [(self.seed, "env-000000000000")]
        for field, value in (
            ("ownerId", ""),
            ("deploymentId", "bad\nOTEL_OWNER_ID=other"),
            ("environment", "unknown"),
        ):
            seed = copy.deepcopy(self.seed)
            seed["systemDeployments"][0][field] = value
            cases.append((seed, target["environmentId"]))
        duplicate = copy.deepcopy(self.seed)
        duplicate["systemDeployments"].append(target)
        cases.append((duplicate, target["environmentId"]))
        for seed, selected in cases:
            with self.assertRaises(ValueError):
                render(seed, selected, "http://collector:4318", "api", "container")

    def test_endpoint_and_shared_network(self):
        selected = self.seed["systemDeployments"][0]["environmentId"]
        for endpoint in (
            "file:///tmp/socket",
            "http://user:secret@collector",
            "http://collector?token=x",
            "http://collector\nOTEL_OWNER_ID=other",
        ):
            with self.assertRaises(ValueError):
                render(self.seed, selected, endpoint, "api", "app-instance")
        env = render(self.seed, selected, "https://collector/", "api", "app-instance")
        self.assertEqual(env["OTEL_NETWORK_SCOPE"], "app-instance")
