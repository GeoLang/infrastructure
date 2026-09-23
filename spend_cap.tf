locals {
  spend_budget_enabled = var.monthly_spend_budget_usd > 0
  spend_alert_percent  = 80
  spend_action_percent = 100
}

resource "aws_sns_topic" "spend_cap" {
  count = local.spend_budget_enabled ? 1 : 0

  name = "${local.name_prefix}-spend-cap"
}

resource "aws_sns_topic_policy" "spend_cap" {
  count = local.spend_budget_enabled ? 1 : 0

  arn = aws_sns_topic.spend_cap[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.spend_cap[0].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_budgets_budget" "monthly_spend" {
  count = local.spend_budget_enabled ? 1 : 0

  name         = "${local.name_prefix}-monthly-spend"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_spend_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # credits cover the bill today, counting them would keep the budget at zero
  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = local.spend_alert_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.spend_cap[0].arn]
  }

  depends_on = [aws_sns_topic_policy.spend_cap]
}

resource "aws_iam_policy" "deny_model_calls" {
  count = local.spend_budget_enabled ? 1 : 0

  name = "${local.name_prefix}-deny-model-calls"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Deny"
      Action   = ["bedrock:*", "bedrock-mantle:*"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "budget_action" {
  count = local.spend_budget_enabled ? 1 : 0

  name = "${local.name_prefix}-budget-action"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "budget_action" {
  count = local.spend_budget_enabled ? 1 : 0

  name = "${local.name_prefix}-budget-action"
  role = aws_iam_role.budget_action[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
      Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/${var.bedrock_api_key_user}"
      Condition = {
        ArnEquals = { "iam:PolicyARN" = aws_iam_policy.deny_model_calls[0].arn }
      }
    }]
  })
}

# budgets data lags 8 to 12 hours, sibyl's own monthly limit is the cap and this the backstop
resource "aws_budgets_budget_action" "deny_model_calls" {
  count = local.spend_budget_enabled ? 1 : 0

  budget_name        = aws_budgets_budget.monthly_spend[0].name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action[0].arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = local.spend_action_percent
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.deny_model_calls[0].arn
      users      = [var.bedrock_api_key_user]
    }
  }

  subscriber {
    address           = aws_sns_topic.spend_cap[0].arn
    subscription_type = "SNS"
  }

  depends_on = [aws_iam_role_policy.budget_action]

  lifecycle {
    precondition {
      condition     = var.bedrock_api_key_user != ""
      error_message = "monthly_spend_budget_usd needs bedrock_api_key_user, the IAM user the deny is attached to."
    }
  }
}

output "spend_cap_topic_arn" {
  description = "SNS topic the monthly spend budget alerts, subscribe an email to it"
  value       = local.spend_budget_enabled ? aws_sns_topic.spend_cap[0].arn : "Spend budget disabled"
}
