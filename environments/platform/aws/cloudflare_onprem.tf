# The on-prem app's way in from the load balancer: tunnel foxtrot-chiikawa-onprem, run by a
# cloudflared next to the app on the on-prem host (outbound only, no port forwarding):
#
#   docker run -d --name cloudflared --restart unless-stopped --network host \
#     cloudflare/cloudflared:2024.12.2 tunnel --no-autoupdate run --token <foxtrot/app/cloudflare-tunnel-onprem>
#
# The account allows two load-balancer origins, so on-prem gets no pool of its own: a pool's one
# origin is pointed at this tunnel while that pool carries no traffic (tools/pool_origin.sh).
# Which pool depends on the move: the "aws" pool's monitor sends Host aws.foxtrot.live and the
# "gcp" pool's sends gcp.foxtrot.live, so the tunnel answers both, and app.foxtrot.live for users.

variable "onprem_app_origin" {
  type        = string
  default     = "http://localhost:8000"
  description = "Where cloudflared on the on-prem host reaches the app"
}

resource "random_bytes" "chiikawa_onprem_tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "chiikawa_onprem" {
  account_id    = local.cf_account_id
  name          = "foxtrot-chiikawa-onprem"
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.chiikawa_onprem_tunnel_secret.base64
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "chiikawa_onprem" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.chiikawa_onprem.id
  config = {
    ingress = [
      { hostname = local.app_host, service = var.onprem_app_origin },
      { hostname = "aws.${var.cloudflare_zone}", service = var.onprem_app_origin },
      { hostname = "gcp.${var.cloudflare_zone}", service = var.onprem_app_origin },
      { hostname = "chiikawa-onprem.${var.cloudflare_zone}", service = var.onprem_app_origin },
      { service = "http_status:404" },
    ]
  }
}

# chiikawa-onprem.foxtrot.live reaches the on-prem app directly, for checks outside the load balancer.
resource "cloudflare_dns_record" "chiikawa_onprem" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "chiikawa-onprem.${var.cloudflare_zone}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.chiikawa_onprem.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "chiikawa app on-prem (tunnel foxtrot-chiikawa-onprem, managed by Terraform)"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "chiikawa_onprem" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.chiikawa_onprem.id
}

resource "aws_secretsmanager_secret" "chiikawa_onprem_tunnel" {
  name                    = "foxtrot/app/cloudflare-tunnel-onprem"
  description             = "Cloudflare tunnel token for the on-prem chiikawa app; written by Terraform"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "chiikawa_onprem_tunnel" {
  secret_id     = aws_secretsmanager_secret.chiikawa_onprem_tunnel.id
  secret_string = data.cloudflare_zero_trust_tunnel_cloudflared_token.chiikawa_onprem.token
}

output "chiikawa_onprem" {
  value = {
    tunnel_name       = cloudflare_zero_trust_tunnel_cloudflared.chiikawa_onprem.name
    tunnel_origin     = "${cloudflare_zero_trust_tunnel_cloudflared.chiikawa_onprem.id}.cfargotunnel.com"
    tunnel_secret_ref = aws_secretsmanager_secret.chiikawa_onprem_tunnel.arn
    direct_url        = "https://chiikawa-onprem.${var.cloudflare_zone}"
  }
}
