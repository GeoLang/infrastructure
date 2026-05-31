# GeoLang Infrastructure — Autoscaling Module
#
# ECS Service Auto Scaling with target tracking policies based on
# CPU and memory utilization. Scales services up/down automatically.

variable "name_prefix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "services" {
  description = "Map of service names to autoscaling config"
  type = map(object({
    ecs_service_name = string
    min_capacity     = number
    max_capacity     = number
    cpu_target       = number
    memory_target    = number
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Auto Scaling Targets ────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "ecs" {
  for_each = var.services

  max_capacity       = each.value.max_capacity
  min_capacity       = each.value.min_capacity
  resource_id        = "service/${var.ecs_cluster_name}/${each.value.ecs_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = merge(var.tags, { Service = each.key })
}

# ─── CPU Target Tracking ─────────────────────────────────────────────────────

resource "aws_appautoscaling_policy" "cpu" {
  for_each = var.services

  name               = "${var.name_prefix}-${each.key}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = each.value.cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ─── Memory Target Tracking ──────────────────────────────────────────────────

resource "aws_appautoscaling_policy" "memory" {
  for_each = var.services

  name               = "${var.name_prefix}-${each.key}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = each.value.memory_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "scaling_targets" {
  description = "Auto scaling target resource IDs"
  value       = { for k, v in aws_appautoscaling_target.ecs : k => v.resource_id }
}
