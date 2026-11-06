output "handoff" {
  description = "비밀값 없는 인계 계약. 비밀값은 Secret Manager 참조로만 전달합니다."
  value = {
    schema_version = 1
    cloud          = "gcp"
    deployment_id  = var.deployment_id
    metadata       = module.metadata.common
    compute        = { id = module.compute.instance_id, public_ip = module.compute.public_ip, private_ip = module.compute.private_ip, identity = module.iam.service_account_email }
    database       = { id = module.cloud_sql.instance_name, host = module.cloud_sql.private_ip, port = 5432, name = var.database_name, engine = "postgres", version = "17", connection_name = module.cloud_sql.connection_name, public_ip = module.cloud_sql.public_ip, outgoing_ip = module.cloud_sql.outgoing_ip, tls_required = true, logical_decoding = true, admin_user = module.cloud_sql.admin_user, admin_secret_ref = google_secret_manager_secret.db_admin.id, app_user = local.app_db_user, app_secret_ref = google_secret_manager_secret.app_db.id }
    cache          = { id = module.memorystore.id, host = module.memorystore.host, port = module.memorystore.port, tls_required = var.redis_transit_encryption, auth_enabled = var.redis_auth }
    storage        = { id = module.storage.url, name = module.storage.bucket_name }
    network        = { id = module.network.network_id, subnetwork_id = module.network.subnetwork_id }
    app            = { image = var.app.image, url = "http://${module.compute.public_ip}${var.app.port == 80 ? "" : ":${var.app.port}"}", env_keys = module.app_runtime.app_env_keys, boot_log = "/var/log/foxtrot-app.log" }
    pending_checks = ["application-boot-log", "application-smoke-test"]
  }
}
