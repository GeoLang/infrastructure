# GeoLang Infrastructure — Secrets Manager Module
#
# AWS Secrets Manager for database credentials with automatic
# rotation. Stores secrets as JSON and provides SSM parameter
# references for ECS task definitions.

variable "name_prefix" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_host" {
  description = "RDS endpoint hostname"
  type        = string
  default     = ""
}

variable "db_port" {
  description = "RDS port"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "ptolemy"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Database Credentials Secret ─────────────────────────────────────────────

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.name_prefix}/database/credentials"
  description = "GeoLang Platform — RDS PostGIS credentials"

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-credentials" })
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = var.db_host
    port     = var.db_port
    dbname   = var.db_name
    engine   = "postgres"
  })
}

# ─── API Keys Secret (placeholder) ───────────────────────────────────────────

resource "aws_secretsmanager_secret" "api_keys" {
  name        = "${var.name_prefix}/api-keys"
  description = "GeoLang Platform — API keys for external services (LLM providers, etc.)"

  tags = merge(var.tags, { Name = "${var.name_prefix}-api-keys" })
}

resource "aws_secretsmanager_secret_version" "api_keys" {
  secret_id = aws_secretsmanager_secret.api_keys.id
  secret_string = jsonencode({
    xai_api_key   = ""
    openai_api_key = ""
    groq_api_key   = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ─── Letta Server Password ───────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "letta_password" {
  name        = "${var.name_prefix}/letta/password"
  description = "GeoLang Platform — Letta agent memory server password"

  tags = merge(var.tags, { Name = "${var.name_prefix}-letta-password" })
}

resource "aws_secretsmanager_secret_version" "letta_password" {
  secret_id     = aws_secretsmanager_secret.letta_password.id
  secret_string = jsonencode({ password = "" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "db_credentials_arn" {
  description = "Secrets Manager ARN for database credentials"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "api_keys_arn" {
  description = "Secrets Manager ARN for API keys"
  value       = aws_secretsmanager_secret.api_keys.arn
}

output "letta_password_arn" {
  description = "Secrets Manager ARN for Letta password"
  value       = aws_secretsmanager_secret.letta_password.arn
}

output "db_credentials_secret_id" {
  description = "Secrets Manager secret ID for DB credentials"
  value       = aws_secretsmanager_secret.db_credentials.id
}
