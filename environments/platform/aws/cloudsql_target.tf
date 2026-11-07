# The chiikawa DB migration target: the GCP env's Cloud SQL (private IP only), registered with the
# DB adaptor. Phase 1 values; the source is the AWS env's RDS (environments/aws, db-operator secret).
#
# The adaptor and PgBouncer connect with verify-full. The server certificate names the instance by
# a *.sql.goog DNS name that resolves only inside Google's network, so the platform VPC gets a
# private zone for it pointing at the private IP, and the instance's CA joins db-proxy's trust.

variable "chiikawa_cloudsql" {
  description = "The chiikawa Cloud SQL target (IDs and addresses, not secret)"
  type = object({
    instance      = string # Cloud SQL instance name
    cert_dns_name = string # DNS name in the server certificate
    private_ip    = string
    admin_user    = string
    admin_secret  = string # GCP Secret Manager secret ID of the admin password
    database      = string
  })
  default = {
    instance      = "chiikawa-gcp-1975-db"
    cert_dns_name = "27-d9eb3522-319b-442c-97dc-48420699f4f7.asia-northeast3.sql.goog"
    private_ip    = "10.21.0.3"
    admin_user    = "platformadmin"
    admin_secret  = "chiikawa-gcp-1975-db-admin"
    database      = "app"
  }
}

resource "aws_route53_zone" "chiikawa_cloudsql" {
  name    = var.chiikawa_cloudsql.cert_dns_name
  comment = "Cloud SQL ${var.chiikawa_cloudsql.instance}: its certificate name, for verify-full from the platform"
  vpc {
    vpc_id = aws_vpc.this.id
  }
}
resource "aws_route53_record" "chiikawa_cloudsql" {
  zone_id = aws_route53_zone.chiikawa_cloudsql.zone_id
  name    = var.chiikawa_cloudsql.cert_dns_name
  type    = "A"
  ttl     = 300
  records = [var.chiikawa_cloudsql.private_ip]
}

data "google_sql_ca_certs" "chiikawa" {
  instance = var.chiikawa_cloudsql.instance
}

data "google_secret_manager_secret_version" "chiikawa_cloudsql_admin" {
  secret = var.chiikawa_cloudsql.admin_secret
}
locals {
  cloudsql_ca_pem = join("", [for c in data.google_sql_ca_certs.chiikawa.certs : c.cert])
  cloudsql_admin_auth = format("%s:%s", urlencode(var.chiikawa_cloudsql.admin_user),
  urlencode(data.google_secret_manager_secret_version.chiikawa_cloudsql_admin.secret_data))
  cloudsql_address = "${var.chiikawa_cloudsql.cert_dns_name}:5432/${var.chiikawa_cloudsql.database}"
}

# Read by the adaptor through the catalog's secret_ref (db:chiikawa-gcp-1975). writerPassword is the
# AWS app role's: both databases serve the app the same login.
resource "aws_secretsmanager_secret" "chiikawa_cloudsql_operator" {
  name                    = "foxtrot/app/chiikawa-gcp-1975/db-operator"
  description             = "DB migration adaptor credentials for the chiikawa Cloud SQL target"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "chiikawa_cloudsql_operator" {
  secret_id = aws_secretsmanager_secret.chiikawa_cloudsql_operator.id
  secret_string = jsonencode({
    adminDsn       = "postgresql://${local.cloudsql_admin_auth}@${local.cloudsql_address}?sslmode=verify-full&sslrootcert=/run/foxtrot/server-ca.crt"
    replicationDsn = "postgresql://${local.cloudsql_admin_auth}@${local.cloudsql_address}?sslmode=require"
    writerPassword = data.aws_secretsmanager_secret_version.chiikawa_app_db.secret_string
  })
}

output "chiikawa_cloudsql_target" {
  value = {
    secret_ref = aws_secretsmanager_secret.chiikawa_cloudsql_operator.arn
    route_host = var.chiikawa_cloudsql.cert_dns_name
  }
}
