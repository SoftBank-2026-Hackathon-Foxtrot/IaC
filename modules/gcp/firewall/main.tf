resource "google_compute_firewall" "web" {
  name                    = "${var.name}-web"
  network                 = var.network_id
  direction               = "INGRESS"
  priority                = 1000
  source_ranges           = var.web_ingress_cidrs
  target_service_accounts = [var.app_service_account]
  allow {
    protocol = "tcp"
    ports    = [for port in var.web_ports : tostring(port)]
  }
  description = jsonencode(var.labels)
}
resource "google_compute_firewall" "ssh" {
  count                   = length(var.admin_cidrs) > 0 ? 1 : 0
  name                    = "${var.name}-ssh"
  network                 = var.network_id
  source_ranges           = var.admin_cidrs
  target_service_accounts = [var.app_service_account]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  description = jsonencode(var.labels)
}
resource "google_compute_firewall" "https" {
  name                    = "${var.name}-https-out"
  network                 = var.network_id
  direction               = "EGRESS"
  priority                = 1000
  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [var.app_service_account]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
  description = jsonencode(var.labels)
}
resource "google_compute_firewall" "data" {
  name                    = "${var.name}-data-out"
  network                 = var.network_id
  direction               = "EGRESS"
  priority                = 1000
  destination_ranges      = [var.service_cidr]
  target_service_accounts = [var.app_service_account]
  # 3307 is the Cloud SQL connector/proxy data connection port.
  allow {
    protocol = "tcp"
    ports    = ["5432", "3307", "6378"]
  }
  description = jsonencode(var.labels)
}
resource "google_compute_firewall" "deny_other_egress" {
  name                    = "${var.name}-deny-other-out"
  network                 = var.network_id
  direction               = "EGRESS"
  priority                = 2000
  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [var.app_service_account]
  deny { protocol = "all" }
  description = jsonencode(var.labels)
}
