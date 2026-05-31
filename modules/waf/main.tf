# GeoLang Infrastructure — WAF Module
#
# AWS WAF v2 attached to the ALB with managed rule groups
# for OWASP top-10 protection, rate limiting, and geo-blocking.

variable "name_prefix" {
  type = string
}

variable "alb_arn" {
  description = "ALB ARN to attach the WAF to"
  type        = string
}

variable "rate_limit" {
  description = "Maximum requests per 5-minute period per IP"
  type        = number
  default     = 2000
}

variable "blocked_countries" {
  description = "ISO 3166-1 alpha-2 country codes to block (empty = no geo-blocking)"
  type        = list(string)
  default     = []
}

variable "ip_allowlist" {
  description = "CIDR blocks to always allow (bypasses rate limits)"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── IP Set (Allowlist) ──────────────────────────────────────────────────────

resource "aws_wafv2_ip_set" "allowlist" {
  count = length(var.ip_allowlist) > 0 ? 1 : 0

  name               = "${var.name_prefix}-allowlist"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.ip_allowlist

  tags = var.tags
}

# ─── Web ACL ──────────────────────────────────────────────────────────────────

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.name_prefix}-waf"
  scope       = "REGIONAL"
  description = "GeoLang Platform WAF — OWASP protection"

  default_action {
    allow {}
  }

  # ── Rule 1: Rate limiting ────────────────────────────────────────
  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 2: AWS Managed — Common Rule Set (OWASP core) ──────────
  rule {
    name     = "aws-common-rules"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Exclude rules that may block legitimate geospatial payloads
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "CrossSiteScripting_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 3: AWS Managed — Known Bad Inputs ──────────────────────
  rule {
    name     = "aws-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 4: AWS Managed — SQL Injection ─────────────────────────
  rule {
    name     = "aws-sqli"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-sqli"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 5: AWS Managed — Linux OS (protect Fargate containers) ─
  rule {
    name     = "aws-linux"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-linux"
      sampled_requests_enabled   = true
    }
  }

  # ── Rule 6: Geo-blocking (optional) ─────────────────────────────
  dynamic "rule" {
    for_each = length(var.blocked_countries) > 0 ? [1] : []
    content {
      name     = "geo-block"
      priority = 50

      action {
        block {}
      }

      statement {
        geo_match_statement {
          country_codes = var.blocked_countries
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name_prefix}-geo-block"
        sampled_requests_enabled   = true
      }
    }
  }

  # ── Rule 7: IP Allowlist (skip rate limiting) ───────────────────
  dynamic "rule" {
    for_each = length(var.ip_allowlist) > 0 ? [1] : []
    content {
      name     = "ip-allowlist"
      priority = 0

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.allowlist[0].arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name_prefix}-allowlist"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# ─── ALB Association ──────────────────────────────────────────────────────────

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# ─── WAF Logging ──────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }

      condition {
        action_condition {
          action = "COUNT"
        }
      }
    }
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.main.arn
}

output "web_acl_id" {
  description = "WAF Web ACL ID"
  value       = aws_wafv2_web_acl.main.id
}
