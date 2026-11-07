module "metadata" {
  source        = "../../modules/metadata"
  deployment_id = var.deployment_id
  metadata      = var.metadata
}
module "vpc" {
  source               = "../../modules/aws/vpc"
  name                 = var.deployment_id
  tags                 = merge(module.metadata.common, { component = "network" })
  vpc_cidr             = var.network.vpc_cidr
  public_subnet_cidr   = var.network.public_subnet_cidr
  private_subnet_cidrs = var.network.private_subnet_cidrs
  availability_zones   = var.network.availability_zones
  # A database reachable from another cloud needs a route out of its subnets.
  data_subnets_internet_route = length(var.replication_cidrs) > 0
}
module "security_groups" {
  source                   = "../../modules/aws/security_groups"
  name                     = var.deployment_id
  tags                     = merge(module.metadata.common, { component = "network" })
  vpc_id                   = module.vpc.vpc_id
  web_ingress_cidrs        = var.web_ingress_cidrs
  web_ports                = var.web_ports
  admin_cidrs              = var.admin_cidrs
  proxy_cidrs              = var.proxy_cidrs
  enable_cloudflare_tunnel = var.enable_cloudflare_tunnel
  migration_source_cidrs   = var.migration_source_cidrs
  replication_cidrs        = var.replication_cidrs
  enable_tailscale         = var.tailscale != null
}
module "s3" {
  source        = "../../modules/aws/s3"
  bucket_name   = var.bucket_name
  force_destroy = var.force_destroy_storage
  tags          = merge(module.metadata.common, { component = "storage" })
}
module "iam" {
  source      = "../../modules/aws/iam"
  name        = var.deployment_id
  tags        = merge(module.metadata.common, { component = "identity" })
  bucket_arn  = module.s3.bucket_arn
  secret_arns = concat([aws_secretsmanager_secret.app_db.arn, module.rds.master_secret_arn], values(local.extra_secret_arns), var.tailscale == null ? [] : [var.tailscale.auth_key_secret])
}
module "ec2" {
  source                = "../../modules/aws/ec2"
  name                  = var.deployment_id
  tags                  = merge(module.metadata.common, { component = "compute" })
  ami_id                = var.ami_id != null ? var.ami_id : data.aws_ami.al2023[0].id
  instance_type         = var.sizing.compute_instance_type
  root_disk_gib         = var.sizing.compute_disk_gib
  subnet_id             = module.vpc.public_subnet_id
  security_group_id     = module.security_groups.app_id
  instance_profile_name = module.iam.instance_profile_name
  key_name              = var.key_name
  user_data             = module.app_runtime.script
  source_dest_check     = var.tailscale == null
  depends_on            = [module.vpc]
}
module "rds" {
  source                    = "../../modules/aws/rds"
  name                      = "${var.deployment_id}-db"
  tags                      = merge(module.metadata.common, { component = "database" })
  subnet_ids                = module.vpc.private_subnet_ids
  security_group_id         = module.security_groups.db_id
  instance_class            = var.sizing.db_instance_class
  storage_gib               = var.sizing.db_storage_gib
  max_storage_gib           = var.sizing.db_max_storage_gib
  multi_az                  = var.sizing.db_multi_az
  engine_version            = var.postgres_version
  database_name             = var.database_name
  deletion_protection       = var.deletion_protection
  final_snapshot_identifier = var.final_snapshot_identifier
  publicly_accessible       = length(var.replication_cidrs) > 0
}
module "elasticache" {
  source             = "../../modules/aws/elasticache"
  name               = "${var.deployment_id}-cache"
  tags               = merge(module.metadata.common, { component = "cache" })
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_id  = module.security_groups.cache_id
  node_type          = var.sizing.cache_node_type
  node_count         = var.sizing.cache_node_count
  transit_encryption = var.redis_transit_encryption
  auth_token         = var.redis_auth_token
}
