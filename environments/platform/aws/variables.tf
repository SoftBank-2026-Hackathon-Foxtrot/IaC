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
  default     = "https://platform.foxtrot.invalid"
  description = "콘솔 주소 (Cloudflare). GitHub 로그인 콜백과 Origin 검사에 씁니다. 도메인이 정해지면 바꿉니다."
}
variable "github_client_id" {
  type    = string
  default = ""
}
variable "github_allowed_ids" {
  type        = list(number)
  default     = []
  description = "콘솔 로그인을 허용할 GitHub 숫자 ID"
}
variable "redis_enabled" {
  type        = bool
  default     = false
  description = "Redis 프록시·statemig·sync worker 실행. 프록시는 시작할 때 원본·대상 Redis에 닿아야 하므로 앱 환경과 redis-endpoints 비밀이 준비된 뒤 켭니다."
}
variable "object_resources" {
  type        = string
  default     = "{}"
  description = "object-migration OBJECT_RESOURCES (이전 대상 버킷 목록, JSON)"
}
variable "traffic" {
  description = "트래픽 서비스의 Cloudflare 식별자 (트래픽 파트 값). 비어 있으면 /v1이 503"
  type = object({
    zone_id    = optional(string, "")
    account_id = optional(string, "")
    lb_id      = optional(string, "")
    pool_ids   = optional(string, "")
  })
  default = {}
}
