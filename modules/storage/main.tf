# GeoLang Infrastructure — EFS Storage Module
#
# Elastic File System for persistent shared storage across
# ECS Fargate tasks. Used for TileTopia data, GeoLang cache,
# and Letta agent memory.

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
  description = "Security group of ECS tasks that need EFS access"
  type        = string
}

variable "performance_mode" {
  description = "EFS performance mode (generalPurpose or maxIO)"
  type        = string
  default     = "generalPurpose"
}

variable "throughput_mode" {
  description = "EFS throughput mode (bursting, provisioned, elastic)"
  type        = string
  default     = "elastic"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "efs" {
  name_prefix = "${var.name_prefix}-efs-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
    description     = "NFS from ECS tasks"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-efs-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── EFS File System ─────────────────────────────────────────────────────────

resource "aws_efs_file_system" "main" {
  creation_token   = var.name_prefix
  encrypted        = true
  performance_mode = var.performance_mode
  throughput_mode  = var.throughput_mode

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-efs" })
}

# ─── Mount Targets (one per AZ) ──────────────────────────────────────────────

resource "aws_efs_mount_target" "main" {
  count = length(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# ─── Access Points (per-service isolation) ────────────────────────────────────

resource "aws_efs_access_point" "tiletopia" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/tiletopia"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tiletopia-ap", Service = "tiletopia" })
}

resource "aws_efs_access_point" "geolang" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/geolang"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-geolang-ap", Service = "geolang" })
}

resource "aws_efs_access_point" "letta" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = 0
    uid = 0
  }

  root_directory {
    path = "/letta"
    creation_info {
      owner_gid   = 0
      owner_uid   = 0
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-letta-ap", Service = "letta" })
}

# ─── EFS Backup Policy ───────────────────────────────────────────────────────

resource "aws_efs_backup_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  backup_policy {
    status = "ENABLED"
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "file_system_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.main.id
}

output "file_system_arn" {
  description = "EFS file system ARN"
  value       = aws_efs_file_system.main.arn
}

output "access_points" {
  description = "EFS access point IDs per service"
  value = {
    tiletopia = aws_efs_access_point.tiletopia.id
    geolang   = aws_efs_access_point.geolang.id
    letta     = aws_efs_access_point.letta.id
  }
}

output "security_group_id" {
  description = "EFS security group ID"
  value       = aws_security_group.efs.id
}
