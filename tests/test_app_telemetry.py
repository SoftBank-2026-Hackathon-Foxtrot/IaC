import copy
import unittest
from provisioner.app_telemetry import configure_app


class AppTelemetryTests(unittest.TestCase):
    def test_cloud_secret_references_and_no_request_override(self):
        config = {
            "appTelemetry": {
                "endpoint": "http://otel-collector.internal:4318",
                "applicationId": "goods",
                "headersSecrets": {
                    "aws": "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:otel",
                    "gcp": "projects/test/secrets/otel",
                },
            }
        }
        for cloud in ("aws", "gcp"):
            app = {}
            configure_app(
                app, config, cloud, owner="owner-1", deployment="deployment-1"
            )
            self.assertEqual(app["env"]["OTEL_SYSTEM_METRICS"], "container")
            self.assertEqual(
                app["secret_env"]["OTEL_EXPORTER_OTLP_HEADERS"],
                config["appTelemetry"]["headersSecrets"][cloud],
            )
            self.assertIn(
                "deployment.environment.name=" + cloud,
                app["env"]["OTEL_RESOURCE_ATTRIBUTES"],
            )
            for field in ("env", "api_env", "worker_env", "secret_env"):
                with self.assertRaises(ValueError):
                    configure_app(
                        {field: {"OTEL_EXPORTER_OTLP_ENDPOINT": "http://other"}},
                        config,
                        cloud,
                        owner="owner-1",
                        deployment="deployment-1",
                    )
            invalid = copy.deepcopy(config)
            invalid["appTelemetry"]["headersSecrets"].pop(cloud)
            with self.assertRaises(ValueError):
                configure_app(
                    {}, invalid, cloud, owner="owner-1", deployment="deployment-1"
                )

    def test_loaded_application_identity_overrides_example_name(self):
        app = {}
        configure_app(app, {"applicationId": "chiikawa", "appTelemetry": {"applicationId": "goods", "endpoint": "http://collector:4318", "headersSecrets": {"aws": "secret"}}}, "aws", owner="owner", deployment="deployment")
        self.assertEqual(app["env"]["OTEL_APPLICATION_ID"], "chiikawa")
