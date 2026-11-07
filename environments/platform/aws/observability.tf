# The OTEL stack the module SDKs export to: one Fargate task running the collector, Prometheus
# and Tempo, registered as otel-collector.internal. It mirrors control-plane
# infrastructure/observability/compose.yaml; the config files are passed through the environment
# because the images carry no shell (collector) or no volume (the others).
#
# Storage is the task's ephemeral disk: 24 h retention, lost on redeploy. The console reads
# Prometheus and Tempo through the control-plane only (CONTROL_PLANE_PROMETHEUS_URL/TEMPO_URL).
#
# Tokens: modules authenticate to the collector with otel-ingest-token (the SDK header secret
# carries it as Authorization=Bearer%20<token>); the collector forwards snapshot logs to the
# control-plane with the separate observation-token. Modules never hold the CP token.

variable "observability_enabled" {
  description = "Run the private OTEL stack (otel-collector.internal) and export every service's SDK to it. var.observability, when set, points the SDKs at an external stack instead."
  type        = bool
  default     = true
}

locals {
  otel_stack = var.observability_enabled && var.observability == null
  observability = var.observability != null ? var.observability : (!local.otel_stack ? null : {
    endpoint           = "http://otel-collector.internal:4318"
    headers_secret_arn = one(aws_secretsmanager_secret.otel_headers[*].arn)
    prometheus_url     = "http://otel-collector.internal:9090"
    tempo_url          = "http://otel-collector.internal:3200"
  })

  # All three containers share the task's network namespace, so Tempo's own OTLP receiver moves
  # off 4318 (the collector's port) to 4320.
  otel_collector_config = yamlencode({
    extensions = {
      "bearertokenauth/modules" = { token = "$${env:OTEL_INGEST_TOKEN}" }
    }
    receivers = {
      otlp = { protocols = { http = { endpoint = "0.0.0.0:4318", auth = { authenticator = "bearertokenauth/modules" } } } }
    }
    processors = {
      memory_limiter     = { check_interval = "1s", limit_mib = 384, spike_limit_mib = 96 }
      "filter/snapshots" = { error_mode = "ignore", logs = { log_record = ["attributes[\"foxtrot.event\"] != \"snapshot\""] } }
      batch              = { timeout = "1s", send_batch_size = 16, send_batch_max_size = 24 }
    }
    exporters = {
      "otlp_http/control_plane" = {
        logs_endpoint    = "http://control-plane.internal:8000/internal/otlp/v1/logs"
        headers          = { Authorization = "Bearer $${env:OBSERVATION_TOKEN}" }
        compression      = "none"
        timeout          = "5s"
        sending_queue    = { enabled = true, queue_size = 256 }
        retry_on_failure = { enabled = true, max_elapsed_time = "5m" }
      }
      "otlp_http/prometheus" = {
        endpoint         = "http://127.0.0.1:9090/api/v1/otlp"
        sending_queue    = { enabled = true, queue_size = 256 }
        retry_on_failure = { max_elapsed_time = "1m" }
      }
      "otlp_http/tempo" = {
        endpoint         = "http://127.0.0.1:4320"
        sending_queue    = { enabled = true, queue_size = 256 }
        retry_on_failure = { max_elapsed_time = "1m" }
      }
    }
    service = {
      extensions = ["bearertokenauth/modules"]
      pipelines = {
        logs    = { receivers = ["otlp"], processors = ["memory_limiter", "filter/snapshots", "batch"], exporters = ["otlp_http/control_plane"] }
        metrics = { receivers = ["otlp"], processors = ["memory_limiter", "batch"], exporters = ["otlp_http/prometheus"] }
        traces  = { receivers = ["otlp"], processors = ["memory_limiter", "batch"], exporters = ["otlp_http/tempo"] }
      }
    }
  })
  # service_name / foxtrot_module become labels: the control-plane's /telemetry reads service_name.
  otel_prometheus_config = yamlencode({
    global  = { evaluation_interval = "15s" }
    storage = { tsdb = { out_of_order_time_window = "5m" } }
    otlp = {
      promote_resource_attributes = ["service.name", "service.instance.id", "foxtrot.module"]
      translation_strategy        = "UnderscoreEscapingWithSuffixes"
    }
  })
  otel_tempo_config = yamlencode({
    server      = { http_listen_port = 3200 }
    distributor = { receivers = { otlp = { protocols = { http = { endpoint = "0.0.0.0:4320" } } } } }
    storage = { trace = {
      backend = "local"
      wal     = { path = "/var/tempo/wal" }
      local   = { path = "/var/tempo/blocks" }
    } }
    compactor = { compaction = { block_retention = "24h" } }
  })
}

