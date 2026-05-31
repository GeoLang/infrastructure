# GeoLang Infrastructure — Security Module
#
# GuardDuty threat detection, VPC Flow Logs, and compliance
# resources for enterprise deployments.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "enable_guardduty" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── VPC Flow Logs ───────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.name_prefix}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.name_prefix}-flow-logs-write"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = var.vpc_id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-flow-log" })
}

# ─── GuardDuty ────────────────────────────────────────────────────────────────

resource "aws_guardduty_detector" "main" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"

  datasources {
    s3_logs {
      enable = true
    }

    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-guardduty" })
}

# ─── ECS Exec Policy (for debugging) ─────────────────────────────────────────

resource "aws_iam_policy" "ecs_exec" {
  name        = "${var.name_prefix}-ecs-exec"
  description = "Allow ECS Exec for container debugging"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "flow_log_group" {
  description = "VPC Flow Logs CloudWatch log group"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = var.enable_guardduty ? aws_guardduty_detector.main[0].id : ""
}

output "ecs_exec_policy_arn" {
  description = "IAM policy ARN for ECS Exec"
  value       = aws_iam_policy.ecs_exec.arn
}
