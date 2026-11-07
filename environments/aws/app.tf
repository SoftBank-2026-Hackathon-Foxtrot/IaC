# The running app: the image already in ECR, started on the EC2 instance at first boot.

variable "app" {
  description = "앱 이미지(ECR)와 실행 방식. env로 DATABASE_URL 등을 덮어쓰면 플랫폼 프록시를 거치게 할 수 있습니다."
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
    secret_env        = optional(map(string), {}) # NAME => Secrets Manager ARN
    tunnel_secret     = optional(string)          # Secrets Manager ARN of a Cloudflare tunnel token
    cloudflared_image = optional(string, "cloudflare/cloudflared:2024.12.2")
  })
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/", var.app.image))
    error_message = "app.image는 ECR 이미지 주소입니다 (<계정>.dkr.ecr.<리전>.amazonaws.com/<저장소>:<태그>)."
  }
}
variable "replication_cidrs" {
  type        = set(string)
  default     = []
  nullable    = false
  description = "다른 클라우드의 대상 DB가 RDS로 복제 접속하는 공인 IP. 비어 있지 않으면 RDS에 공인 endpoint가 생깁니다."
}

locals {
  extra_secret_arns = merge(var.app.secret_env, var.app.tunnel_secret == null ? {} : { TUNNEL = var.app.tunnel_secret })
  app_db_user       = "app"
}

resource "random_password" "app_db" {
  length  = 32
  special = false
}
resource "aws_secretsmanager_secret" "app_db" {
  name_prefix             = "${var.deployment_id}-app-db-"
  description             = "App database role password for ${var.deployment_id}"
  recovery_window_in_days = 0
  tags                    = merge(module.metadata.common, { component = "database" })
}
resource "aws_secretsmanager_secret_version" "app_db" {
  secret_id     = aws_secretsmanager_secret.app_db.id
  secret_string = random_password.app_db.result
}

module "app_runtime" {
  source = "../../modules/app_runtime"
  cloud  = "aws"
  region = var.region
  app    = var.app
  database = {
    host                = module.rds.address
    port                = module.rds.port
    name                = var.database_name
    app_user            = local.app_db_user
    app_password_secret = aws_secretsmanager_secret.app_db.arn
    admin_secret        = module.rds.master_secret_arn
    admin_secret_format = "rds-json"
  }
  redis_url = "${var.redis_transit_encryption ? "rediss" : "redis"}://${module.elasticache.endpoint}:${module.elasticache.port}"
  storage   = { bucket = module.s3.bucket_id, region = var.region }
  tailscale = var.tailscale == null ? null : {
    auth_key_secret = var.tailscale.auth_key_secret, tag = var.tailscale.tag,
    routes          = [var.network.vpc_cidr], hostname = var.deployment_id
  }
}

variable "force_destroy_storage" {
  type        = bool
  default     = false
  description = "환경을 지울 때 버킷에 객체가 남아 있어도 지웁니다. 프로비저닝 API가 만든 PoC 환경에서만 켭니다."
}

variable "tailscale" {
  description = "플랫폼과의 사설망: 앱 VM이 이 키(Secrets Manager ARN)로 tailnet에 가입하고 VPC 대역을 광고합니다"
  type        = object({ auth_key_secret = string, tag = optional(string, "tag:aws") })
  default     = null
}
