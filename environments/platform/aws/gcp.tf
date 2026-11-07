# GCP access for platform services. Phase 1 uses service account keys kept in Secrets Manager
# (Workload Identity Federation from Fargate needs a credential helper; later).
locals {
  gcp_accounts = {
    db          = { roles = ["roles/cloudsql.viewer"], description = "DB adaptor: read Cloud SQL instance metadata" }
    object      = { roles = ["roles/storage.admin", "roles/pubsub.editor"], description = "object-migration: copy into and route GCS buckets, follow GCS sources through Pub/Sub" }
    provisioner = { roles = ["roles/editor", "roles/resourcemanager.projectIamAdmin", "roles/iam.serviceAccountAdmin", "roles/secretmanager.admin", "roles/servicenetworking.networksAdmin"], description = "provisioner: create app environments" }
  }
  gcp_roles = merge([for k, v in local.gcp_accounts : { for r in v.roles : "${k}:${r}" => { account = k, role = r } }]...)
}
resource "google_service_account" "platform" {
  for_each     = local.gcp_accounts
  account_id   = "foxtrot-platform-${each.key}"
  display_name = "Foxtrot platform ${each.key}"
  description  = each.value.description
}
resource "google_project_iam_member" "platform" {
  for_each = local.gcp_roles
  project  = var.gcp_project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.platform[each.value.account].email}"
}
# A GCS bucket notification is published by the project's Cloud Storage service agent. With the
# publisher role on the project it can post to every object-migration topic, so the server need
# not set an IAM policy per topic (pubsub.editor cannot; the server tolerates that refusal).
data "google_storage_project_service_account" "gcs" {
  project = var.gcp_project_id
}
resource "google_project_iam_member" "gcs_agent_publisher" {
  project = var.gcp_project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}
resource "google_service_account_key" "platform" {
  for_each           = local.gcp_accounts
  service_account_id = google_service_account.platform[each.key].name
}
resource "aws_secretsmanager_secret" "gcp" {
  for_each                = local.gcp_accounts
  name                    = "foxtrot/platform/gcp-${each.key}-credentials"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "gcp" {
  for_each      = local.gcp_accounts
  secret_id     = aws_secretsmanager_secret.gcp[each.key].id
  secret_string = base64decode(google_service_account_key.platform[each.key].private_key)
}

# The workload token for app VMs on GCP: they read secrets from Secret Manager in their project,
# so the token the control plane checks has a copy there. The provisioner points apps at it.
resource "google_secret_manager_secret" "workload_token" {
  secret_id = "foxtrot-platform-workload-token"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "workload_token" {
  secret      = google_secret_manager_secret.workload_token.id
  secret_data = random_password.generated["workload-token"].result
}
