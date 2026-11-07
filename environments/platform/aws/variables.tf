variable "region" {
  type    = string
  default = "ap-northeast-2"
}
variable "name" {
  type    = string
  default = "foxtrot-platform"
}
variable "vpc_cidr" {
  type        = string
  default     = "10.30.0.0/16"
  description = "관리 VPC. 팀 대역 계획(traffic): AWS 앱 10.10, GCP 앱 10.20/10.21, 관리 10.30, Tailscale 100.64/10"
}
variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2c"]
}
variable "app_cidrs" {
  type        = list(string)
  default     = ["10.10.0.0/16", "10.20.0.0/16", "10.21.0.0/16"]
  description = "앱 환경 대역. 관리 VPC에서 이 대역으로 가는 트래픽은 게이트웨이(Tailscale)로 보냅니다."
}
variable "gateway_instance_type" {
  type    = string
  default = "t3.small"
}
variable "image_tags" {
  type        = map(string)
  default     = {}
  description = "서비스 이름 => 이미지 태그. 없으면 latest"
}
variable "gcp_project_id" {
  type        = string
  description = "플랫폼 서비스가 접근하는 GCP 프로젝트 (Cloud SQL 조회, GCS, 앱 환경 생성)"
}
variable "console_url" {
  type        = string
  default     = "https://platform.foxtrot.live"
  description = "콘솔 주소 (DNS는 Cloudflare). GitHub 로그인 콜백(<주소>/api/auth/github/callback)과 Origin 검사에 씁니다."
}
variable "github_client_id" {
  type        = string
  default     = "Ov23liYMrR7123mf374C"
  description = "org 소유 GitHub 앱의 Client ID (비밀 아님). secret은 Secrets Manager foxtrot/platform/github-client-secret"
}
variable "github_allowed_ids" {
  type = list(number)
  # org 멤버 전원: dlacowns21, hyunsuhahaha, noeulnight, SuperSon7, yyoungjin
  default     = [176018876, 76990163, 44047052, 121543941, 133024268]
  description = "콘솔 로그인을 허용할 GitHub 숫자 ID"
}
variable "redis_enabled" {
  type        = bool
  default     = true
  description = "Redis 프록시·statemig·sync worker 실행. 프록시는 시작할 때 원본·대상 Redis에 닿아야 하므로 앱 환경과 redis-endpoints 비밀이 준비된 뒤 켭니다."
}
variable "object_resources" {
  type        = string
  default     = "{\"aws-receipts\": {\"kind\": \"s3\", \"bucket\": \"foxtrot-chiikawa-aws-3e3d\", \"region\": \"ap-northeast-2\", \"ref\": \"default\"}, \"gcp-receipts\": {\"kind\": \"gcs\", \"bucket\": \"foxtrot-chiikawa-gcp-1975\", \"ref\": \"env:GCS\"}}"
  description = "object-migration OBJECT_RESOURCES (이전 대상 버킷 목록, JSON). 키가 시드의 resource:<이름>"
}
variable "traffic" {
  description = "트래픽 서비스의 Cloudflare 식별자 (트래픽 파트 값). 비어 있으면 /v1이 503"
  type = object({
    zone_id    = optional(string, "")
    account_id = optional(string, "")
    lb_id      = optional(string, "")
    pool_ids   = optional(string, "")
  })
  # app.foxtrot.live load balancer and its two pools (IDs are not secret).
  default = {
    zone_id    = "a347c7267257bd2d1b3fe35d0d62ac72"
    account_id = "3d6694c353d2e0519e3215805b763743"
    lb_id      = "6bf4a03e3d63cb3da4a19e6d0c69a606"
    pool_ids   = "{\"aws\":\"b26f0a79ed2d63568022f5b0ffd2b00d\",\"gcp\":\"c02ba1a4acbbbb702fd2f67d6b6dc6a4\"}"
  }
}

variable "redis_endpoints" {
  description = "Redis 프록시 백엔드: 이름 => redis:// 주소 (첫 항목이 처음 활성). 사설망(Tailscale)으로 닿는 앱 환경의 Redis"
  type        = map(string)
  # chiikawa: AWS ElastiCache (source) and GCP Memorystore (target), both reached over the tailnet.
  default = {
    aws = "redis://chiikawa-aws-3e3d-cache.nea7q9.ng.0001.apn2.cache.amazonaws.com:6379"
    gcp = "redis://10.21.107.99:6379"
  }
}

variable "redis_endpoint_auth" {
  description = "AUTH가 필요한 Redis 백엔드(온프렘 Valkey 등): redis_endpoints의 이름 => 계정. 비밀번호는 Secrets Manager ARN에서 읽는다(온프렘 handoff의 appCredentialRef, adminCredentialRef). 프록시는 앱 계정, sync worker와 statemig는 관리자 계정으로 붙는다"
  type = map(object({
    app_password_secret   = string
    admin_password_secret = string
    app_user              = optional(string, "app")
    admin_user            = optional(string, "default")
  }))
  default = {}
}

variable "redis_allowed_commands" {
  description = <<-EOT
    Redis 프록시의 앱 명령 목록(STATEMIG_ALLOWED_COMMANDS). 비어 있으면 끔. 켜면 목록 밖 명령은 NOPERM으로 거부하고,
    백엔드 등록 때 이 명령들만 비교한다. 엔진이나 버전이 다른 Redis(ElastiCache 7.1, Memorystore 7.0, Valkey 8) 사이를
    옮길 때 필요하다. 데모 앱 코드에서 찾은 후보(실제 실행으로 확인 전):
    get set del expire incr ping select multi exec discard zadd xadd xack xpending xgroup xreadgroup xautoclaim
    evalsha eval script publish subscribe unsubscribe
  EOT
  type        = list(string)
  default     = []
}

variable "observability" {
  description = "An external OTEL stack instead of the platform's own (observability.tf). Headers secret contains Authorization=Bearer%20<module-token>. Null: the platform stack when observability_enabled, else no SDK export."
  type = object({
    endpoint           = string
    headers_secret_arn = string
    prometheus_url     = string
    tempo_url          = string
  })
  default = null
}

variable "security_review" {
  description = "Console security review (control-plane security_review): CONTROL_PLANE_SECURITY_REVIEW_CONFIG_JSON and the GCP reader key it reads (SECURITY_GCP_CREDENTIALS). Null turns it off. Set up by Jeongbin on 11-08 outside Terraform; the key secret is managed outside this root."
  type = object({
    config                 = any
    gcp_credentials_secret = string
  })
  default = {
    config = {
      "application" : "chiikawa",
      "allowedUserIds" : [
        "github:121543941"
      ],
      "awsRole" : "chiikawa-aws-3e3d-app",
      "awsBucket" : "foxtrot-chiikawa-aws-3e3d",
      "gcpBucket" : "foxtrot-chiikawa-gcp-1975",
      "extraBucket" : "foxtrot-security-demo-513413",
      "gcpPrincipal" : "serviceAccount:chiikawa-gcp-1975-app@foxtrot-513413.iam.gserviceaccount.com",
      "gcpCredentialsRef" : "env:SECURITY_GCP_CREDENTIALS",
      "mode" : "cloud",
      "readOnly" : true
    }
    gcp_credentials_secret = "arn:aws:secretsmanager:ap-northeast-2:952561150367:secret:foxtrot/platform/gcp-security-reader-credentials-DETF5H"
  }
}
