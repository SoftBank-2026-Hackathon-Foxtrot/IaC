terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
  # bucket comes from -backend-config (it carries the account ID):
  #   terraform init -backend-config="bucket=foxtrot-provisioner-state-<account>"
  backend "s3" {
    key          = "platform/aws.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "foxtrot", managed_by = "terraform", component = "platform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

provider "google" {
  project = var.gcp_project_id
  region  = "asia-northeast3"
}
