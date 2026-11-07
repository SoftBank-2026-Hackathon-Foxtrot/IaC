output "handoff" {
  description = "비밀값 없는 모듈 인계 계약. resource_created는 앱/DB 이전 readiness를 보장하지 않습니다."
  value = {
    schema_version = 1
    cloud          = "aws"
    deployment_id  = var.deployment_id
    metadata       = module.metadata.common
    compute        = { id = module.ec2.instance_id, public_ip = module.ec2.public_ip, private_ip = module.ec2.private_ip, identity = module.iam.role_arn }
    database       = { id = module.rds.identifier, host = module.rds.address, port = module.rds.port, name = var.database_name, engine = "postgres", version = var.postgres_version, tls_required = true, logical_replication = true, publicly_accessible = length(var.replication_cidrs) > 0, admin_secret_ref = module.rds.master_secret_arn, app_user = local.app_db_user, app_secret_ref = aws_secretsmanager_secret.app_db.arn, arn = module.rds.arn, operator_secret_ref = aws_secretsmanager_secret.db_operator.arn }
    cache          = { id = module.elasticache.id, host = module.elasticache.endpoint, port = module.elasticache.port, tls_required = var.redis_transit_encryption, auth_source = var.redis_transit_encryption ? "external-secret-injection" : "none-security-group-only" }
    storage        = { id = module.s3.bucket_arn, name = module.s3.bucket_id }
    network        = { id = module.vpc.vpc_id, app_security_group_id = module.security_groups.app_id }
    app            = { image = var.app.image, url = "http://${module.ec2.public_ip}${var.app.port == 80 ? "" : ":${var.app.port}"}", env_keys = module.app_runtime.app_env_keys, boot_log = "/var/log/foxtrot-app.log" }
    pending_checks = ["application-boot-log", "application-smoke-test"]
  }
}
