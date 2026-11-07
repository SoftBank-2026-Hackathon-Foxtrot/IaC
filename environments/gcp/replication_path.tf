# Managed services in this VPC (Cloud SQL, Memorystore) reach the other cloud through the app VM,
# the Tailscale subnet router. Routes to the remote ranges point at it, and the private services
# peering exports them, so Cloud SQL can subscribe to RDS for the DB migration. The VM source-NATs
# into the remote VPC, so replies come back the same way.

variable "remote_cidrs" {
  description = "Ranges on the other side of the tailnet that this VPC's managed services connect to (the AWS app VPC, the platform VPC)"
  type        = list(string)
  default     = ["10.10.0.0/16", "10.30.0.0/16"]
  nullable    = false
}

locals {
  route_through_app = var.tailscale != null && var.app != null
}

resource "google_compute_route" "remote" {
  for_each          = local.route_through_app ? toset(var.remote_cidrs) : toset([])
  name              = "${var.deployment_id}-via-app-${replace(replace(each.value, ".", "-"), "/", "-")}"
  network           = module.network.network_id
  dest_range        = each.value
  next_hop_instance = module.compute.instance_id
  priority          = 900
}

resource "google_compute_network_peering_routes_config" "private_services" {
  count                = local.route_through_app ? 1 : 0
  network              = module.network.network_name
  peering              = module.network.private_services_peering_name
  export_custom_routes = true
  import_custom_routes = false
}

# Packets the VM forwards for Cloud SQL and Memorystore arrive on its interface.
resource "google_compute_firewall" "services_through_app" {
  count                   = local.route_through_app ? 1 : 0
  name                    = "${var.deployment_id}-services-through-app"
  network                 = module.network.network_id
  direction               = "INGRESS"
  source_ranges           = ["${var.network.service_range_address}/${var.network.service_range_prefix}"]
  target_service_accounts = [module.iam.service_account_email]
  allow {
    protocol = "tcp"
    ports    = ["5432", "6379"]
  }
}
