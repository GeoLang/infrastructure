# GeoLang Infrastructure — Outputs
#
# All endpoints, URLs, and deployment commands for the platform.

# ─── Access URLs ──────────────────────────────────────────────────────────────

output "platform_url" {
  description = "Primary platform URL"
  value = (
    var.enable_dns && var.domain_name != ""
    ? "https://${var.domain_name}"
    : var.enable_cdn
    ? "https://${module.cdn[0].domain_name}"
    : "http://${module.loadbalancer.alb_dns_name}"
  )
}

output "alb_dns_name" {
  description = "Application Load Balancer DNS name"
  value       = module.loadbalancer.alb_dns_name
}

output "cdn_domain" {
  description = "CloudFront CDN domain name"
  value       = var.enable_cdn ? module.cdn[0].domain_name : "CDN disabled"
}

# ─── Container Registry ──────────────────────────────────────────────────────

output "ecr_repositories" {
  description = "ECR repository URLs for each service"
  value       = module.ecr.repository_urls
}

# ─── Database ────────────────────────────────────────────────────────────────

output "database_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = var.enable_database ? module.database[0].endpoint : "Database disabled"
}

# ─── DNS ──────────────────────────────────────────────────────────────────────

output "name_servers" {
  description = "Route53 name servers (set these at your domain registrar)"
  value       = var.enable_dns && var.domain_name != "" ? module.dns[0].name_servers : []
}

# ─── Monitoring ──────────────────────────────────────────────────────────────

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = module.monitoring.dashboard_url
}

output "alerts_topic_arn" {
  description = "SNS topic ARN — subscribe your email for alerts"
  value       = module.monitoring.sns_topic_arn
}

# ─── S3 ──────────────────────────────────────────────────────────────────────

output "tiles_bucket" {
  description = "S3 bucket for tile and asset storage"
  value       = var.enable_s3_tiles ? aws_s3_bucket.tiles[0].id : "S3 disabled"
}

# ─── ECS ──────────────────────────────────────────────────────────────────────

output "ecs_cluster" {
  description = "ECS cluster name"
  value       = module.ecs.cluster_name
}

output "service_discovery_namespace" {
  description = "Cloud Map namespace for inter-service DNS"
  value       = module.ecs.service_discovery_namespace
}

# ─── Bastion Host ────────────────────────────────────────────────────────────

output "bastion_ssm_command" {
  description = "SSM Session Manager command to connect to bastion"
  value       = var.enable_bastion ? module.bastion[0].ssm_connect_command : "Bastion disabled"
}

output "bastion_db_tunnel_command" {
  description = "SSM port-forwarding command for RDS access"
  value       = var.enable_bastion ? module.bastion[0].db_tunnel_command : "Bastion disabled"
}

# ─── Autoscaling ─────────────────────────────────────────────────────────────

output "autoscaling_enabled" {
  description = "Whether autoscaling is enabled"
  value       = var.enable_autoscaling
}

# ─── WAF ──────────────────────────────────────────────────────────────────────

output "waf_web_acl_id" {
  description = "WAF Web ACL ID"
  value       = var.enable_waf ? module.waf[0].web_acl_id : "WAF disabled"
}

# ─── ElastiCache ─────────────────────────────────────────────────────────────

output "redis_endpoint" {
  description = "Redis endpoint URL"
  value       = var.enable_cache ? module.cache[0].connection_url : "Redis disabled"
}

# ─── EFS ──────────────────────────────────────────────────────────────────────

output "efs_file_system_id" {
  description = "EFS file system ID"
  value       = var.enable_efs ? module.storage[0].file_system_id : "EFS disabled"
}

# ─── Security ────────────────────────────────────────────────────────────────

output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = var.enable_security ? module.security[0].guardduty_detector_id : "Security module disabled"
}

output "vpc_flow_log_group" {
  description = "VPC Flow Logs CloudWatch log group"
  value       = var.enable_security ? module.security[0].flow_log_group : "Security module disabled"
}

# ─── SQS Queues ──────────────────────────────────────────────────────────────

output "sqs_queue_urls" {
  description = "SQS queue URLs for async processing"
  value       = var.enable_queues ? module.queues[0].queue_urls : {}
}

# ─── Backup ──────────────────────────────────────────────────────────────────

output "backup_vault_name" {
  description = "AWS Backup vault name"
  value       = var.enable_backup && var.enable_database ? module.backup[0].vault_name : "Backup disabled"
}

# ─── Deployment Commands ─────────────────────────────────────────────────────

output "deploy_commands" {
  description = "Step-by-step commands to build and deploy all services"
  value       = <<-EOT

    ╔══════════════════════════════════════════════════════════════╗
    ║          GeoLang Platform — Deployment Commands             ║
    ╚══════════════════════════════════════════════════════════════╝

    # 1. Authenticate with ECR:
    aws ecr get-login-password --region ${var.aws_region} \
      | docker login --username AWS --password-stdin \
        $(aws sts get-caller-identity --query Account --output text).dkr.ecr.${var.aws_region}.amazonaws.com

    # 2. Build and push each service:
    %{for svc in local.enabled_services~}
    %{if svc != "letta"~}
    docker build -t ${module.ecr.repository_urls[svc]}:latest ../${svc}/
    docker push ${module.ecr.repository_urls[svc]}:latest
    %{endif~}
    %{endfor~}

    # 3. Force new deployment of all services:
    %{for svc in local.enabled_services~}
    aws ecs update-service --cluster ${local.name_prefix} \
      --service ${local.name_prefix}-${svc} --force-new-deployment
    %{endfor~}

    # 4. Verify platform health:
    curl ${var.enable_cdn ? "https://${module.cdn[0].domain_name}" : "http://${module.loadbalancer.alb_dns_name}"}/api/v1/health

    # 5. Subscribe to alerts (replace with your email):
    aws sns subscribe --topic-arn ${module.monitoring.sns_topic_arn} \
      --protocol email --notification-endpoint your@email.com

  EOT
}
