# GeoLang Infrastructure — Database Module (RDS PostGIS)
#
# Provisions an RDS PostgreSQL instance with PostGIS extensions.
# Uses private subnets with no public access.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_security_group_id" {
  description = "Security group of ECS tasks that need DB access"
  type        = string
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "ptolemy"
}

variable "db_username" {
  type    = string
  default = "ptolemy"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "multi_az" {
  type    = bool
  default = false
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

  # Only allow PostgreSQL from ECS tasks
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
    description     = "PostgreSQL from ECS tasks"
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

# ─── RDS Instance ────────────────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-postgis"

  engine         = "postgres"
  engine_version = "16.4"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false
  copy_tags_to_snapshot  = true
  backup_retention_period = 7

  # PostGIS extensions are available on standard PostgreSQL engine
  parameter_group_name = aws_db_parameter_group.postgis.name

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgis" })
}

# ─── Parameter Group ─────────────────────────────────────────────────────────

resource "aws_db_parameter_group" "postgis" {
  name_prefix = "${var.name_prefix}-postgis-"
  family      = "postgres16"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  parameter {
    name  = "rds.force_ssl"
    value = "0" # Disable for internal VPC traffic; enable in production
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.main.endpoint
}

output "arn" {
  description = "RDS instance ARN"
  value       = aws_db_instance.main.arn
}

output "address" {
  description = "RDS hostname"
  value       = aws_db_instance.main.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "database_url" {
  description = "Full PostgreSQL connection string"
  value       = "postgres://${var.db_username}:${var.db_password}@${aws_db_instance.main.endpoint}/${var.db_name}"
  sensitive   = true
}

output "security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}
