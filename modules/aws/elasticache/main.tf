variable "auth_token" {
  type        = string
  sensitive   = true
  description = "외부 secret injection으로 제공. Terraform state에 저장되므로 state 접근을 제한합니다."
  validation {
    condition     = can(regex("^[a-zA-Z0-9!&#$^<>-]{16,128}$", var.auth_token))
    error_message = "Redis AUTH는 16~128자의 허용된 문자만 사용합니다."
  }
}
resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = var.tags
}
resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = var.name
  description                = "${var.name} application cache"
  engine                     = "redis"
  engine_version             = "7.1"
  parameter_group_name       = "default.redis7"
  node_type                  = var.node_type
  num_cache_clusters         = var.node_count
  automatic_failover_enabled = var.node_count > 1
  multi_az_enabled           = var.node_count > 1
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [var.security_group_id]
  port                       = 6379
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = var.auth_token
  auth_token_update_strategy = "SET"
  snapshot_retention_limit   = 1
  apply_immediately          = false
  tags                       = var.tags
}
