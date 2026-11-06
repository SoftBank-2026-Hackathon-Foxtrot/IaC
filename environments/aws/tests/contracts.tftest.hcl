mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::test-poc-bucket", id = "test-poc-bucket" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-app" }
  }
}
run "root_wiring" {
  command = plan
  variables {
    deployment_id             = "fox-aws-poc01"
    metadata                  = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01" }
    region                    = "ap-northeast-2"
    account_id                = "123456789012"
    bucket_name               = "replace-with-globally-unique-aws-bucket"
    database_name             = "app"
    web_ingress_cidrs         = ["0.0.0.0/0"]
    web_ports                 = [80, 443]
    admin_cidrs               = []
    deletion_protection       = true
    final_snapshot_identifier = "fox-aws-poc01-final-unique"
    network                   = { "vpc_cidr" = "10.20.0.0/16", "public_subnet_cidr" = "10.20.0.0/24", "private_subnet_cidrs" = ["10.20.10.0/24", "10.20.11.0/24"], "availability_zones" = ["ap-northeast-2a", "ap-northeast-2c"] }
    sizing                    = { "compute_instance_type" = "t3.small", "compute_disk_gib" = 30, "db_instance_class" = "db.t3.micro", "db_storage_gib" = 20, "db_max_storage_gib" = 100, "db_multi_az" = false, "cache_node_type" = "cache.t3.micro", "cache_node_count" = 1 }
    ami_id                    = "ami-1234567890abcdef0"
    redis_auth_token          = "TESTONLYnotarealsecret123456789"
  }
  assert {
    condition     = output.handoff.cloud == "aws" && output.handoff.schema_version == 1
    error_message = "AWS handoff contract must remain stable."
  }
}
run "reject_open_ssh" {
  command = plan
  variables {
    deployment_id             = "fox-aws-poc01"
    metadata                  = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01" }
    region                    = "ap-northeast-2"
    account_id                = "123456789012"
    bucket_name               = "replace-with-globally-unique-aws-bucket"
    database_name             = "app"
    web_ingress_cidrs         = ["0.0.0.0/0"]
    web_ports                 = [80, 443]
    admin_cidrs               = ["0.0.0.0/0"]
    deletion_protection       = true
    final_snapshot_identifier = "fox-aws-poc01-final-unique"
    network                   = { "vpc_cidr" = "10.20.0.0/16", "public_subnet_cidr" = "10.20.0.0/24", "private_subnet_cidrs" = ["10.20.10.0/24", "10.20.11.0/24"], "availability_zones" = ["ap-northeast-2a", "ap-northeast-2c"] }
    sizing                    = { "compute_instance_type" = "t3.small", "compute_disk_gib" = 30, "db_instance_class" = "db.t3.micro", "db_storage_gib" = 20, "db_max_storage_gib" = 100, "db_multi_az" = false, "cache_node_type" = "cache.t3.micro", "cache_node_count" = 1 }
    ami_id                    = "ami-1234567890abcdef0"
    redis_auth_token          = "TESTONLYnotarealsecret123456789"
    key_name                  = "existing-key"
  }
  expect_failures = [var.admin_cidrs]
}
run "reject_database_public_port" {
  command = plan
  variables {
    deployment_id             = "fox-aws-poc01"
    metadata                  = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01" }
    region                    = "ap-northeast-2"
    account_id                = "123456789012"
    bucket_name               = "replace-with-globally-unique-aws-bucket"
    database_name             = "app"
    web_ingress_cidrs         = ["0.0.0.0/0"]
    web_ports                 = [5432]
    admin_cidrs               = []
    deletion_protection       = true
    final_snapshot_identifier = "fox-aws-poc01-final-unique"
    network                   = { "vpc_cidr" = "10.20.0.0/16", "public_subnet_cidr" = "10.20.0.0/24", "private_subnet_cidrs" = ["10.20.10.0/24", "10.20.11.0/24"], "availability_zones" = ["ap-northeast-2a", "ap-northeast-2c"] }
    sizing                    = { "compute_instance_type" = "t3.small", "compute_disk_gib" = 30, "db_instance_class" = "db.t3.micro", "db_storage_gib" = 20, "db_max_storage_gib" = 100, "db_multi_az" = false, "cache_node_type" = "cache.t3.micro", "cache_node_count" = 1 }
    ami_id                    = "ami-1234567890abcdef0"
    redis_auth_token          = "TESTONLYnotarealsecret123456789"
  }
  expect_failures = [var.web_ports]
}
run "reject_unreviewed_size" {
  command = plan
  variables {
    deployment_id             = "fox-aws-poc01"
    metadata                  = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01" }
    region                    = "ap-northeast-2"
    account_id                = "123456789012"
    bucket_name               = "replace-with-globally-unique-aws-bucket"
    database_name             = "app"
    web_ingress_cidrs         = ["0.0.0.0/0"]
    web_ports                 = [80, 443]
    admin_cidrs               = []
    deletion_protection       = true
    final_snapshot_identifier = "fox-aws-poc01-final-unique"
    network                   = { "vpc_cidr" = "10.20.0.0/16", "public_subnet_cidr" = "10.20.0.0/24", "private_subnet_cidrs" = ["10.20.10.0/24", "10.20.11.0/24"], "availability_zones" = ["ap-northeast-2a", "ap-northeast-2c"] }
    sizing                    = { "compute_instance_type" = "p5.48xlarge" }
    ami_id                    = "ami-1234567890abcdef0"
    redis_auth_token          = "TESTONLYnotarealsecret123456789"
  }
  expect_failures = [var.sizing]
}
run "private_database" {
  command = plan
  module { source = "../../modules/aws/rds" }
  variables {
    name                      = "test-db"
    tags                      = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01", "deployment_id" = "test-poc", "managed_by" = "terraform", "template_version" = "v0-1", "security_profile" = "public-app-private-data-v1" }
    subnet_ids                = ["subnet-123", "subnet-456"]
    security_group_id         = "sg-123"
    instance_class            = "db.t3.micro"
    storage_gib               = 20
    max_storage_gib           = 100
    multi_az                  = false
    engine_version            = "16"
    database_name             = "app"
    deletion_protection       = true
    final_snapshot_identifier = "test-final"
  }
  assert {
    condition     = aws_db_instance.this.publicly_accessible == false && aws_db_instance.this.storage_encrypted
    error_message = "RDS must stay private and encrypted."
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password && aws_db_instance.this.deletion_protection && !aws_db_instance.this.skip_final_snapshot
    error_message = "RDS credentials and deletion controls must not regress."
  }
}
run "private_storage" {
  command = plan
  module { source = "../../modules/aws/s3" }
  variables {
    bucket_name = "test-poc-bucket"
    tags        = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01", "deployment_id" = "test-poc", "managed_by" = "terraform", "template_version" = "v0-1", "security_profile" = "public-app-private-data-v1" }
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_policy && aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "Bucket must not be public."
  }
  assert {
    condition     = aws_s3_bucket.this.force_destroy == false && aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning and nonempty-bucket deletion protection are required."
  }
}
run "cache_requires_auth_and_tls" {
  command = plan
  module { source = "../../modules/aws/elasticache" }
  variables {
    name              = "test-cache"
    tags              = { "project" = "foxtrot", "environment" = "poc", "owner" = "platform-team", "cost_center" = "hackathon", "workload" = "web", "migration_id" = "mig-001", "data_class" = "internal", "expires_on" = "2026-12-01", "deployment_id" = "test-poc", "managed_by" = "terraform", "template_version" = "v0-1", "security_profile" = "public-app-private-data-v1" }
    subnet_ids        = ["subnet-123", "subnet-456"]
    security_group_id = "sg-123"
    node_type         = "cache.t3.micro"
    node_count        = 2
    auth_token        = "TESTONLYnotarealsecret123456789"
  }
  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled && aws_elasticache_replication_group.this.at_rest_encryption_enabled && aws_elasticache_replication_group.this.auth_token_update_strategy == "SET"
    error_message = "Redis encryption/auth cannot be relaxed."
  }
  assert {
    condition     = aws_elasticache_replication_group.this.automatic_failover_enabled && aws_elasticache_replication_group.this.multi_az_enabled
    error_message = "Multiple nodes must enable failover."
  }
  assert {
    condition     = { for p in aws_elasticache_parameter_group.migration.parameter : p.name => p.value } == { "notify-keyspace-events" = "KEA", "maxmemory-policy" = "noeviction" } && aws_elasticache_replication_group.this.parameter_group_name == aws_elasticache_parameter_group.migration.name
    error_message = "Migration requires attached keyspace notifications and noeviction."
  }

}

