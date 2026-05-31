# GeoLang Infrastructure — SQS Queues Module
#
# Message queues for async processing of heavy geospatial workloads:
# tile ingestion, point cloud processing, ETL pipelines, and
# AI inference requests.

variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Tile Processing Queue ───────────────────────────────────────────────────
# Used by TileTopia for async ingestion of point clouds, 3D models, and DEMs.

resource "aws_sqs_queue" "tile_processing" {
  name                       = "${var.name_prefix}-tile-processing"
  visibility_timeout_seconds = 900  # 15 min — tile processing can be slow
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20   # Long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.tile_processing_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(var.tags, { Service = "tiletopia" })
}

resource "aws_sqs_queue" "tile_processing_dlq" {
  name                      = "${var.name_prefix}-tile-processing-dlq"
  message_retention_seconds = 604800 # 7 days
  tags                      = merge(var.tags, { Service = "tiletopia", Type = "dlq" })
}

# ─── Geocoding Batch Queue ───────────────────────────────────────────────────
# Used by Geokode for batch geocoding operations.

resource "aws_sqs_queue" "geocoding_batch" {
  name                       = "${var.name_prefix}-geocoding-batch"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.geocoding_batch_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(var.tags, { Service = "geokode" })
}

resource "aws_sqs_queue" "geocoding_batch_dlq" {
  name                      = "${var.name_prefix}-geocoding-batch-dlq"
  message_retention_seconds = 604800
  tags                      = merge(var.tags, { Service = "geokode", Type = "dlq" })
}

# ─── AI Agent Queue ──────────────────────────────────────────────────────────
# Used by GeoLang for async AI inference and tool execution.

resource "aws_sqs_queue" "agent_tasks" {
  name                       = "${var.name_prefix}-agent-tasks"
  visibility_timeout_seconds = 600 # 10 min — LLM calls can be slow
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.agent_tasks_dlq.arn
    maxReceiveCount     = 2
  })

  tags = merge(var.tags, { Service = "geolang" })
}

resource "aws_sqs_queue" "agent_tasks_dlq" {
  name                      = "${var.name_prefix}-agent-tasks-dlq"
  message_retention_seconds = 604800
  tags                      = merge(var.tags, { Service = "geolang", Type = "dlq" })
}

# ─── ETL Pipeline Queue ──────────────────────────────────────────────────────
# Used by Geodukt for ETL pipeline execution.

resource "aws_sqs_queue" "etl_pipeline" {
  name                       = "${var.name_prefix}-etl-pipeline"
  visibility_timeout_seconds = 1800 # 30 min — ETL can be very slow
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.etl_pipeline_dlq.arn
    maxReceiveCount     = 2
  })

  tags = merge(var.tags, { Service = "geodukt" })
}

resource "aws_sqs_queue" "etl_pipeline_dlq" {
  name                      = "${var.name_prefix}-etl-pipeline-dlq"
  message_retention_seconds = 604800
  tags                      = merge(var.tags, { Service = "geodukt", Type = "dlq" })
}

# ─── IAM Policy for Queue Access ─────────────────────────────────────────────

resource "aws_iam_policy" "sqs_access" {
  name        = "${var.name_prefix}-sqs-access"
  description = "Allow ECS tasks to send/receive SQS messages"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = [
        aws_sqs_queue.tile_processing.arn,
        aws_sqs_queue.geocoding_batch.arn,
        aws_sqs_queue.agent_tasks.arn,
        aws_sqs_queue.etl_pipeline.arn,
      ]
    }]
  })

  tags = var.tags
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "queue_urls" {
  description = "SQS queue URLs by purpose"
  value = {
    tile_processing = aws_sqs_queue.tile_processing.url
    geocoding_batch = aws_sqs_queue.geocoding_batch.url
    agent_tasks     = aws_sqs_queue.agent_tasks.url
    etl_pipeline    = aws_sqs_queue.etl_pipeline.url
  }
}

output "queue_arns" {
  description = "SQS queue ARNs"
  value = {
    tile_processing = aws_sqs_queue.tile_processing.arn
    geocoding_batch = aws_sqs_queue.geocoding_batch.arn
    agent_tasks     = aws_sqs_queue.agent_tasks.arn
    etl_pipeline    = aws_sqs_queue.etl_pipeline.arn
  }
}

output "sqs_policy_arn" {
  description = "IAM policy ARN for SQS access"
  value       = aws_iam_policy.sqs_access.arn
}
