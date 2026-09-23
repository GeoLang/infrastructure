locals {
  demo_landing_page_path      = "/try"
  demo_landing_page_directory = "${path.module}/demo-landing-page"
  demo_landing_page_files = {
    "index.html"  = "text/html"
    "landing.css" = "text/css"
    "landing.js"  = "text/javascript"
  }

  demo_idle_minutes              = 30
  demo_idle_check_minutes        = 5
  demo_function_timeout_seconds  = 30
  demo_wake_concurrency          = 1
  demo_activity_metric_namespace = "GeoLang/${local.name_prefix}"
  demo_activity_metric_name      = "DemoActivity"

  hours_per_day = 24
  demo_hours = var.nightly_scale_down == null ? [] : (
    var.morning_scale_up_hour < var.nightly_scale_down.hour
    ? range(var.morning_scale_up_hour, var.nightly_scale_down.hour)
    : concat(range(var.morning_scale_up_hour, local.hours_per_day), range(0, var.nightly_scale_down.hour))
  )
  demo_idle_check_hours = [for hour in range(local.hours_per_day) : hour if !contains(local.demo_hours, hour)]

  demo_function_environment = {
    DEMO_CLUSTER_NAME              = module.ecs.cluster_name
    DEMO_RUNNING_DESIRED_COUNTS    = jsonencode(local.running_desired_counts)
    DEMO_ACTIVITY_METRIC_NAMESPACE = local.demo_activity_metric_namespace
    DEMO_ACTIVITY_METRIC_NAME      = local.demo_activity_metric_name
    DEMO_IDLE_MINUTES              = tostring(local.demo_idle_minutes)
  }
}

