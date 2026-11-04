resource "google_redis_instance" "this" {
  name           = var.name
  region         = var.region
  tier           = var.high_availability ? "STANDARD_HA" : "BASIC"
  memory_size_gb = var.memory_gib
  redis_version  = "REDIS_7_0"
  redis_configs = {
    "notify-keyspace-events" = "KEA"
    "maxmemory-policy"       = "noeviction"
  }
  authorized_network      = var.network_id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  reserved_ip_range       = var.service_range_name
  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  labels                  = var.labels
}