# The SDK header secret: the module token in the OTEL_EXPORTER_OTLP_HEADERS form.
resource "aws_secretsmanager_secret" "otel_headers" {
  count                   = local.otel_stack ? 1 : 0
  name                    = "foxtrot/platform/otel-exporter-headers"
  description             = "OTEL_EXPORTER_OTLP_HEADERS for every platform service: Authorization=Bearer%20<otel-ingest-token>"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "otel_headers" {
  count         = local.otel_stack ? 1 : 0
  secret_id     = aws_secretsmanager_secret.otel_headers[0].id
  secret_string = "Authorization=Bearer%20${random_password.generated["otel-ingest-token"].result}"
}

module "observability" {
  count  = local.otel_stack ? 1 : 0
  source = "../../../modules/platform_service"
  name   = "otel-collector"
  cpu    = 1024
  memory = 2048
  containers = [
    {
      name    = "collector"
      image   = "otel/opentelemetry-collector-contrib:0.147.0"
      command = ["--config=env:OTEL_COLLECTOR_CONFIG"]
      ports   = [4318]
      environment = {
        OTEL_COLLECTOR_CONFIG = local.otel_collector_config
      }
      secrets = {
        OTEL_INGEST_TOKEN = aws_secretsmanager_secret.generated["otel-ingest-token"].arn
        OBSERVATION_TOKEN = local.secret_arn["observation-token"]
      }
      dependsOn = [
        { containerName = "prometheus", condition = "HEALTHY" },
        { containerName = "tempo", condition = "HEALTHY" },
      ]
    },
    {
      name       = "prometheus"
      image      = "prom/prometheus:v3.9.1"
      entryPoint = ["sh", "-c"]
      command    = ["printf '%s' \"$PROMETHEUS_CONFIG\" > /prometheus/config.yaml && exec /bin/prometheus --config.file=/prometheus/config.yaml --storage.tsdb.path=/prometheus --web.enable-otlp-receiver --storage.tsdb.retention.time=24h --storage.tsdb.retention.size=1GB"]
      ports      = [9090]
      environment = {
        PROMETHEUS_CONFIG = local.otel_prometheus_config
      }
      health = ["wget -qO- http://127.0.0.1:9090/-/ready > /dev/null || exit 1"]
    },
    {
      name       = "tempo"
      image      = "grafana/tempo:2.9.0"
      entryPoint = ["sh", "-c"]
      command    = ["printf '%s' \"$TEMPO_CONFIG\" > /var/tempo/tempo.yaml && exec /tempo -config.file=/var/tempo/tempo.yaml"]
      ports      = [3200]
      environment = {
        TEMPO_CONFIG = local.otel_tempo_config
      }
      # The image has busybox but no /bin/sh, so no CMD-SHELL. /ready stays 503 for minutes while
      # the ring settles; the HTTP server answering is enough for the collector, which retries.
      health = ["CMD", "/busybox/wget", "-qO-", "http://127.0.0.1:3200/api/echo"]
    },
  ]
  depends_on = [aws_secretsmanager_secret_version.generated]
  # shared settings
  cluster_id         = local.svc.cluster_id
  subnet_ids         = local.svc.subnet_ids
  security_group_ids = local.svc.security_group_ids
  namespace_id       = local.svc.namespace_id
  log_group          = local.svc.log_group
  region             = local.svc.region
}

output "observability" {
  description = "Where the SDKs export and the control-plane reads (null: export disabled)"
  value       = local.observability == null ? null : { for k, v in local.observability : k => v if k != "headers_secret_arn" }
}
