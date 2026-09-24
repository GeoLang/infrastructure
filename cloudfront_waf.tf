locals {
  cloudfront_waf_enabled             = var.enable_cdn && var.cloudfront_rate_limits != null
  cloudfront_rate_window_seconds     = 300
  cloudfront_auth_path_prefix        = "/api/v1/auth/"
  cloudfront_auth_rule_priority      = 1
  cloudfront_all_requests_priority   = 2
  cloudfront_path_decode_priority    = 0
  cloudfront_path_lowercase_priority = 1
}

# on the alb the client address comes from an X-Forwarded-For the client can forge
resource "aws_wafv2_web_acl" "cloudfront" {
  count = local.cloudfront_waf_enabled ? 1 : 0

  name  = "${local.name_prefix}-cloudfront"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "auth-requests-per-ip"
    priority = local.cloudfront_auth_rule_priority

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.cloudfront_rate_limits.auth_requests_per_ip
        aggregate_key_type    = "IP"
        evaluation_window_sec = local.cloudfront_rate_window_seconds

        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = local.cloudfront_auth_path_prefix

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = local.cloudfront_path_decode_priority
              type     = "URL_DECODE"
            }

            text_transformation {
              priority = local.cloudfront_path_lowercase_priority
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-auth-requests-per-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "requests-per-ip"
    priority = local.cloudfront_all_requests_priority

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.cloudfront_rate_limits.requests_per_ip
        aggregate_key_type    = "IP"
        evaluation_window_sec = local.cloudfront_rate_window_seconds
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-requests-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cloudfront"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}
