resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Public PoC web entry; SSH only from explicit admin CIDRs"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-app", exposure = "public" })
}
resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL from app security group only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-db", exposure = "private" })
}
resource "aws_security_group" "cache" {
  name_prefix = "${var.name}-cache-"
  description = "Redis TLS from app security group only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-cache", exposure = "private" })
}
locals {
  web_rules = { for pair in setproduct(var.web_ingress_cidrs, var.web_ports) : "${pair[0]}:${pair[1]}" => pair }
}
resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each          = local.web_rules
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
  tags              = var.tags
}
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = var.admin_cidrs
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  tags              = var.tags
}
resource "aws_vpc_security_group_ingress_rule" "db" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = var.tags
}
resource "aws_vpc_security_group_ingress_rule" "cache" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  tags                         = var.tags
}
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = var.tags
}
resource "aws_vpc_security_group_egress_rule" "db" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = var.tags
}
resource "aws_vpc_security_group_egress_rule" "cache" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.cache.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  tags                         = var.tags
}
