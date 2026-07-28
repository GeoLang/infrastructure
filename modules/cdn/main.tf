# GeoLang Infrastructure — CDN Module (CloudFront)
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

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── CloudFront Distribution ─────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} GeoLang Platform CDN"
  price_class     = "PriceClass_100" # US, Canada, Europe

  aliases = var.domain_name != "" && var.certificate_arn != "" ? [var.domain_name] : []

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default behavior — pass through to ALB (API, frontend)
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
  # forwarding as realtime above. ptolemy reads only the Authorization header
  # (ptolemy-api/src/auth.rs:290-294, no subprotocol fallback) and its classify()
  # calls every GET public, so these handshakes carry no credential today. The
  # forwarding is here so the upgrade survives the CDN, not because it authorizes
  # anything.
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

  # 3D Tiles — cache aggressively (immutable content-addressed tiles).
  # No credential is forwarded here or on terrain below on purpose: both map to
  # reads tiletopia serves anonymously (is_public_read in its auth.rs), so the
  # response is identical for every caller. If tile reads ever become per-user,
  # these TTLs have to go to 0 with them.
  #
  # TODO: this pattern matches no tiletopia route. Its 3D tiles are served from
  # /api/v1/assets/{id}/tileset.json and /api/v1/assets/{id}/tiles/{path}, so
  # nothing reaches this behavior and the terrain one below is the only tile
  # cache that works. Fixing it needs the /tiles prefix question settled first.
  ordered_cache_behavior {
    path_pattern           = "/tiles/v1/3dtiles/*"
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

  # Terrain tiles — cache aggressively
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

  # Static frontend assets — cache with revalidation
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

  # Catalog is authenticated, so never cache it. tiletopia's /api/v1/catalog sits behind
  # auth_middleware and answers per user, but this behavior kept no credential in
  # the cache key at all, so one caller's catalog was served to everyone for up to
  # an hour. Authorization has to reach the origin for the request to succeed, and
  # the TTLs stay 0 so the response is never stored.
  ordered_cache_behavior {
    path_pattern           = "/tiles/v1/catalog*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Origin", "Host"]
      cookies { forward = "all" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
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
