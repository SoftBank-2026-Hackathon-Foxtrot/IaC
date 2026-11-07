# Secrets an app VM needs from the other cloud. A VM reads only its own cloud's secret store, so
# the platform keeps a copy there. Phase 1: the chiikawa app (AWS env chiikawa-aws-3e3d, GCP env
# chiikawa-gcp-1975); the provisioner gives them to the apps as secretEnv.
#
#   GCS HMAC secret → AWS: after the object cutover the AWS app writes receipts to the GCS bucket
#                          (STORAGE_GCS_ACCESS_KEY_ID / STORAGE_GCS_SECRET_ACCESS_KEY, app/objroute.py).
#   app DB password → GCP: both apps reach the one database through db-proxy.internal, and
#                          PgBouncer serves the app role with the AWS environment's password.
#   S3 key          → GCP: in a GCP → AWS object run the GCP app reads the S3 target and, after the
#                          cutover, its workers write receipts there (STORAGE_S3_ACCESS_KEY_ID /
#                          STORAGE_S3_SECRET_ACCESS_KEY). A GCP VM has no AWS role, so it gets a key
#                          of an IAM user that can use only the AWS env's receipts bucket.

variable "chiikawa_cross_cloud" {
  description = "Secrets copied between the chiikawa app environments (IDs are not secret)"
  type = object({
    gcs_hmac_secret   = string # GCP Secret Manager secret ID of the GCP env's storage HMAC secret
    aws_app_db_secret = string # Secrets Manager ARN of the AWS env's app DB password
    aws_bucket        = string # the AWS env's receipts bucket, for the GCP app's S3 key
  })
  default = {
    gcs_hmac_secret   = "chiikawa-gcp-1975-storage-hmac"
    aws_app_db_secret = "arn:aws:secretsmanager:ap-northeast-2:952561150367:secret:chiikawa-aws-3e3d-app-db-ac5d4bec769a50c011141f06b7-JOakrS"
    aws_bucket        = "foxtrot-chiikawa-aws-3e3d"
  }
}

data "google_secret_manager_secret_version" "chiikawa_gcs_hmac" {
  secret = var.chiikawa_cross_cloud.gcs_hmac_secret
}
resource "aws_secretsmanager_secret" "chiikawa_gcs_hmac" {
  name                    = "foxtrot/app/chiikawa/gcs-hmac-secret"
  description             = "GCS HMAC secret of the chiikawa GCP env, for the AWS app VM"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "chiikawa_gcs_hmac" {
  secret_id     = aws_secretsmanager_secret.chiikawa_gcs_hmac.id
  secret_string = data.google_secret_manager_secret_version.chiikawa_gcs_hmac.secret_data
}

data "aws_secretsmanager_secret_version" "chiikawa_app_db" {
  secret_id = var.chiikawa_cross_cloud.aws_app_db_secret
}
resource "google_secret_manager_secret" "chiikawa_app_db" {
  secret_id = "foxtrot-app-db-password-chiikawa"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "chiikawa_app_db" {
  secret      = google_secret_manager_secret.chiikawa_app_db.id
  secret_data = data.aws_secretsmanager_secret_version.chiikawa_app_db.secret_string
}

resource "aws_iam_user" "chiikawa_gcp_s3" {
  name = "foxtrot-app-chiikawa-gcp-s3"
  path = "/foxtrot/apps/"
}
resource "aws_iam_user_policy" "chiikawa_gcp_s3" {
  name = "receipts-bucket"
  user = aws_iam_user.chiikawa_gcp_s3.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = "arn:aws:s3:::${var.chiikawa_cross_cloud.aws_bucket}" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${var.chiikawa_cross_cloud.aws_bucket}/*" },
    ]
  })
}
resource "aws_iam_access_key" "chiikawa_gcp_s3" {
  user = aws_iam_user.chiikawa_gcp_s3.name
}
resource "google_secret_manager_secret" "chiikawa_s3_secret" {
  secret_id = "foxtrot-app-s3-secret-chiikawa"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "chiikawa_s3_secret" {
  secret      = google_secret_manager_secret.chiikawa_s3_secret.id
  secret_data = aws_iam_access_key.chiikawa_gcp_s3.secret
}

output "chiikawa_cross_cloud" {
  value = {
    aws_gcs_hmac_secret_ref = aws_secretsmanager_secret.chiikawa_gcs_hmac.arn
    gcp_app_db_secret_ref   = google_secret_manager_secret.chiikawa_app_db.id
    # The GCP app's env STORAGE_S3_ACCESS_KEY_ID (an access key ID is not secret) and secretEnv
    # STORAGE_S3_SECRET_ACCESS_KEY.
    gcp_s3_access_key_id = aws_iam_access_key.chiikawa_gcp_s3.id
    gcp_s3_secret_ref    = google_secret_manager_secret.chiikawa_s3_secret.id
  }
}
