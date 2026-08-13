# GeoLang Infrastructure, Secrets Manager Module

variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "secret_names" {
  description = "Runtime secrets to create"
  type        = set(string)
  default     = []
}

locals {
  runtime_secrets = {
    platform_jwt         = "Shared HS256 platform signing secret"
    ptolemy_database_url = "Ptolemy PostgreSQL connection URL"
    agora_database_url   = "Agora PostgreSQL connection URL"
    geolang_executor     = "Shared GeoLang API to executor credential"
    llm_api_key          = "Sibyl OpenAI-compatible provider API key"
    jupyter_token        = "ViewTopia Jupyter server token"
  }
}

resource "aws_secretsmanager_secret" "runtime" {
  for_each = var.secret_names

  name        = "${var.name_prefix}/${replace(each.key, "_", "-")}"
  description = local.runtime_secrets[each.key]

  # terraform only creates the container and the values are written out of band,
  # so a scheduled deletion would just block recreating the same name
  recovery_window_in_days = 0

  tags = merge(var.tags, { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}" })
}

output "secret_arns" {
  description = "Runtime secret ARNs keyed by purpose"
  value       = { for name, secret in aws_secretsmanager_secret.runtime : name => secret.arn }
}
