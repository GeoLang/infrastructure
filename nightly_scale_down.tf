locals {
  nightly_scale_down_enabled = var.nightly_scale_down != null

  nightly_scale_down_service_arns = [
    for service_name in values(module.ecs.service_names) :
    "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${module.ecs.cluster_name}/${service_name}"
  ]
}

resource "aws_iam_role" "nightly_scale_down" {
  count = local.nightly_scale_down_enabled ? 1 : 0

  name = "${local.name_prefix}-nightly-scale-down"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnEquals = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule-group/default"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "nightly_scale_down" {
  count = local.nightly_scale_down_enabled ? 1 : 0

  name = "${local.name_prefix}-nightly-scale-down"
  role = aws_iam_role.nightly_scale_down[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ecs:UpdateService"
      Resource = local.nightly_scale_down_service_arns
    }]
  })
}

resource "aws_scheduler_schedule" "nightly_scale_down" {
  for_each = local.nightly_scale_down_enabled ? module.ecs.service_names : {}

  name                         = "${local.name_prefix}-${each.key}-nightly-scale-down"
  schedule_expression          = "cron(0 ${var.nightly_scale_down.hour} * * ? *)"
  schedule_expression_timezone = var.nightly_scale_down.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.nightly_scale_down[0].arn

    input = jsonencode({
      Cluster      = module.ecs.cluster_name
      Service      = each.value
      DesiredCount = 0
    })
  }
}
