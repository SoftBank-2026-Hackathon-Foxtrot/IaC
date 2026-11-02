variable "account_id" {
  type        = string
  description = "실행 대상 AWS 계정. provider에서 계정 오실행을 차단합니다."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "AWS 계정은 12자리 숫자입니다."
  }
}
variable "network" {
  type        = object({ vpc_cidr = string, public_subnet_cidr = string, private_subnet_cidrs = list(string), availability_zones = list(string) })
  description = "사람이 관리하는 네트워크. CIDR 포함·중복은 render_inputs.py validate로 추가 검사합니다."
  validation {
    condition     = length(var.network.private_subnet_cidrs) == 2 && length(distinct(var.network.availability_zones)) == 2 && alltrue([for c in concat([var.network.vpc_cidr, var.network.public_subnet_cidr], var.network.private_subnet_cidrs) : can(cidrnetmask(c))])
    error_message = "유효한 IPv4 CIDR과 서로 다른 두 AZ/private subnet이 필요합니다."
  }
}
variable "ami_id" {
  type        = string
  default     = null
  description = "검토한 x86_64 AMI ID. null이면 Amazon Linux 2023 최신 x86_64 사용. 재현 가능한 배포는 ID를 고정하세요."
}
variable "key_name" {
  type        = string
  default     = null
  description = "SSH를 사용할 경우 대상 리전에 이미 있는 key pair 이름. private key는 입력하지 않습니다."
  validation {
    condition     = length(var.admin_cidrs) == 0 || var.key_name != null
    error_message = "SSH CIDR을 열려면 기존 key_name을 지정하세요."
  }
}
variable "postgres_version" {
  type        = string
  default     = "16"
  description = "PostgreSQL 16 또는 해당 minor. 실행 전 리전 지원 버전 확인. AI 입력에서 제외합니다."
  validation {
    condition     = can(regex("^16(\\.[0-9]+)?$", var.postgres_version))
    error_message = "이 초안의 parameter group은 PostgreSQL 16 전용입니다."
  }
}
variable "redis_auth_token" {
  type        = string
  sensitive   = true
  description = "TF_VAR_redis_auth_token 또는 비밀 저장소 주입. tfvars/Git/추천 JSON에 기록하지 않습니다."
}
variable "final_snapshot_identifier" {
  type        = string
  description = "DB 삭제 시 생성할 snapshot 고유 이름. 기존 snapshot과 충돌하지 않도록 사람이 지정합니다."
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = module.metadata.common }
}
data "aws_ami" "al2023" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
