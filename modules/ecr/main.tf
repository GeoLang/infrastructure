# GeoLang Infrastructure — ECR Module
#
# Creates one ECR repository per service with lifecycle policies
# and image scanning enabled.

variable "name_prefix" {
  type = string
}

variable "services" {
  description = "List of service names to create repositories for"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── ECR Repositories ────────────────────────────────────────────────────────

resource "aws_ecr_repository" "services" {
  for_each = toset(var.services)

  name                 = "${var.name_prefix}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, { Service = each.key })
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each = toset(var.services)

  repository = aws_ecr_repository.services[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v"]
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN"
  value       = { for k, v in aws_ecr_repository.services : k => v.arn }
}
