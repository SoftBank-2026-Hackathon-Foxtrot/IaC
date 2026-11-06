output "handoff" {
  description = "비밀값 없는 인계 계약. SQL IAM 사용자의 SQL GRANT와 앱 connector 설정은 후속 작업입니다."
  value = {
    schema_version = 1
    cloud          = "gcp"
    deployment_id  = var.deployment_id
    metadata       = module.metadata.common
    compute        = { id = module.compute.instance_id, public_ip = module.compute.public_ip, private_ip = module.compute.private_ip, identity = module.iam.service_account_email }
    database       = { id = module.cloud_sql.instance_name, host = module.cloud_sql.private_ip, port = 5432, name = var.database_name, connection_name = module.cloud_sql.connection_name, app_db_user = module.cloud_sql.app_db_user, tls_required = true, auth_mode = "cloud-sql-iam-connector" }
    cache          = { id = module.memorystore.id, host = module.memorystore.host, port = module.memorystore.port, tls_required = true, auth_source = "memorystore-get-auth-string-via-authorized-bootstrap", server_ca_certs = module.memorystore.server_ca_certs }
    storage        = { id = module.storage.url, name = module.storage.bucket_name }
    network        = { id = module.network.network_id, subnetwork_id = module.network.subnetwork_id }
    pending_checks = ["application-deployment", "database-grants-and-schema", "cache-auth-delivery", "replication-connectivity", "application-smoke-test"]
  }
}
