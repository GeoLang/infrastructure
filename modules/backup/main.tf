# GeoLang Infrastructure — AWS Backup Module
#
# Automated backup vault with lifecycle policies for RDS snapshots
# and optional cross-region copy for disaster recovery.

variable "name_prefix" {
  type = string
}

variable "rds_arn" {
  description = "RDS instance ARN to back up"
  type        = string
}

variable "efs_arn" {
  description = "EFS file system ARN to back up (optional)"
  type        = string
  default     = ""
}

variable "backup_schedule" {
  description = "Cron expression for backup schedule"
  type        = string
  default     = "cron(0 3 * * ? *)" # Daily at 3 AM UTC
}

variable "retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30
}

variable "enable_cross_region" {
  description = "Enable cross-region backup copy for DR"
  type        = bool
  default     = false
}

variable "dr_region" {
  description = "DR region for cross-region backup copy"
  type        = string
  default     = "us-west-2"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Backup Vault ─────────────────────────────────────────────────────────────

resource "aws_backup_vault" "main" {
  name = "${var.name_prefix}-vault"
  tags = merge(var.tags, { Name = "${var.name_prefix}-backup-vault" })
}

# ─── IAM Role for Backup ─────────────────────────────────────────────────────

resource "aws_iam_role" "backup" {
  name = "${var.name_prefix}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ─── Backup Plan ──────────────────────────────────────────────────────────────

resource "aws_backup_plan" "main" {
  name = "${var.name_prefix}-daily"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = var.backup_schedule

    lifecycle {
      delete_after = var.retention_days
    }

    dynamic "copy_action" {
      for_each = var.enable_cross_region ? [1] : []
      content {
        destination_vault_arn = "arn:aws:backup:${var.dr_region}:${data.aws_caller_identity.current.account_id}:backup-vault:Default"
        lifecycle {
          delete_after = var.retention_days
        }
      }
    }
  }

  # Weekly backup with longer retention
  rule {
    rule_name         = "weekly-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 ? * SUN *)" # Sunday 3 AM

    lifecycle {
      delete_after = var.retention_days * 3 # 90 days for weekly
    }
  }

  tags = var.tags
}

data "aws_caller_identity" "current" {}

# ─── Backup Selection (RDS) ──────────────────────────────────────────────────

resource "aws_backup_selection" "rds" {
  name         = "${var.name_prefix}-rds"
  plan_id      = aws_backup_plan.main.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = compact([
    var.rds_arn,
    var.efs_arn,
  ])
}

# ─── Vault Lock (optional, for compliance) ────────────────────────────────────
# Uncomment for WORM compliance (prevents backup deletion)
# resource "aws_backup_vault_lock_configuration" "main" {
#   backup_vault_name   = aws_backup_vault.main.name
#   min_retention_days  = 7
#   max_retention_days  = 365
# }

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "vault_name" {
  description = "Backup vault name"
  value       = aws_backup_vault.main.name
}

output "vault_arn" {
  description = "Backup vault ARN"
  value       = aws_backup_vault.main.arn
}

output "plan_id" {
  description = "Backup plan ID"
  value       = aws_backup_plan.main.id
}
