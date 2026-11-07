mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"}}]}"
    }
  }
}
variables {
  name               = "test"
  cluster_id         = "arn:aws:ecs:ap-northeast-2:123456789012:cluster/test"
  subnet_ids         = ["subnet-12345678"]
  security_group_ids = ["sg-12345678"]
  namespace_id       = "ns-12345678"
  log_group          = "/test"
  region             = "ap-northeast-2"
  containers = [{
    name  = "api"
    image = "example/app:test"
    secrets = {
      PASSWORD = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:db-123456:password::"
      TOKEN    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:db-123456:token:AWSCURRENT:"
    }
    health = ["CMD", "python", "-c", "print('healthy')"]
  }]
}
run "secret_selectors" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role_policy.execution_secrets[0].policy).Statement[0].Resource == ["arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:db-123456"]
    error_message = "IAM must grant access to the secret ARN, without JSON key or version selectors."
  }
  assert {
    condition     = length(aws_iam_role_policy.task) == 0
    error_message = "Omitting a task policy must not create one."
  }
}
run "explicit_policy" {
  command = plan
  variables {
    task_policy_enabled = true
    task_policy         = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"iam:GetRolePolicy\",\"Resource\":\"arn:aws:iam::123456789012:role/app\"}]}"
  }
  assert {
    condition     = length(aws_iam_role_policy.task) == 1
    error_message = "An enabled task policy must be planned."
  }
}
run "explicit_disabled" {
  command = plan
  variables {
    task_policy_enabled = false
    task_policy         = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
  assert {
    condition     = length(aws_iam_role_policy.task) == 0
    error_message = "A known false switch must suppress policy creation."
  }
}

run "policy_with_unknown_resource_arn" {
  command = plan
  module { source = "./tests/fixtures/unknown-policy" }
  assert {
    condition     = output.name == "unknown-policy.internal"
    error_message = "The first plan must work even when the policy resource ARN is unknown."
  }
}
