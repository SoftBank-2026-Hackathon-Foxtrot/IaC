# The running app: the image already in Artifact Registry, started on the VM at every boot.

variable "app" {
  description = "앱 이미지(Artifact Registry)와 실행 방식. env로 DATABASE_URL 등을 덮어쓰면 플랫폼 프록시를 거치게 할 수 있습니다."
  type = object({
    image             = string
    port              = optional(number, 80)
    api_workers       = optional(number, 4)
    worker_count      = optional(number, 2)
    served_by         = optional(string)
    seed_demo_data    = optional(bool, true)
    seed_close_in_s   = optional(number, 86400)
    env               = optional(map(string), {})
    api_env           = optional(map(string), {})
    worker_env        = optional(map(string), {})
    secret_env        = optional(map(string), {}) # NAME => projects/<p>/secrets/<name>
    tunnel_secret     = optional(string)          # projects/<p>/secrets/<name> of a Cloudflare tunnel token
    cloudflared_image = optional(string, "cloudflare/cloudflared:2024.12.2")
  })
  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/", var.app.image))
    error_message = "app.image는 Artifact Registry 이미지 주소입니다 (<리전>-docker.pkg.dev/<프로젝트>/<저장소>/<이미지>:<태그>)."
  }
}
variable "db_authorized_networks" {
  type        = map(string)
  default     = {}
  description = "Cloud SQL 공인 IP에 접속을 허용할 이름 => CIDR (플랫폼 DB 에이전트, 복제 원본). 비어 있으면 사설 IP만."
  validation {
    condition     = alltrue([for c in values(var.db_authorized_networks) : can(cidrnetmask(c)) && tonumber(split("/", c)[1]) >= 24])
    error_message = "허용 대역은 /24~/32 CIDR만 받습니다."
  }
}
variable "redis_auth" {
  type        = bool
  default     = false
  description = "Memorystore AUTH. 팀 Redis 프록시가 백엔드 AUTH를 다루지 않아 기본은 끕니다."
}
variable "redis_transit_encryption" {
  type        = bool
  default     = false
  description = "Memorystore TLS. 팀 Redis 프록시가 TLS 백엔드를 지원하지 않아 기본은 끕니다."
}

locals {
  app_db_user = "app"
  secrets = {
    app_db   = random_password.app_db.result
    db_admin = random_password.db_admin.result
    storage  = module.iam.hmac_secret
  }
  extra_secret_refs = merge(var.app.secret_env, var.app.tunnel_secret == null ? {} : { TUNNEL = var.app.tunnel_secret })
}

resource "random_password" "app_db" {
  length  = 32
  special = false
}
resource "random_password" "db_admin" {
  length  = 32
  special = false
}
resource "google_secret_manager_secret" "app_db" {
  secret_id = "${var.deployment_id}-app-db"
  labels    = merge(module.metadata.common, { component = "database" })
  replication {
    auto {}
  }
  depends_on = [google_project_service.required]
}
resource "google_secret_manager_secret" "db_admin" {
  secret_id = "${var.deployment_id}-db-admin"
  labels    = merge(module.metadata.common, { component = "database" })
  replication {
    auto {}
  }
  depends_on = [google_project_service.required]
}
resource "google_secret_manager_secret" "storage" {
  secret_id = "${var.deployment_id}-storage-hmac"
  labels    = merge(module.metadata.common, { component = "storage" })
  replication {
    auto {}
  }
  depends_on = [google_project_service.required]
}
resource "google_secret_manager_secret_version" "app_db" {
  secret      = google_secret_manager_secret.app_db.id
  secret_data = local.secrets.app_db
}
resource "google_secret_manager_secret_version" "db_admin" {
  secret      = google_secret_manager_secret.db_admin.id
  secret_data = local.secrets.db_admin
}
resource "google_secret_manager_secret_version" "storage" {
  secret      = google_secret_manager_secret.storage.id
  secret_data = local.secrets.storage
}
# The VM reads exactly these secrets, nothing else in the project.
resource "google_secret_manager_secret_iam_member" "app" {
  for_each = merge(
    { app_db = google_secret_manager_secret.app_db.id, db_admin = google_secret_manager_secret.db_admin.id, storage = google_secret_manager_secret.storage.id },
    local.extra_secret_refs,
    var.tailscale == null ? {} : { TAILSCALE = var.tailscale.auth_key_secret },
  )
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.iam.service_account_email}"
}

module "app_runtime" {
  source = "../../modules/app_runtime"
  cloud  = "gcp"
  region = var.region
  app    = var.app
  database = {
    host                = module.cloud_sql.private_ip
    port                = 5432
    name                = var.database_name
    app_user            = local.app_db_user
    app_password_secret = google_secret_manager_secret.app_db.id
    admin_secret        = google_secret_manager_secret.db_admin.id
    admin_secret_format = "plain"
    admin_user          = module.cloud_sql.admin_user
  }
  redis_url = "${var.redis_transit_encryption ? "rediss" : "redis"}://${module.memorystore.host}:${module.memorystore.port}"
  storage = {
    bucket        = module.storage.bucket_name
    region        = "auto"
    endpoint      = "https://storage.googleapis.com"
    access_key_id = module.iam.hmac_access_id
    secret        = google_secret_manager_secret.storage.id
  }
  tailscale = var.tailscale == null ? null : {
    auth_key_secret = var.tailscale.auth_key_secret, tag = var.tailscale.tag,
    routes          = [var.network.subnet_cidr, "${var.network.service_range_address}/${var.network.service_range_prefix}"], hostname = var.deployment_id
  }
}

variable "force_destroy_storage" {
  type        = bool
  default     = false
  description = "환경을 지울 때 버킷에 객체가 남아 있어도 지웁니다. 프로비저닝 API가 만든 PoC 환경에서만 켭니다."
}

variable "tailscale" {
  description = "플랫폼과의 사설망: 앱 VM이 이 키(projects/<p>/secrets/<name>)로 tailnet에 가입하고 VM·관리형 서비스 대역을 광고합니다"
  type        = object({ auth_key_secret = string, tag = optional(string, "tag:gcp") })
  default     = null
}
