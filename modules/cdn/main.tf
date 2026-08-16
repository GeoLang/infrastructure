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

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # TLS to the origin needs a hostname we control. ACM will not issue for the
  # raw *.elb.amazonaws.com name and CloudFront checks the origin certificate
  # against the origin hostname, so https-only is only possible once a domain is
  # configured and origin.<domain> points at the ALB.
  origin_is_named = var.origin_domain_name != ""
  origin_host     = local.origin_is_named ? var.origin_domain_name : var.alb_dns_name
}

# ─── CloudFront Distribution ─────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} GeoLang Platform CDN"
  price_class     = "PriceClass_100" # US, Canada, Europe

  aliases = var.domain_name != "" && var.certificate_arn != "" ? [var.domain_name] : []

  origin {
    domain_name = local.origin_host
    origin_id   = "alb"

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # WARNING: the http-only fallback is not fit for production. It sends every
      # Authorization header, JWT and session cookie from CloudFront to the ALB in
      # cleartext across the public internet. It exists only so the stack can come
      # up without a domain. Set domain_name and enable_dns to get https-only.
      origin_protocol_policy = local.origin_is_named ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default behavior, pass through to ALB (API, frontend)
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

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

output "hosted_zone_id" {
  description = "CloudFront hosted zone ID (for Route53 alias)"
  value       = aws_cloudfront_distribution.main.hosted_zone_id
}
