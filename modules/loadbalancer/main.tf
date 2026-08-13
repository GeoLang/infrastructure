# GeoLang Infrastructure — Load Balancer Module
#
# Application Load Balancer with path-based routing to all
# platform services. Mirrors the ViewTopia nginx-platform.conf
# routing pattern.

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS (empty = HTTP only)"
  type        = string
  default     = ""
}

variable "restrict_ingress_to_cloudfront" {
  description = "Admit only the CloudFront origin-facing ranges to the ALB"
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── ALB Security Group ──────────────────────────────────────────────────────
#
# With a CDN in front, reaching the ALB directly would skip CloudFront's viewer
# TLS policy, its zero-cache behaviours for authenticated paths, and the origin
# hostname the certificate is checked against. AWS publishes the origin-facing
# ranges as a managed prefix list, so the ALB can admit those alone.

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = var.restrict_ingress_to_cloudfront ? 1 : 0

  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  # CloudFront reaches the origin over https once the ALB has a certificate,
  # which is the same condition that names the CDN origin, so it connects on one
  # port and only that port has to be admitted. Admitting both would fail the
  # apply: the prefix list counts as 55 of a security group's 60 rules.
  cloudfront_origin_port = var.certificate_arn != "" ? 443 : 80

  alb_ingress_rules = var.restrict_ingress_to_cloudfront ? [
    { port = local.cloudfront_origin_port, description = "CloudFront origin-facing ranges" }
    ] : [
    { port = 80, description = "HTTP" },
    { port = 443, description = "HTTPS" },
  ]
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.alb_ingress_rules
    content {
      from_port       = ingress.value.port
      to_port         = ingress.value.port
      protocol        = "tcp"
      cidr_blocks     = var.restrict_ingress_to_cloudfront ? [] : ["0.0.0.0/0"]
      prefix_list_ids = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[*].id
      description     = ingress.value.description
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── ECS Security Group ──────────────────────────────────────────────────────

resource "aws_security_group" "ecs" {
  name_prefix = "${var.name_prefix}-ecs-"
  vpc_id      = var.vpc_id

  # Allow all traffic from ALB
  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "All TCP from ALB"
  }

  # Allow inter-service communication within VPC
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
    description = "Inter-service communication"
  }

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.untrusted_code.id]
    description     = "Tool calls from untrusted code to ptolemy, tiletopia, geokode and itinera"
  }

  ingress {
    from_port       = 8100
    to_port         = 8100
    protocol        = "tcp"
    security_groups = [aws_security_group.untrusted_code.id]
    description     = "Workflow calls from untrusted code to geodukt"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Agora Security Group ────────────────────────────────────────────────────
#
# Agora listens on 3000, the same port the executor's tool calls reach in the
# shared ECS group, and it authenticates nothing that arrives from inside the
# VPC. Its own group keeps that traffic to the callers that route user requests,
# the platform proxy and the geolang API, both of which sit in the ECS group.

resource "aws_security_group" "agora" {
  name_prefix = "${var.name_prefix}-agora-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
    description     = "Session traffic from the platform proxy and the geolang API"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-agora-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Untrusted Code Security Group ───────────────────────────────────────────
#
# The geolang executor sits here instead of the shared ECS group, which reaches
# every service and both RDS instances. Egress is only what the executor's tools
# call plus what Fargate needs over the task ENI. This group cannot reference
# the ECS group, because the ECS group already references this one and terraform
# would see a cycle, so its own inbound rules name the VPC CIDR instead.

resource "aws_security_group" "untrusted_code" {
  name_prefix = "${var.name_prefix}-untrusted-code-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Executor runs from geolang-api"
  }

  # image pulls, secrets and log delivery all leave over the task ENI, and the
  # download tools read OSM, Natural Earth and GHS-POP over https
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to ECR, Secrets Manager, CloudWatch and remote data sources"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
    description = "Cloud Map and public name resolution"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Cloud Map and public name resolution"
  }

  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "EFS mounts"
  }

  egress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "ptolemy, tiletopia, geokode and itinera tool calls"
  }

  egress {
    from_port   = 8100
    to_port     = 8100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "geodukt workflow calls"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-untrusted-code-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Jupyter Security Group ──────────────────────────────────────────────────
#
# Jupyter also runs user-supplied code, but it calls no platform service, so it
# gets none of the executor group's tool-call egress. Notebooks reach the
# internet on 443 the same way the executor does.

resource "aws_security_group" "jupyter" {
  name_prefix = "${var.name_prefix}-jupyter-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8888
    to_port         = 8888
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
    description     = "Notebook traffic from the platform proxy"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS to ECR, Secrets Manager, CloudWatch and package indexes"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
    description = "Cloud Map and public name resolution"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Cloud Map and public name resolution"
  }

  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "EFS mounts"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-jupyter-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Application Load Balancer ────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

# ─── HTTP Listener ────────────────────────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.certificate_arn != "" ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = var.certificate_arn != "" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = var.certificate_arn == "" ? [1] : []
      content {
        content_type = "application/json"
        message_body = "{\"service\":\"geolang\",\"status\":\"healthy\"}"
        status_code  = "200"
      }
    }
  }
}

# ─── HTTPS Listener (when certificate is provided) ───────────────────────────

resource "aws_lb_listener" "https" {
  count = var.certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"service\":\"geolang\",\"status\":\"healthy\"}"
      status_code  = "200"
    }
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "alb_arn" {
  value = aws_lb.main.arn
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_zone_id" {
  value = aws_lb.main.zone_id
}

output "http_listener_arn" {
  value = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  value = length(aws_lb_listener.https) > 0 ? aws_lb_listener.https[0].arn : ""
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "ecs_security_group_id" {
  value = aws_security_group.ecs.id
}

output "untrusted_code_security_group_id" {
  value = aws_security_group.untrusted_code.id
}

output "agora_security_group_id" {
  value = aws_security_group.agora.id
}

output "jupyter_security_group_id" {
  value = aws_security_group.jupyter.id
}
