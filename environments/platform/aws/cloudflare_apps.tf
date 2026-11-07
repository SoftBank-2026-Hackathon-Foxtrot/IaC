# The chiikawa app on GCP gets its own entry, apart from the traffic part's test server (pool
# "gcp", tunnel foxtrot-traffic-gcp): a tunnel run by the app VM's cloudflared, a pool on that
# tunnel, and that pool in the app.foxtrot.live load balancer at weight 0. The control plane's
# seed names it trafficPool "chiikawa-gcp", so a migration moves users between "aws" and it and
# leaves the other pools at 0.

locals {
  app_host = "app.foxtrot.live"
  # Every pool the load balancer has; the traffic service needs all of them (CF_POOL_IDS).
  traffic_pool_ids = merge(jsondecode(var.traffic.pool_ids), {
    "chiikawa-gcp" = cloudflare_load_balancer_pool.chiikawa_gcp.id
  })
}

resource "random_bytes" "chiikawa_gcp_tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "chiikawa_gcp" {
  account_id    = local.cf_account_id
  name          = "foxtrot-chiikawa-gcp"
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.chiikawa_gcp_tunnel_secret.base64
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "chiikawa_gcp" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.chiikawa_gcp.id
  config = {
    ingress = [
      { hostname = local.app_host, service = "http://localhost:8000" },
      { hostname = "chiikawa-gcp.${var.cloudflare_zone}", service = "http://localhost:8000" },
      { service = "http_status:404" },
    ]
  }
}

# chiikawa-gcp.foxtrot.live reaches this VM directly, for checks outside the load balancer.
resource "cloudflare_dns_record" "chiikawa_gcp" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "chiikawa-gcp.${var.cloudflare_zone}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.chiikawa_gcp.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "chiikawa app on GCP (tunnel foxtrot-chiikawa-gcp, managed by Terraform)"
}

# The GCP app VM reads its tunnel token from Secret Manager in its project.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "chiikawa_gcp" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.chiikawa_gcp.id
}
resource "google_secret_manager_secret" "chiikawa_gcp_tunnel" {
  secret_id = "foxtrot-app-cloudflare-tunnel-chiikawa-gcp"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "chiikawa_gcp_tunnel" {
  secret      = google_secret_manager_secret.chiikawa_gcp_tunnel.id
  secret_data = data.cloudflare_zero_trust_tunnel_cloudflared_token.chiikawa_gcp.token
}

resource "cloudflare_load_balancer_monitor" "chiikawa_gcp" {
  account_id     = local.cf_account_id
  description    = "foxtrot-chiikawa-gcp-readyz"
  type           = "https"
  method         = "GET"
  path           = "/readyz"
  port           = 443
  expected_codes = "200"
  interval       = 60
  header         = { Host = [local.app_host] }
}

resource "cloudflare_load_balancer_pool" "chiikawa_gcp" {
  account_id      = local.cf_account_id
  name            = "foxtrot-chiikawa-gcp"
  monitor         = cloudflare_load_balancer_monitor.chiikawa_gcp.id
  minimum_origins = 1
  check_regions   = ["SEAS"]
  origins = [{
    name    = "chiikawa-gcp"
    address = "${cloudflare_zero_trust_tunnel_cloudflared.chiikawa_gcp.id}.cfargotunnel.com"
    enabled = true
    weight  = 1
    header  = { host = [local.app_host] }
  }]
}

# The load balancer was made by hand for the traffic part; Terraform now keeps its pool list.
# The traffic service sets the pool weights at run time, so Terraform leaves them alone.
import {
  to = cloudflare_load_balancer.app
  id = "${var.traffic.zone_id}/${var.traffic.lb_id}"
}
resource "cloudflare_load_balancer" "app" {
  zone_id          = var.traffic.zone_id
  name             = local.app_host
  description      = "Foxtrot migration demo"
  proxied          = true
  enabled          = true
  steering_policy  = "random"
  session_affinity = "none"
  fallback_pool    = local.traffic_pool_ids["aws"]
  default_pools    = [local.traffic_pool_ids["aws"], local.traffic_pool_ids["gcp"], local.traffic_pool_ids["chiikawa-gcp"]]
  random_steering  = { default_weight = 0 }
  # As the load balancer was made; written out so the import changes only default_pools.
  networks                    = ["cloudflare"]
  adaptive_routing            = { failover_across_pools = false }
  location_strategy           = { mode = "pop", prefer_ecs = "proximity" }
  session_affinity_attributes = { samesite = "Auto", secure = "Auto", drain_duration = 0, zero_downtime_failover = "none" }
  lifecycle {
    ignore_changes = [random_steering]
  }
}

output "chiikawa_gcp" {
  value = {
    tunnel_secret_ref = google_secret_manager_secret.chiikawa_gcp_tunnel.id
    pool_id           = cloudflare_load_balancer_pool.chiikawa_gcp.id
    direct_url        = "https://chiikawa-gcp.${var.cloudflare_zone}"
  }
}
