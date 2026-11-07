# Managed services in this VPC (RDS) reach the other cloud through the app VM, the Tailscale subnet
# router. Routes to the remote ranges point at its interface, so RDS can subscribe to Cloud SQL for
# a GCP → AWS database migration. The GCP router source-NATs into its VPC, so replies come back
# the same way. Mirrors environments/gcp/replication_path.tf.

variable "remote_cidrs" {
  description = "Ranges on the other side of the tailnet that this VPC's managed services connect to (the GCP app subnet, its private services range)"
  type        = list(string)
  default     = ["10.20.0.0/24", "10.21.0.0/16"]
  nullable    = false
}

locals {
  route_through_app = var.tailscale != null && var.app != null
}

resource "aws_route" "remote" {
  for_each               = local.route_through_app ? toset(var.remote_cidrs) : toset([])
  route_table_id         = module.vpc.route_table_ids[1] # private: the RDS and ElastiCache subnets
  destination_cidr_block = each.value
  network_interface_id   = module.ec2.primary_network_interface_id
}

# RDS opens the replication connection itself; its security group has no egress otherwise.
resource "aws_vpc_security_group_egress_rule" "db_to_remote" {
  for_each          = local.route_through_app ? toset(var.remote_cidrs) : toset([])
  security_group_id = module.security_groups.db_id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  description       = "RDS subscribes to the other cloud's PostgreSQL through the app VM"
}

# Packets the VM forwards for RDS arrive on its interface.
resource "aws_vpc_security_group_ingress_rule" "db_through_app" {
  count                        = local.route_through_app ? 1 : 0
  security_group_id            = module.security_groups.app_id
  referenced_security_group_id = module.security_groups.db_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "RDS replication traffic the app VM forwards to the tailnet"
}
