terraform {
  required_providers { aws = { source = "hashicorp/aws" } }
}
resource "aws_s3_bucket" "app" { bucket = "test-plan-unknown-arn" }
module "service" {
  source              = "../../.."
  name                = "unknown-policy"
  cluster_id          = "arn:aws:ecs:ap-northeast-2:123456789012:cluster/test"
  subnet_ids          = ["subnet-12345678"]
  security_group_ids  = ["sg-12345678"]
  namespace_id        = "ns-12345678"
  log_group           = "/test"
  region              = "ap-northeast-2"
  containers          = [{ name = "api", image = "example/app:test" }]
  task_policy_enabled = true
  task_policy         = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.app.arn}/*" }] })
}
output "name" { value = module.service.dns_name }
