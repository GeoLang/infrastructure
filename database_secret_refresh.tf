locals {
  database_secret_refresh_enabled = var.enable_database && var.enable_database_secret_refresh && (var.enable_ptolemy || var.enable_agora)

  database_secret_refresh_targets = merge(
    var.enable_database && var.enable_ptolemy ? {
      ptolemy = {
        name              = "ptolemy"
        source_secret_arn = module.database[0].master_user_secret_arn
        target_secret_arn = lookup(local.runtime_secret_arns, "ptolemy_database_url", "")
        host              = module.database[0].address
        port              = module.database[0].port
        database_name     = var.db_name
        cluster_name      = module.ecs.cluster_name
        service_name      = module.ecs.service_names["ptolemy"]
      }
    } : {},
    var.enable_database && var.enable_agora ? {
      agora = {
        name              = "agora"
        source_secret_arn = module.agora_database[0].master_user_secret_arn
        target_secret_arn = lookup(local.runtime_secret_arns, "agora_database_url", "")
        host              = module.agora_database[0].address
        port              = module.agora_database[0].port
        database_name     = "agora"
        cluster_name      = module.ecs.cluster_name
        service_name      = module.ecs.service_names["agora"]
      }
    } : {},
  )

  database_secret_refresh_source_arns = distinct([
    for target in values(local.database_secret_refresh_targets) : target.source_secret_arn
  ])

  database_secret_refresh_target_arns = distinct([
    for target in values(local.database_secret_refresh_targets) : target.target_secret_arn
  ])

  database_secret_refresh_service_arns = [
    for target in values(local.database_secret_refresh_targets) : "arn:${data.aws_partition.current[0].partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current[0].account_id}:service/${target.cluster_name}/${target.service_name}"
  ]
}

data "aws_caller_identity" "current" {
  count = local.database_secret_refresh_enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = local.database_secret_refresh_enabled ? 1 : 0
}

resource "terraform_data" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition = alltrue([
        for target in values(local.database_secret_refresh_targets) : target.target_secret_arn != ""
      ])
      error_message = "enable_database_secret_refresh requires a runtime URL secret ARN for every enabled Ptolemy or Agora database."
    }

    precondition {
      condition = alltrue([
        for target in values(local.database_secret_refresh_targets) : can(regex(
          "^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$",
          target.target_secret_arn,
        ))
      ])
      error_message = "enable_database_secret_refresh requires full Secrets Manager ARNs for Ptolemy and Agora runtime URL secrets."
    }
  }
}

data "archive_file" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  type             = "zip"
  source_file      = "${path.module}/functions/refresh_database_secrets.py"
  output_file_mode = "0644"
  output_path      = "${path.module}/.terraform/refresh_database_secrets.zip"
}

resource "aws_cloudwatch_log_group" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-database-secret-refresh"
  retention_in_days = var.log_retention_days

  tags = merge(local.tags, { Service = "database-secret-refresh" })
}

resource "aws_iam_role" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  name = "${local.name_prefix}-database-secret-refresh"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  name = "${local.name_prefix}-database-secret-refresh"
  role = aws_iam_role.database_secret_refresh[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = concat(local.database_secret_refresh_source_arns, local.database_secret_refresh_target_arns)
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue"]
        Resource = local.database_secret_refresh_target_arns
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:UpdateSecretVersionStage"]
        Resource = local.database_secret_refresh_target_arns
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Resource = local.database_secret_refresh_service_arns
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.database_secret_refresh[0].arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  function_name = "${local.name_prefix}-database-secret-refresh"
  description   = "Refreshes runtime database URLs after RDS password rotation"
  role          = aws_iam_role.database_secret_refresh[0].arn
  handler       = "refresh_database_secrets.handler"
  runtime       = "python3.13"
  timeout       = 600

  filename         = data.archive_file.database_secret_refresh[0].output_path
  source_code_hash = data.archive_file.database_secret_refresh[0].output_base64sha256

  reserved_concurrent_executions = 1

  environment {
    variables = {
      DATABASE_SECRET_REFRESH_TARGETS = jsonencode(values(local.database_secret_refresh_targets))
    }
  }

  depends_on = [
    terraform_data.database_secret_refresh,
    aws_cloudwatch_log_group.database_secret_refresh,
  ]

  tags = merge(local.tags, { Service = "database-secret-refresh" })
}

resource "aws_iam_role" "database_secret_refresh_scheduler" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  name = "${local.name_prefix}-database-secret-refresh-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current[0].account_id
        }
        ArnEquals = {
          "aws:SourceArn" = "arn:${data.aws_partition.current[0].partition}:scheduler:${var.aws_region}:${data.aws_caller_identity.current[0].account_id}:schedule-group/default"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "database_secret_refresh_scheduler" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  name = "${local.name_prefix}-database-secret-refresh-scheduler"
  role = aws_iam_role.database_secret_refresh_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.database_secret_refresh[0].arn
    }]
  })
}

resource "aws_scheduler_schedule" "database_secret_refresh" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  name                = "${local.name_prefix}-database-secret-refresh"
  schedule_expression = "rate(15 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.database_secret_refresh[0].arn
    role_arn = aws_iam_role.database_secret_refresh_scheduler[0].arn
  }
}

resource "aws_lambda_permission" "database_secret_refresh_scheduler" {
  count = local.database_secret_refresh_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.database_secret_refresh[0].function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.database_secret_refresh[0].arn
}
