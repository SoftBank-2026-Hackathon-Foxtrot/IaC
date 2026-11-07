mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"}}]}"
    }
  }
}
mock_provider "google" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "cloudflare" {}
mock_provider "tailscale" {}
variables {
  gcp_project_id = "test-project"
  security_review = {
    config                 = { readOnly = true, awsRole = "application/test-app" }
    gcp_credentials_secret = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:reader-123456"
  }
}
run "review_role_permission" {
  command = plan
  plan_options { target = [module.control_plane.aws_iam_role_policy.task] }
  assert {
    condition     = local.security_review_statements[0].Resource == "arn:aws:iam::123456789012:role/application/test-app"
    error_message = "The control plane may inspect only the configured application role."
  }
}
run "writer_required" {
  command = plan
  plan_options { target = [module.control_plane.aws_iam_role_policy.task] }
  variables {
    security_review = {
      config                 = { readOnly = false, awsRole = "test-app" }
      gcp_credentials_secret = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:reader-123456"
    }
  }
  expect_failures = [var.security_review]
}
run "reject_wildcard_role" {
  command = plan
  plan_options { target = [module.control_plane.aws_iam_role_policy.task] }
  variables {
    security_review = {
      config                 = { readOnly = true, awsRole = "*" }
      gcp_credentials_secret = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:reader-123456"
    }
  }
  expect_failures = [var.security_review]
}
