# GeoLang Infrastructure — DNS Module (Route53 + ACM)
#
# Manages the geolang.com hosted zone and provisions an
# ACM certificate with DNS validation.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The default provider here is us-east-1, because CloudFront only reads
      # viewer certificates from that region. `aws.regional` is the deployment
      # region, where the ALB lives: an ALB can only use a certificate issued in
      # its own region, so the two listeners need two certificates.
      configuration_aliases = [aws.regional]
    }
  }
}

variable "name_prefix" {
  type = string
}

variable "domain_name" {
  description = "Domain name (e.g., geolang.com)"
  type        = string
}

variable "cloudfront_domain_name" {
  description = "CloudFront distribution domain for alias record"
  type        = string
  default     = ""
}

variable "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID for alias record"
  type        = string
  default     = ""
}

variable "alb_dns_name" {
  description = "ALB DNS name for direct alias (when no CDN)"
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "ALB hosted zone ID"
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Route53 Hosted Zone ─────────────────────────────────────────────────────

resource "aws_route53_zone" "main" {
  name = var.domain_name
  tags = merge(var.tags, { Name = var.domain_name })
}

# ─── ACM Certificate ─────────────────────────────────────────────────────────
# Must be in us-east-1 for CloudFront. Use the aliased provider.

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  tags = merge(var.tags, { Name = "${var.name_prefix}-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── DNS Validation Records ──────────────────────────────────────────────────

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ─── ALB Certificate (deployment region) ─────────────────────────────────────
# Same domains as the CloudFront certificate, issued in the region the ALB runs
# in. ACM hands out one validation CNAME per domain per account and it works in
# every region, so this reuses the records above instead of creating its own.
# Two resources writing the same record would fight on every plan.

resource "aws_acm_certificate" "alb" {
  provider                  = aws.regional
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "alb" {
  provider                = aws.regional
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ─── Origin Record → ALB ─────────────────────────────────────────────────────
# CloudFront checks the origin's certificate against the origin hostname, and
# ACM will not issue for the raw *.elb.amazonaws.com name. This gives the ALB a
# name we control so the CloudFront-to-ALB hop can be TLS instead of cleartext.

resource "aws_route53_record" "origin" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "origin.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = false
  }
}

# ─── A Record → CloudFront or ALB ────────────────────────────────────────────

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.cloudfront_domain_name != "" ? var.cloudfront_domain_name : var.alb_dns_name
    zone_id                = var.cloudfront_hosted_zone_id != "" ? var.cloudfront_hosted_zone_id : var.alb_zone_id
    evaluate_target_health = true
  }
}

# www redirect
resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.cloudfront_domain_name != "" ? var.cloudfront_domain_name : var.alb_dns_name
    zone_id                = var.cloudfront_hosted_zone_id != "" ? var.cloudfront_hosted_zone_id : var.alb_zone_id
    evaluate_target_health = true
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "Route53 name servers (set these at your domain registrar)"
  value       = aws_route53_zone.main.name_servers
}

output "certificate_arn" {
  description = "Validated ACM certificate ARN (us-east-1, for the CloudFront viewer)"
  value       = aws_acm_certificate_validation.main.certificate_arn
}

output "alb_certificate_arn" {
  description = "Validated ACM certificate ARN in the deployment region, for the ALB listener"
  value       = aws_acm_certificate_validation.alb.certificate_arn
}

output "origin_domain_name" {
  description = "Hostname pointing at the ALB, used as the CloudFront origin"
  value       = aws_route53_record.origin.name
}
