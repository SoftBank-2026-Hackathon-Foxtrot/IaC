output "handoff" {
  description = "비밀값 없는 모듈 인계 계약. resource_created는 앱/DB 이전 readiness를 보장하지 않습니다."
  value = {
    schema_version = 1
    cloud          = "aws"
    deployment_id  = var.deployment_id
    metadata       = module.metadata.common
    compute        = { id = module.ec2.instance_id, public_ip = module.ec2.public_ip, private_ip = module.ec2.private_ip, identity = module.iam.role_arn }
    database       = { id = module.rds.identifier, host = module.rds.address, port = module.rds.port, name = var.database_name, tls_required = true, admin_secret_ref = module.rds.master_secret_arn }
    cache          = { id = module.elasticache.id, host = module.elasticache.endpoint, port = module.elasticache.port, tls_required = true, auth_source = "external-secret-injection" }
    storage        = { id = module.s3.bucket_arn, name = module.s3.bucket_id }
    network        = { id = module.vpc.vpc_id, app_security_group_id = module.security_groups.app_id }
    pending_checks = ["application-deployment", "database-grants-and-schema", "replication-connectivity", "application-smoke-test"]
  }
}
