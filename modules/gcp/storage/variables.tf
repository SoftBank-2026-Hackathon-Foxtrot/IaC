variable "name" {
  type        = string
  description = "전역 고유 bucket 이름"
}

variable "labels" {
  type        = map(string)
  description = "필수 추적 메타데이터. 비밀값과 개인정보를 넣지 않습니다."
}

variable "region" {
  type        = string
  description = "bucket location"
}
