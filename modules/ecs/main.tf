# GeoLang Infrastructure - ECS Module
#
# ECS Fargate cluster with service discovery (Cloud Map) and
# individual task definitions for each GeoLang service.

variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_security_group_id" {
  type = string
}

variable "untrusted_code_security_group_id" {
  description = "Security group for services that run user-supplied code"
  type        = string
}

variable "enable_container_insights" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Service definitions ─────────────────────────────────────────────────────
# Each entry defines an ECS service with its container config.

variable "services" {
  description = "Map of service definitions to deploy"
  type = map(object({
    image                    = string
    cpu                      = number
    memory                   = number
    desired_count            = number
    container_port           = number
    health_path              = string
    health_command           = optional(list(string), [])
    environment              = list(object({ name = string, value = string }))
    secrets                  = optional(list(object({ name = string, valueFrom = string })), [])
    command                  = optional(list(string), [])
    public                   = optional(bool, false)
    user                     = optional(string)
    working_directory        = optional(string)
    readonly_root_filesystem = optional(bool, false)
    dropped_capabilities     = optional(list(string), [])
    runs_untrusted_code      = optional(bool, false)
    security_group_id        = optional(string)
    mount_points = optional(list(object({
      source_volume  = string
      container_path = string
      read_only      = optional(bool, false)
    })), [])
    efs_volumes = optional(map(object({
      file_system_id  = string
      access_point_id = string
    })), {})
  }))
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ALB integration
variable "alb_listener_arn" {
  description = "ALB listener ARN for target group attachment"
  type        = string
}

variable "alb_listener_https_arn" {
  description = "HTTPS ALB listener ARN (empty if no HTTPS)"
  type        = string
  default     = ""
}

locals {
  public_services = { for name, service in var.services : name => service if service.public }
  secret_arns     = distinct(flatten([for service in values(var.services) : [for secret in service.secrets : secret.valueFrom]]))

  service_security_group_ids = {
    for name, service in var.services : name => coalesce(
      service.security_group_id,
      service.runs_untrusted_code ? var.untrusted_code_security_group_id : var.ecs_security_group_id,
    )
  }
}

# ─── ECS Cluster ──────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = var.tags
}

# ─── Service Discovery (Cloud Map) ───────────────────────────────────────────
# Enables inter-service communication via DNS names like
# ptolemy.geolang.local, tiletopia.geolang.local, etc.

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.name_prefix}.local"
  vpc  = var.vpc_id

  tags = var.tags
}

resource "aws_service_discovery_service" "services" {
  for_each = var.services

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

# ─── IAM Roles ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_execution" {
  name = "${var.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow pulling secrets from SSM Parameter Store
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  count = length(local.secret_arns) > 0 ? 1 : 0

  name = "${var.name_prefix}-ssm-read"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameters",
        "ssm:GetParameter",
        "secretsmanager:GetSecretValue",
      ]
      Resource = local.secret_arns
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# Services running user-supplied code get their own role: any code they run can
# read the role's credentials from the task metadata endpoint, so it holds no
# policies at all.
resource "aws_iam_role" "ecs_task_untrusted_code" {
  name = "${var.name_prefix}-ecs-task-untrusted-code"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# S3 access for services that need tile storage
resource "aws_iam_role_policy" "ecs_s3" {
  name = "${var.name_prefix}-s3-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = ["arn:aws:s3:::${var.name_prefix}-*", "arn:aws:s3:::${var.name_prefix}-*/*"]
    }]
  })
}

# ─── CloudWatch Log Groups ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "services" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, { Service = each.key })
}

# ─── Task Definitions ────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "services" {
  for_each = var.services

  family                   = "${var.name_prefix}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = each.value.runs_untrusted_code ? aws_iam_role.ecs_task_untrusted_code.arn : aws_iam_role.ecs_task.arn

  dynamic "volume" {
    for_each = each.value.efs_volumes
    content {
      name = volume.key

      efs_volume_configuration {
        file_system_id     = volume.value.file_system_id
        transit_encryption = "ENABLED"

        authorization_config {
          access_point_id = volume.value.access_point_id
          iam             = "DISABLED"
        }
      }
    }
  }

  container_definitions = jsonencode([{
    name  = each.key
    image = each.value.image
    portMappings = [{
      containerPort = each.value.container_port
      protocol      = "tcp"
    }]
    environment            = each.value.environment
    secrets                = each.value.secrets
    command                = length(each.value.command) > 0 ? each.value.command : null
    user                   = each.value.user
    workingDirectory       = each.value.working_directory
    readonlyRootFilesystem = each.value.readonly_root_filesystem
    mountPoints = [for mount in each.value.mount_points : {
      sourceVolume  = mount.source_volume
      containerPath = mount.container_path
      readOnly      = mount.read_only
    }]
    linuxParameters = length(each.value.dropped_capabilities) > 0 ? {
      capabilities = {
        drop = each.value.dropped_capabilities
      }
    } : null

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.services[each.key].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = length(each.value.health_command) > 0 ? each.value.health_command : ["CMD-SHELL", "curl -f http://localhost:${each.value.container_port}${each.value.health_path} || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = merge(var.tags, { Service = each.key })
}

# ─── ALB Target Groups ───────────────────────────────────────────────────────

resource "aws_lb_target_group" "services" {
  for_each = local.public_services

  name        = "${var.name_prefix}-${each.key}"
  port        = each.value.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = each.value.health_path
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  tags = merge(var.tags, { Service = each.key })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = length(local.public_services) <= 1
      error_message = "At most one ECS service can be public because the ALB has one catch-all route."
    }
  }
}

# The edge proxy is the only public target. It applies the platform's prefix
# rewrites before using Cloud Map to reach private services.

resource "aws_lb_listener_rule" "http" {
  for_each = var.alb_listener_https_arn == "" ? local.public_services : {}

  listener_arn = var.alb_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "https" {
  for_each = var.alb_listener_https_arn != "" ? local.public_services : {}

  listener_arn = var.alb_listener_https_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  tags = var.tags
}

# ─── ECS Services ────────────────────────────────────────────────────────────

resource "aws_ecs_service" "services" {
  for_each = var.services

  name            = "${var.name_prefix}-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.services[each.key].arn
  desired_count   = each.value.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [local.service_security_group_ids[each.key]]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = each.value.public ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.services[each.key].arn
      container_name   = each.key
      container_port   = each.value.container_port
    }
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services[each.key].arn
  }

  depends_on = [
    aws_lb_listener_rule.http,
    aws_lb_listener_rule.https,
  ]

  tags = merge(var.tags, { Service = each.key })
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "service_discovery_namespace" {
  value = aws_service_discovery_private_dns_namespace.main.name
}

output "service_names" {
  value = { for k, v in aws_ecs_service.services : k => v.name }
}

output "task_definition_arns" {
  value = { for k, v in aws_ecs_task_definition.services : k => v.arn }
}
