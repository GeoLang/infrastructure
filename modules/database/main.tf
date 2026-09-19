# GeoLang Infrastructure - Database Module (Aurora PostgreSQL Serverless v2)
#
# One Aurora PostgreSQL cluster with a single serverless writer that scales to
# zero. Private subnets, no public access.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "client_security_group_ids" {
  description = "Security groups of tasks that need database access"
  type        = list(string)
}

variable "max_capacity" {
  description = "Aurora Serverless v2 maximum capacity in ACUs"
  type        = number
  default     = 2
}

variable "db_name" {
  type    = string
  default = "ptolemy"
}

variable "db_username" {
  type    = string
  default = "ptolemy"
}

variable "bastion_security_group_id" {
  description = "Security group of bastion host for DB access (optional)"
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Subnet Group ────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-subnet-group" })
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.client_security_group_ids) > 0 ? [1] : []
    content {
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = var.client_security_group_ids
      description     = "PostgreSQL from platform tasks"
    }
  }

  # Allow PostgreSQL from bastion host (when enabled)
  dynamic "ingress" {
    for_each = var.bastion_security_group_id != "" ? [1] : []
    content {
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [var.bastion_security_group_id]
      description     = "PostgreSQL from bastion host"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Aurora Cluster ──────────────────────────────────────────────────────────

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${var.name_prefix}-postgis"

  engine         = "aurora-postgresql"
  engine_version = "17.10"
  engine_mode    = "provisioned"

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = var.max_capacity
    seconds_until_auto_pause = 300
  }

  database_name               = var.db_name
  master_username             = var.db_username
  manage_master_user_password = true

  storage_encrypted = true
  # the refresh lambda creates the agora database through the Data API
  enable_http_endpoint = true

  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.rds.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.postgis.name

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false
  copy_tags_to_snapshot   = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgis" })
}

resource "aws_rds_cluster_instance" "main" {
  identifier         = "${var.name_prefix}-postgis-1"
  cluster_identifier = aws_rds_cluster.main.id

  instance_class = "db.serverless"
  engine         = aws_rds_cluster.main.engine
  engine_version = aws_rds_cluster.main.engine_version

  publicly_accessible        = false
  auto_minor_version_upgrade = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgis-1" })
}

# ─── Parameter Group ─────────────────────────────────────────────────────────

resource "aws_rds_cluster_parameter_group" "postgis" {
  name_prefix = "${var.name_prefix}-postgis-"
  family      = "aurora-postgresql17"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # hosted database URLs need verify-full and the AWS RDS CA bundle
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "endpoint" {
  description = "Aurora writer endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "identifier" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.main.id
}

output "instance_identifier" {
  description = "Aurora writer instance identifier"
  value       = aws_rds_cluster_instance.main.identifier
}

output "arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.main.arn
}

output "address" {
  description = "Aurora writer hostname"
  value       = aws_rds_cluster.main.endpoint
}

output "port" {
  description = "Aurora port"
  value       = aws_rds_cluster.main.port
}

output "master_user_secret_arn" {
  description = "RDS-managed master credential secret ARN"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Aurora security group ID"
  value       = aws_security_group.rds.id
}
