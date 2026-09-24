# GeoLang Infrastructure - CDN Module (CloudFront)
#
# CloudFront distribution in front of the ALB with cache behaviors
# optimized for geospatial tile delivery.

variable "name_prefix" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "domain_name" {
  description = "Custom domain (empty = CloudFront default domain)"
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM certificate ARN (must be in us-east-1)"
  type        = string
  default     = ""
}

variable "origin_domain_name" {
  description = "Hostname for the ALB origin, e.g. origin.example.com. Empty falls back to the raw ALB DNS name over plain HTTP."
  type        = string
  default     = ""
}

variable "allow_cleartext_origin" {
  description = "Permit the http-only fallback when no origin hostname is configured"
  type        = bool
  default     = false
}

variable "web_acl_arn" {
  description = "WAF web ACL attached to the distribution, empty for none"
  type        = string
  default     = ""
}

variable "origin_verify_header" {
  description = "Header CloudFront adds to every request to the ALB origin, null for none"
  type = object({
    name  = string
    value = string
  })
  default = null
}

variable "demo_page" {
  description = "Private S3 bucket and path prefix for the static demo landing page, null for none"
  type = object({
    bucket_regional_domain_name = string
    path                        = string
  })
  default = null
}

variable "content_security_policy_enforced" {
  description = "Send the viewer's Content-Security-Policy as enforced rather than report-only"
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # scripts only from the bundle or a blob url, data sources open because users add their own tile hosts
  content_security_policy = join("; ", [
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval' blob:",
    "worker-src 'self' blob:",
    "style-src 'self' 'unsafe-inline'",
    "img-src * data: blob:",
    "connect-src * data: blob:",
    "media-src * data: blob:",
    "font-src 'self' data:",
    "frame-src https:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ])

  # TLS to the origin needs a hostname we control. ACM will not issue for the
  # raw *.elb.amazonaws.com name and CloudFront checks the origin certificate
  # against the origin hostname, so https-only is only possible once a domain is
  # configured and origin.<domain> points at the ALB.
  origin_is_named = var.origin_domain_name != ""
  origin_host     = local.origin_is_named ? var.origin_domain_name : var.alb_dns_name

  demo_page_origin_id     = "demo-page"
  demo_page_cache_seconds = 300
}

resource "aws_cloudfront_origin_access_control" "demo_page" {
  count = var.demo_page == null ? 0 : 1

  name                              = "${var.name_prefix}-demo-page"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# S3 has no index documents over the REST endpoint CloudFront signs for
resource "aws_cloudfront_function" "demo_page_index" {
  count = var.demo_page == null ? 0 : 1

  name    = "${var.name_prefix}-demo-page-index"
  runtime = "cloudfront-js-2.0"
  publish = true
  code = templatefile("${path.module}/demo_page_index.js", {
    demo_page_path = var.demo_page.path
  })
}

# a forwarded Host makes S3 look up a bucket named after the CloudFront domain
resource "aws_cloudfront_cache_policy" "demo_page" {
  count = var.demo_page == null ? 0 : 1

  name        = "${var.name_prefix}-demo-page"
  min_ttl     = 0
  default_ttl = local.demo_page_cache_seconds
  max_ttl     = local.demo_page_cache_seconds

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}

# ─── CloudFront Distribution ─────────────────────────────────────────────────

resource "aws_cloudfront_response_headers_policy" "viewer" {
  name = "${var.name_prefix}-viewer"

  security_headers_config {
    content_type_options {
      override = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    dynamic "content_security_policy" {
      for_each = var.content_security_policy_enforced ? [1] : []
      content {
        content_security_policy = local.content_security_policy
        override                = true
      }
    }
  }

  dynamic "custom_headers_config" {
    for_each = var.content_security_policy_enforced ? [] : [1]
    content {
      items {
        header   = "Content-Security-Policy-Report-Only"
        value    = local.content_security_policy
        override = true
      }
    }
  }
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} GeoLang Platform CDN"
  price_class     = "PriceClass_100" # US, Canada, Europe

  aliases = var.domain_name != "" && var.certificate_arn != "" ? [var.domain_name] : []

  web_acl_id = var.web_acl_arn != "" ? var.web_acl_arn : null

  origin {
    domain_name = local.origin_host
    origin_id   = "alb"

    dynamic "custom_header" {
      for_each = var.origin_verify_header == null ? [] : [var.origin_verify_header]
      content {
        name  = custom_header.value.name
        value = custom_header.value.value
      }
    }

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # WARNING: http-only sends every Authorization header, JWT and session cookie to the ALB in cleartext
      origin_protocol_policy = local.origin_is_named ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  dynamic "origin" {
    for_each = var.demo_page == null ? [] : [var.demo_page]
    content {
      domain_name              = origin.value.bucket_regional_domain_name
      origin_id                = local.demo_page_origin_id
      origin_access_control_id = aws_cloudfront_origin_access_control.demo_page[0].id
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.demo_page == null ? [] : [var.demo_page.path, "${var.demo_page.path}/*"]
    content {
      path_pattern           = ordered_cache_behavior.value
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      target_origin_id       = local.demo_page_origin_id
      viewer_protocol_policy = "redirect-to-https"
      cache_policy_id        = aws_cloudfront_cache_policy.demo_page[0].id
      compress               = true

      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.demo_page_index[0].arn
      }
    }
  }

  # Default behavior, pass through to ALB (API, frontend)
  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "alb"
    viewer_protocol_policy     = "redirect-to-https"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.viewer.id

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Origin", "Host"]
      cookies {
        forward = "all"
      }
    }

    # Never cache here. This behavior catches the authenticated API and the
    # frontend shell, and a non-zero max_ttl lets an origin Cache-Control keep
    # serving a revoked token's response for that long. Public immutable content
    # gets its aggressive TTLs from the ordered behaviors below.
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Realtime collaboration WebSocket (tiletopia /api/v1/realtime/{room}).
  # Auth rides the subprotocol offer `Sec-WebSocket-Protocol: bearer, <jwt>`
  # because a browser cannot set Authorization on a WS handshake, so that header
  # has to reach the origin or every handshake 401s. Upgrade and Connection are
  # deliberately absent: CloudFront cannot cache on them and drives the upgrade
  # itself.
  ordered_cache_behavior {
    path_pattern           = "/api/v1/realtime/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "https-only"

    forwarded_values {
      # the room id is in the path and the origin refuses a query-string
      # credential, so there is nothing in the query worth forwarding
      query_string = false
      headers = [
        "Sec-WebSocket-Protocol",
        "Sec-WebSocket-Key",
        "Sec-WebSocket-Version",
        "Sec-WebSocket-Extensions",
        "Authorization",
        "Origin",
        "Host",
      ]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # ptolemy's websockets: /ws/branches/{id} and /ws/rooms/{id}. Same handshake
  # forwarding as realtime above, and for the same reason: ptolemy classifies
  # /ws/* as authenticated and takes the token from either the Authorization
  # header or the bearer subprotocol, so that header has to reach the origin.
  ordered_cache_behavior {
    path_pattern           = "/ws/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "https-only"

    forwarded_values {
      query_string = false
      headers = [
        "Sec-WebSocket-Protocol",
        "Sec-WebSocket-Key",
        "Sec-WebSocket-Version",
        "Sec-WebSocket-Extensions",
        "Authorization",
        "Origin",
        "Host",
      ]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Agora uses a WebSocket under /agora/ws. Its bearer token can arrive in the
  # WebSocket subprotocol, so the handshake headers must reach the proxy.
  ordered_cache_behavior {
    path_pattern           = "/agora/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "https-only"

    forwarded_values {
      query_string = true
      headers = [
        "Sec-WebSocket-Protocol",
        "Sec-WebSocket-Key",
        "Sec-WebSocket-Version",
        "Sec-WebSocket-Extensions",
        "Authorization",
        "Origin",
        "Host",
      ]
      cookies { forward = "all" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Jupyter kernel channels use WebSockets and its HTTP API uses a token and
  # cookies. Forward both kinds of request without caching.
  ordered_cache_behavior {
    path_pattern           = "/jupyter/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "https-only"

    forwarded_values {
      query_string = true
      headers = [
        "Sec-WebSocket-Protocol",
        "Sec-WebSocket-Key",
        "Sec-WebSocket-Version",
        "Sec-WebSocket-Extensions",
        "Authorization",
        "Origin",
        "Host",
      ]
      cookies { forward = "all" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # 3D Tiles, cache aggressively (immutable content-addressed tiles).
  # No credential is forwarded here or on terrain below on purpose: both map to
  # reads tiletopia serves anonymously (is_public_read in its auth.rs), so the
  # response is identical for every caller. If tile reads ever become per-user,
  # these TTLs have to go to 0 with them.
  #
  # The viewer asks for /tiles/v1/...; the proxy rewrites that to tiletopia
  # /api/v1/... after CloudFront, so these patterns have to match the public
  # path. A CloudFront wildcard crosses slashes while is_public_read matches
  # whole segments, so a longer path that still fits these patterns is refused
  # at the origin rather than served from a shared cache entry.
  ordered_cache_behavior {
    path_pattern           = "/tiles/v1/assets/*/tileset.json"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 86400   # 1 day
    default_ttl = 604800  # 7 days
    max_ttl     = 2592000 # 30 days
    compress    = true
  }

  ordered_cache_behavior {
    path_pattern           = "/tiles/v1/assets/*/tiles/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 86400
    default_ttl = 604800
    max_ttl     = 2592000
    compress    = true
  }

  # Terrain tiles, cache aggressively
  ordered_cache_behavior {
    path_pattern           = "/tiles/v1/terrain/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 86400
    default_ttl = 604800
    max_ttl     = 2592000
    compress    = true
  }

  # Static frontend assets, cache with revalidation
  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 3600
    default_ttl = 86400
    max_ttl     = 604800
    compress    = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.certificate_arn == "" ? true : false
    acm_certificate_arn            = var.certificate_arn != "" ? var.certificate_arn : null
    ssl_support_method             = var.certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.certificate_arn != "" ? "TLSv1.2_2021" : null
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cdn" })

  lifecycle {
    precondition {
      condition     = local.origin_is_named || var.allow_cleartext_origin
      error_message = "CloudFront would reach the load balancer over plain HTTP, sending Authorization headers and session cookies across the public internet in cleartext. Set domain_name with enable_dns so the origin has a hostname TLS can be checked against, or set allow_cleartext_origin = true for a stack that carries no credentials."
    }
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.main.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN"
  value       = aws_cloudfront_distribution.main.arn
}

output "hosted_zone_id" {
  description = "CloudFront hosted zone ID (for Route53 alias)"
  value       = aws_cloudfront_distribution.main.hosted_zone_id
}
