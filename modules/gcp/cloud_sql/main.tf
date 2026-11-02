resource "google_sql_database_instance" "this" {
  name                = var.name
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = var.deletion_protection
  settings {
    tier                        = var.tier
    edition                     = "ENTERPRISE"
    availability_type           = var.high_availability ? "REGIONAL" : "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.storage_gib
    disk_autoresize             = true
    disk_autoresize_limit       = var.max_storage_gib
    deletion_protection_enabled = var.deletion_protection
    user_labels                 = var.labels
    ip_configuration {
      ipv4_enabled       = false
      private_network    = var.network_id
      allocated_ip_range = var.service_range_name
      ssl_mode           = "ENCRYPTED_ONLY"
    }
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "18:00"
      transaction_log_retention_days = 7
      backup_retention_settings { retained_backups = 7 }
    }
    maintenance_window {
      day          = 7
      hour         = 19
      update_track = "stable"
    }
  }
}
resource "google_sql_database" "app" {
  name     = var.database_name
  instance = google_sql_database_instance.this.name
}
resource "google_sql_user" "app" {
  name     = trimsuffix(var.app_service_account, ".gserviceaccount.com")
  instance = google_sql_database_instance.this.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}
