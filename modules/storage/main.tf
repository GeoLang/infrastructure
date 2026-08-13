# GeoLang Infrastructure - EFS Storage Module
#
# Elastic File System for persistent shared storage across
# ECS Fargate tasks. Used for TileTopia data and GeoLang cache.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_security_group_ids" {
  description = "Security groups of ECS tasks that need EFS access"
  type        = list(string)
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

variable "access_points" {
  description = "Per-workload EFS roots"
  type = map(object({
    path        = string
    uid         = number
    gid         = number
    permissions = optional(string, "0755")
  }))
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
    security_groups = var.ecs_security_group_ids
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

resource "aws_efs_access_point" "services" {
  for_each = var.access_points

  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = each.value.gid
    uid = each.value.uid
  }

  root_directory {
    path = each.value.path
    creation_info {
      owner_gid   = each.value.gid
      owner_uid   = each.value.uid
      permissions = each.value.permissions
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-ap", Workload = each.key })
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
  value       = { for name, access_point in aws_efs_access_point.services : name => access_point.id }
}

output "security_group_id" {
  description = "EFS security group ID"
  value       = aws_security_group.efs.id
}
