# Redis proxy backends. The proxy, statemig and the sync worker read STATEMIG_ENDPOINTS
# (name=url,...). The cloud app environments' Redis have no AUTH, so their URLs carry no password.
# A backend listed in var.redis_endpoint_auth (on-prem Valkey with ACL users) gets its accounts
# from Secrets Manager: the proxy logs in as the app account (the one statemig fences on the old
# side), the sync worker and statemig as the admin account.
data "aws_secretsmanager_secret_version" "redis_auth" {
  for_each  = merge([for name, auth in var.redis_endpoint_auth : { "${name}/app" = auth.app_password_secret, "${name}/admin" = auth.admin_password_secret }]...)
  secret_id = each.value
}
locals {
  redis_url_parts = { for name, url in var.redis_endpoints : name => regex("^(rediss?)://(.+)$", url) }
  redis_url_for = { for side in ["app", "admin"] : side => {
    for name, url in var.redis_endpoints : name => !contains(keys(var.redis_endpoint_auth), name) ? url : format("%s://%s:%s@%s",
      local.redis_url_parts[name][0],
      side == "app" ? var.redis_endpoint_auth[name].app_user : var.redis_endpoint_auth[name].admin_user,
      urlencode(trimspace(data.aws_secretsmanager_secret_version.redis_auth["${name}/${side}"].secret_string)),
    local.redis_url_parts[name][1])
  } }
  redis_endpoints_value = { for side, urls in local.redis_url_for : side => join(",", [for name in sort(keys(urls)) : "${name}=${urls[name]}"]) }
  redis_secret_side     = { "redis-endpoints-proxy" = "app", "redis-endpoints-admin" = "admin" }
}
resource "aws_secretsmanager_secret" "redis_endpoints" {
  for_each                = toset(["redis-endpoints-proxy", "redis-endpoints-admin"])
  name                    = "foxtrot/platform/${each.key}"
  description             = "STATEMIG_ENDPOINTS (name=redis://[user:pw@]host:port,...); written by Terraform from var.redis_endpoints and var.redis_endpoint_auth"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "redis_endpoints" {
  for_each      = aws_secretsmanager_secret.redis_endpoints
  secret_id     = each.value.id
  secret_string = local.redis_endpoints_value[local.redis_secret_side[each.key]] == "" ? "UNSET" : local.redis_endpoints_value[local.redis_secret_side[each.key]]
  lifecycle {
    precondition {
      condition     = alltrue([for name in keys(var.redis_endpoint_auth) : contains(keys(var.redis_endpoints), name)])
      error_message = "redis_endpoint_auth names a backend that is not in redis_endpoints."
    }
  }
}
moved {
  from = aws_secretsmanager_secret.external["redis-endpoints-proxy"]
  to   = aws_secretsmanager_secret.redis_endpoints["redis-endpoints-proxy"]
}
moved {
  from = aws_secretsmanager_secret.external["redis-endpoints-admin"]
  to   = aws_secretsmanager_secret.redis_endpoints["redis-endpoints-admin"]
}
moved {
  from = aws_secretsmanager_secret_version.external["redis-endpoints-proxy"]
  to   = aws_secretsmanager_secret_version.redis_endpoints["redis-endpoints-proxy"]
}
moved {
  from = aws_secretsmanager_secret_version.external["redis-endpoints-admin"]
  to   = aws_secretsmanager_secret_version.redis_endpoints["redis-endpoints-admin"]
}