run "management_enabled" {
  command = plan
  module { source = "../../modules/aws/security_groups" }
  variables {
    name                     = "test-poc"
    web_ingress_cidrs        = ["0.0.0.0/0"]
    web_ports                = [80, 443]
    admin_cidrs              = []
    tags                     = {}
    vpc_id                   = "vpc-123"
    proxy_cidrs              = ["10.50.0.10/32"]
    enable_cloudflare_tunnel = true
    migration_source_cidrs   = ["10.20.10.5/32"]
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.proxy) == 2 && aws_vpc_security_group_egress_rule.proxy["10.50.0.10/32:6432"].to_port == 6432 && aws_vpc_security_group_ingress_rule.migration_db["10.20.10.5/32"].from_port == 5432 && aws_vpc_security_group_ingress_rule.migration_cache["10.20.10.5/32"].to_port == 6379 && length(aws_vpc_security_group_egress_rule.cloudflare_tunnel) == 2
    error_message = "Management paths must be explicit, port-scoped and opt-in."
  }
}

run "management_default_closed" {
  command = plan
  module { source = "../../modules/aws/security_groups" }
  variables {
    name              = "test-poc"
    web_ingress_cidrs = ["0.0.0.0/0"]
    web_ports         = [80, 443]
    admin_cidrs       = []
    tags              = {}
    vpc_id            = "vpc-123"
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.proxy) == 0 && length(aws_vpc_security_group_ingress_rule.migration_db) == 0 && length(aws_vpc_security_group_ingress_rule.migration_cache) == 0 && length(aws_vpc_security_group_egress_rule.cloudflare_tunnel) == 0
    error_message = "Management paths must be explicit, port-scoped and opt-in."
  }
}

run "management_reject_public" {
  command = plan
  module { source = "../../modules/aws/security_groups" }
  variables {
    name                     = "test-poc"
    web_ingress_cidrs        = ["0.0.0.0/0"]
    web_ports                = [80, 443]
    admin_cidrs              = []
    tags                     = {}
    vpc_id                   = "vpc-123"
    proxy_cidrs              = ["0.0.0.0/0"]
    enable_cloudflare_tunnel = true
  }
  expect_failures = [var.proxy_cidrs]
}
