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

variable "task_subnet_ids" {
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

variable "use_fargate_spot" {
  description = "Run tasks on Fargate Spot instead of on-demand Fargate"
  type        = bool
  default     = true
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
    # extra groups the task carries so another service's ingress can name it
    additional_security_group_ids = optional(list(string), [])
    mount_points = optional(list(object({
      source_volume  = string
      container_path = string
      read_only      = optional(bool, false)
    })), [])
    efs_volumes = optional(map(object({
      file_system_id   = string
      file_system_arn  = string
      access_point_id  = string
      access_point_arn = string
    })), {})
    ephemeral_storage_gib = optional(number)
    # the module creates volume as task-local storage
    init_container = optional(object({
      image          = string
      command        = list(string)
      volume         = string
      container_path = string
    }))
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

variable "origin_verify_header" {
  description = "Header a request must carry for the listener rule to forward it, null to forward everything"
  type = object({
    name  = string
    value = string
  })
  default = null
}

locals {
  public_services     = { for name, service in var.services : name => service if service.public }
  service_secret_arns = flatten([for service in values(var.services) : [for secret in service.secrets : secret.valueFrom]])
  secret_arns         = distinct(local.service_secret_arns)

  service_security_group_ids = {
    for name, service in var.services : name => coalesce(
      service.security_group_id,
      service.runs_untrusted_code ? var.untrusted_code_security_group_id : var.ecs_security_group_id,
    )
  }

  untrusted_code_services = { for name, service in var.services : name => service if service.runs_untrusted_code }

  efs_client_grants = {
    for name, service in var.services : name => {
      runs_untrusted_code = service.runs_untrusted_code
      file_system_arns    = distinct([for volume in values(service.efs_volumes) : volume.file_system_arn])
      access_point_arns_by_action = {
        "elasticfilesystem:ClientMount" = [for volume in values(service.efs_volumes) : volume.access_point_arn]
        "elasticfilesystem:ClientWrite" = [
          for volume_name, volume in service.efs_volumes : volume.access_point_arn
          if anytrue([for mount in service.mount_points : mount.source_volume == volume_name && !mount.read_only])
        ]
      }
    } if length(service.efs_volumes) > 0
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

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
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
  count = length(local.service_secret_arns) > 0 ? 1 : 0

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

# user code can read these credentials, so each role holds only EFS client grants for its own service's access points
resource "aws_iam_role" "ecs_task_untrusted_code" {
  for_each = local.untrusted_code_services

  name = "${var.name_prefix}-${each.key}-untrusted-code"

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

resource "aws_iam_role_policy" "efs_client" {
  for_each = local.efs_client_grants

  name = "${var.name_prefix}-${each.key}-efs-client"
  role = each.value.runs_untrusted_code ? aws_iam_role.ecs_task_untrusted_code[each.key].id : aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for action, access_point_arns in each.value.access_point_arns_by_action : {
        Effect    = "Allow"
        Action    = action
        Resource  = each.value.file_system_arns
        Condition = { StringEquals = { "elasticfilesystem:AccessPointArn" = access_point_arns } }
      } if length(access_point_arns) > 0
    ]
  })
}

# ─── CloudWatch Log Groups ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "services" {
  for_each = var.services

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, { Service = each.key })
}

locals {
  log_configurations = {
    for name, log_group in aws_cloudwatch_log_group.services : name => {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = log_group.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }

  init_container_definitions = {
    for name, service in var.services : name => service.init_container == null ? [] : [{
      name      = "${name}-init"
      image     = service.init_container.image
      essential = false
      command   = service.init_container.command
      mountPoints = [{
        sourceVolume  = service.init_container.volume
        containerPath = service.init_container.container_path
        readOnly      = false
      }]
      logConfiguration = local.log_configurations[name]
    }]
  }
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
  task_role_arn            = each.value.runs_untrusted_code ? aws_iam_role.ecs_task_untrusted_code[each.key].arn : aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  dynamic "volume" {
    for_each = each.value.efs_volumes
    content {
      name = volume.key

      efs_volume_configuration {
        file_system_id     = volume.value.file_system_id
        transit_encryption = "ENABLED"

        authorization_config {
          access_point_id = volume.value.access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }

  dynamic "volume" {
    for_each = each.value.init_container == null ? [] : [each.value.init_container.volume]
    content {
      name = volume.value
    }
  }

  dynamic "ephemeral_storage" {
    for_each = each.value.ephemeral_storage_gib == null ? [] : [each.value.ephemeral_storage_gib]
    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  container_definitions = jsonencode(concat(local.init_container_definitions[each.key], [{
    name  = each.key
    image = each.value.image
    dependsOn = length(local.init_container_definitions[each.key]) > 0 ? [
      for init_container in local.init_container_definitions[each.key] : { containerName = init_container.name, condition = "SUCCESS" }
    ] : null
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
        add  = []
        drop = each.value.dropped_capabilities
      }
    } : null

    logConfiguration = local.log_configurations[each.key]

    healthCheck = {
      command     = length(each.value.health_command) > 0 ? each.value.health_command : ["CMD-SHELL", "curl -f http://localhost:${each.value.container_port}${each.value.health_path} || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }]))

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

  dynamic "condition" {
    for_each = var.origin_verify_header == null ? [] : [var.origin_verify_header]
    content {
      http_header {
        http_header_name = condition.value.name
        values           = [condition.value.value]
      }
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

  dynamic "condition" {
    for_each = var.origin_verify_header == null ? [] : [var.origin_verify_header]
    content {
      http_header {
        http_header_name = condition.value.name
        values           = [condition.value.value]
      }
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
  launch_type     = var.use_fargate_spot ? null : "FARGATE"

  dynamic "capacity_provider_strategy" {
    for_each = var.use_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
    }
  }

  # tasks carry a public IP instead of routing through a NAT gateway
  network_configuration {
    subnets          = var.task_subnet_ids
    security_groups  = concat([local.service_security_group_ids[each.key]], each.value.additional_security_group_ids)
    assign_public_ip = true
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
    aws_ecs_cluster_capacity_providers.main,
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

output "log_group_names" {
  value = { for k, v in aws_cloudwatch_log_group.services : k => v.name }
}

output "task_definition_arns" {
  value = { for k, v in aws_ecs_task_definition.services : k => v.arn }
}
