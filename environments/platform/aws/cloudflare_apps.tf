# The chiikawa app on GCP has its own tunnel, run by the app VM's cloudflared, apart from the
# traffic part's test server (tunnel foxtrot-traffic-gcp, VM foxtrot-traffic-test-b).
#
# The Cloudflare account allows two load-balancer origins in all, both in use (pools "aws" and
# "gcp"), so this app gets no pool of its own: a pool's origin is pointed at this tunnel while that
# pool carries no traffic (tools/pool_origin.py). The tunnel answers the hostnames users and both
# pools' monitors send (app, aws and gcp .foxtrot.live), so it can take either pool.

locals {
  app_host = "app.foxtrot.live"
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
      { hostname = "aws.${var.cloudflare_zone}", service = "http://localhost:8000" },
      { hostname = "gcp.${var.cloudflare_zone}", service = "http://localhost:8000" },
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

# The load balancer stays with the traffic part. It was imported here for a pool that the origin
# limit does not allow; stop managing it without deleting it.
removed {
  from = cloudflare_load_balancer.app
  lifecycle {
    destroy = false
  }
}

output "chiikawa_gcp" {
  value = {
    tunnel_secret_ref = google_secret_manager_secret.chiikawa_gcp_tunnel.id
    tunnel_origin     = "${cloudflare_zero_trust_tunnel_cloudflared.chiikawa_gcp.id}.cfargotunnel.com"
    direct_url        = "https://chiikawa-gcp.${var.cloudflare_zone}"
  }
}