# ─── Landing page ────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "demo_landing_page" {
  count = var.enable_demo_landing_page ? 1 : 0

  # kept out of the name_prefix-* pattern the ecs task role can write to
  bucket = "${var.project_name}-demo-landing-page-${var.environment}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "demo_landing_page" {
  count = var.enable_demo_landing_page ? 1 : 0

  bucket                  = aws_s3_bucket.demo_landing_page[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "demo_landing_page" {
  count = var.enable_demo_landing_page ? 1 : 0

  bucket = aws_s3_bucket.demo_landing_page[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.demo_landing_page[0].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = module.cdn[0].distribution_arn
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.demo_landing_page]
}

resource "aws_s3_object" "demo_landing_page" {
  for_each = var.enable_demo_landing_page ? local.demo_landing_page_files : {}

  bucket       = aws_s3_bucket.demo_landing_page[0].id
  key          = "${trimprefix(local.demo_landing_page_path, "/")}/${each.key}"
  source       = "${local.demo_landing_page_directory}/${each.key}"
  etag         = filemd5("${local.demo_landing_page_directory}/${each.key}")
  content_type = each.value
}

resource "aws_s3_object" "demo_landing_page_config" {
  count = var.enable_demo_landing_page ? 1 : 0

  bucket       = aws_s3_bucket.demo_landing_page[0].id
  key          = "${trimprefix(local.demo_landing_page_path, "/")}/config.json"
  content_type = "application/json"

  content = jsonencode({
    wakeUrl     = aws_lambda_function_url.demo_wake[0].function_url
    timezone    = var.nightly_scale_down.timezone
    morningHour = var.morning_scale_up_hour
    nightlyHour = var.nightly_scale_down.hour
    idleMinutes = local.demo_idle_minutes
  })
}

# ─── Shared by both functions ────────────────────────────────────────────────

data "archive_file" "demo_scaling" {
  count = var.enable_demo_landing_page ? 1 : 0

  type             = "zip"
  source_file      = "${path.module}/functions/demo_scaling.py"
  output_file_mode = "0644"
  output_path      = "${path.module}/.terraform/demo_scaling.zip"
}

resource "aws_cloudwatch_log_metric_filter" "demo_chat_runs" {
  count = var.enable_demo_landing_page ? 1 : 0

  name           = "${local.name_prefix}-demo-chat-runs"
  log_group_name = module.ecs.log_group_names["geolang-api"]
  # uvicorn's access log line for a chat run
  pattern = "\"POST /chat/agui\""

  metric_transformation {
    name      = local.demo_activity_metric_name
    namespace = local.demo_activity_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

# ─── Wake on demand ──────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "demo_wake" {
  count = var.enable_demo_landing_page ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-demo-wake"
  retention_in_days = var.log_retention_days

  tags = merge(local.tags, { Service = "demo-wake" })
}

resource "aws_iam_role" "demo_wake" {
  count = var.enable_demo_landing_page ? 1 : 0

  name = "${local.name_prefix}-demo-wake"

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

resource "aws_iam_role_policy" "demo_wake" {
  count = var.enable_demo_landing_page ? 1 : 0

  name = "${local.name_prefix}-demo-wake"
  role = aws_iam_role.demo_wake[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecs:UpdateService"
        Resource = local.ecs_service_arns
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = local.demo_activity_metric_namespace
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.demo_wake[0].arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "demo_wake" {
  count = var.enable_demo_landing_page ? 1 : 0

  function_name = "${local.name_prefix}-demo-wake"
  description   = "Scales the ECS services up when the demo landing page asks"
  role          = aws_iam_role.demo_wake[0].arn
  handler       = "demo_scaling.wake_handler"
  runtime       = "python3.13"
  timeout       = local.demo_function_timeout_seconds
  # the url is public, unbounded calls would take every lambda slot in the account
  reserved_concurrent_executions = local.demo_wake_concurrency

  filename         = data.archive_file.demo_scaling[0].output_path
  source_code_hash = data.archive_file.demo_scaling[0].output_base64sha256

  environment {
    variables = local.demo_function_environment
  }

  depends_on = [aws_cloudwatch_log_group.demo_wake]

  tags = merge(local.tags, { Service = "demo-wake" })
}

resource "aws_lambda_function_url" "demo_wake" {
  count = var.enable_demo_landing_page ? 1 : 0

  function_name      = aws_lambda_function.demo_wake[0].function_name
  authorization_type = "NONE"

  cors {
    allow_origins = [local.platform_origin]
    allow_methods = ["POST"]
  }
}

resource "aws_lambda_permission" "demo_wake_function_url" {
  count = var.enable_demo_landing_page ? 1 : 0

  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.demo_wake[0].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "demo_wake_invoke_through_url" {
  count = var.enable_demo_landing_page ? 1 : 0

  statement_id             = "AllowInvokeThroughFunctionUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.demo_wake[0].function_name
  principal                = "*"
  invoked_via_function_url = true
}

# ─── Idle scale-down ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "demo_idle_scale_down" {
  count = var.enable_demo_landing_page ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-demo-idle-scale-down"
  retention_in_days = var.log_retention_days

  tags = merge(local.tags, { Service = "demo-idle-scale-down" })
}

resource "aws_iam_role" "demo_idle_scale_down" {
  count = var.enable_demo_landing_page ? 1 : 0

  name = "${local.name_prefix}-demo-idle-scale-down"

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

resource "aws_iam_role_policy" "demo_idle_scale_down" {
  count = var.enable_demo_landing_page ? 1 : 0

  name = "${local.name_prefix}-demo-idle-scale-down"
  role = aws_iam_role.demo_idle_scale_down[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecs:UpdateService"
        Resource = local.ecs_service_arns
      },
      {
        # GetMetricStatistics takes no resource or namespace condition
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricStatistics"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.demo_idle_scale_down[0].arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "demo_idle_scale_down" {
  count = var.enable_demo_landing_page ? 1 : 0

  function_name = "${local.name_prefix}-demo-idle-scale-down"
  description   = "Scales the ECS services down after the demo sits idle"
  role          = aws_iam_role.demo_idle_scale_down[0].arn
  handler       = "demo_scaling.idle_handler"
  runtime       = "python3.13"
  timeout       = local.demo_function_timeout_seconds

  filename         = data.archive_file.demo_scaling[0].output_path
  source_code_hash = data.archive_file.demo_scaling[0].output_base64sha256

  environment {
    variables = local.demo_function_environment
  }

  depends_on = [aws_cloudwatch_log_group.demo_idle_scale_down]

  tags = merge(local.tags, { Service = "demo-idle-scale-down" })
}

resource "aws_iam_role" "demo_idle_scale_down_scheduler" {
  count = var.enable_demo_landing_page ? 1 : 0

  name = "${local.name_prefix}-demo-idle-scale-down-scheduler"

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

resource "aws_iam_role_policy" "demo_idle_scale_down_scheduler" {
  count = var.enable_demo_landing_page ? 1 : 0

  name = "${local.name_prefix}-demo-idle-scale-down-scheduler"
  role = aws_iam_role.demo_idle_scale_down_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.demo_idle_scale_down[0].arn
    }]
  })
}

# runs only outside the morning to nightly hours, so it never undoes the morning scale-up
resource "aws_scheduler_schedule" "demo_idle_scale_down" {
  count = var.enable_demo_landing_page ? 1 : 0

  name                         = "${local.name_prefix}-demo-idle-scale-down"
  schedule_expression          = "cron(0/${local.demo_idle_check_minutes} ${join(",", local.demo_idle_check_hours)} * * ? *)"
  schedule_expression_timezone = var.nightly_scale_down.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.demo_idle_scale_down[0].arn
    role_arn = aws_iam_role.demo_idle_scale_down_scheduler[0].arn
  }
}
