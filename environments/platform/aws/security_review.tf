# This root owns the control-plane task role, including security inspection access.
locals {
  security_review_statements = var.security_review == null ? [] : [{
    Effect   = "Allow"
    Action   = ["iam:GetRolePolicy"]
    Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.security_review.config.awsRole}"
  }]
}
