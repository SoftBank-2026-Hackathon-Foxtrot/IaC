variable "name" {
  type        = string
  description = "배포별 고유 이름. root에서 검증합니다."
}

variable "labels" {
  type        = map(string)
  description = "필수 추적 메타데이터. 비밀값과 개인정보를 넣지 않습니다."
}

variable "network_id" {
  type        = string
  description = "VPC network ID"
}

variable "app_service_account" {
  type        = string
  description = "앱 VM에 붙일 service account email"
}

variable "web_ingress_cidrs" {
  type        = set(string)
  description = "웹 접근 CIDR"
}

variable "web_ports" {
  type        = set(number)
  description = "웹 TCP ports"
}

variable "admin_cidrs" {
  type        = set(string)
  description = "선택적 SSH 관리자 CIDR"
}

variable "service_cidr" {
  type        = string
  description = "DB/cache용 Private Service Access CIDR"
}
