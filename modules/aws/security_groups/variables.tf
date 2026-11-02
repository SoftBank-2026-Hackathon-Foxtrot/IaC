variable "name" {
  type        = string
  description = "배포별 고유 이름. root에서 검증합니다."
}

variable "tags" {
  type        = map(string)
  description = "필수 추적 메타데이터. 비밀값과 개인정보를 넣지 않습니다."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "web_ingress_cidrs" {
  type        = set(string)
  description = "앱 웹 포트에 접근할 IPv4 CIDR"
}

variable "web_ports" {
  type        = set(number)
  description = "공개할 앱 TCP 포트"
}

variable "admin_cidrs" {
  type        = set(string)
  description = "선택적 SSH 관리자 CIDR. 기본 비어 있음"
}
