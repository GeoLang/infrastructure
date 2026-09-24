# GeoLang Infrastructure - Input Variables
#
# All configurable parameters for the GeoLang platform deployment.
# Override defaults via terraform.tfvars or -var flags.

# ─── General ──────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "geolang"
}

# ─── Domain & DNS ─────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Primary domain name (e.g., geolang.com)"
  type        = string
  default     = ""
}

variable "enable_dns" {
  description = "Create Route53 hosted zone and ACM certificate"
  type        = bool
  default     = false
}

variable "existing_hosted_zone_id" {
  description = "Zone ID of an existing hosted zone for domain_name, empty creates a new zone"
  type        = string
  default     = ""
}

# ─── Service Toggles ─────────────────────────────────────────────────────────

variable "enable_ptolemy" {
  description = "Deploy Ptolemy geodatabase API (requires RDS)"
  type        = bool
  default     = true
}

variable "enable_tiletopia" {
  description = "Deploy TileTopia 3D Tiles / terrain server"
  type        = bool
  default     = true
}

variable "enable_geokode" {
  description = "Deploy Geokode geocoding service"
  type        = bool
  default     = false
}

variable "enable_itinera" {
  description = "Deploy Itinera routing service"
  type        = bool
  default     = false
}

variable "enable_interiora" {
  description = "Deploy Interiora indoor mapping service"
  type        = bool
  default     = false
}

variable "enable_geoplumb" {
  description = "Deploy geoplumb windowed raster tile service"
  type        = bool
  default     = false
}

variable "enable_fenestra" {
  description = "Deploy Fenestra OGC services gateway"
  type        = bool
  default     = false
}

variable "enable_agora" {
  description = "Deploy Agora live collaboration service and its database"
  type        = bool
  default     = false
}

variable "enable_sibyl" {
  description = "Deploy Sibyl agent loop service"
  type        = bool
  default     = false
}

variable "enable_geodukt" {
  description = "Deploy Geodukt pipeline service"
  type        = bool
  default     = false
}

variable "enable_geolang_executor" {
  description = "Deploy the isolated GeoLang tool executor"
  type        = bool
  default     = false
}

variable "enable_jupyter" {
  description = "Deploy Jupyter kernels for ViewTopia notebooks"
  type        = bool
  default     = false
}

variable "enable_platform_proxy" {
  description = "Deploy the public edge proxy that applies platform path rewrites"
  type        = bool
  default     = true
}

variable "enable_geolang" {
  description = "Deploy GeoLang AI agent"
  type        = bool
  default     = true
}

variable "enable_viewtopia" {
  description = "Deploy ViewTopia web frontend"
  type        = bool
  default     = true
}

variable "enable_cdn" {
  description = "Deploy CloudFront CDN in front of the platform"
  type        = bool
  default     = true
}

variable "enable_demo_landing_page" {
  description = "Serve the static demo landing page from S3 through CloudFront, with its wake and idle scale-down functions"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_demo_landing_page || (var.enable_cdn && var.enable_geolang && var.nightly_scale_down != null)
    error_message = "enable_demo_landing_page needs enable_cdn, enable_geolang, and nightly_scale_down."
  }
}

variable "allow_cleartext_origin" {
  description = "Let CloudFront reach the load balancer over plain HTTP when no domain is configured"
  type        = bool
  default     = false
}

# ─── Database (Aurora PostgreSQL Serverless v2) ──────────────────────────────

variable "enable_database" {
  description = "Deploy the Aurora PostgreSQL cluster"
  type        = bool
  default     = true
}

variable "enable_database_secret_refresh" {
  description = "Refresh runtime database URLs after RDS password rotation"
  type        = bool
  default     = true
}

variable "db_max_capacity" {
  description = "Aurora Serverless v2 maximum capacity in ACUs"
  type        = number
  default     = 2
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "ptolemy"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "ptolemy"
}

# ─── ECS / Fargate Sizing ────────────────────────────────────────────────────

variable "nightly_scale_down" {
  description = "Stop every ECS service daily at this local hour"
  type = object({
    timezone = string
    hour     = number
  })
  default = null

  validation {
    condition     = var.nightly_scale_down == null ? true : var.nightly_scale_down.hour >= 0 && var.nightly_scale_down.hour <= 23
    error_message = "nightly_scale_down.hour must be between 0 and 23."
  }
}

variable "morning_scale_up_hour" {
  description = "Start every ECS service daily at this hour in the nightly_scale_down timezone"
  type        = number
  default     = 8

  validation {
    condition     = var.morning_scale_up_hour >= 0 && var.morning_scale_up_hour <= 23 && var.morning_scale_up_hour != try(var.nightly_scale_down.hour, null)
    error_message = "morning_scale_up_hour must be between 0 and 23 and differ from nightly_scale_down.hour."
  }
}

variable "use_fargate_spot" {
  description = "Run every ECS task on Fargate Spot"
  type        = bool
  default     = true
}

variable "service_defaults" {
  description = "Default Fargate task sizing for all services"
  type = object({
    cpu           = number
    memory        = number
    desired_count = number
  })
  default = {
    cpu           = 256 # 0.25 vCPU
    memory        = 512 # 0.5 GB
    desired_count = 1
  }
}

variable "service_overrides" {
  description = "Per-service Fargate sizing overrides (keyed by service name)"
  type = map(object({
    cpu           = optional(number)
    memory        = optional(number)
    desired_count = optional(number)
  }))
  default = {}
}

# ─── Container Images ────────────────────────────────────────────────────────

variable "image_tag" {
  description = "Tag deployed from every ECR repository. Tags are immutable, so a new build needs a new tag."
  type        = string
  default     = "v0.1.0"
}

variable "container_images" {
  description = "Docker image URIs per service (leave empty to use ECR defaults)"
  type        = map(string)
  default     = {}
}

variable "llm_api_base" {
  description = "OpenAI-compatible base URL passed to Sibyl as SIBYL_CLOUD_API_BASE"
  type        = string
  default     = ""
}

variable "llm_models" {
  description = "Model identifiers passed to Sibyl as SIBYL_CLOUD_MODELS"
  type        = string
  default     = ""
}

variable "llm_monthly_spend_limit_usd" {
  description = "Dollars of model calls per UTC month after which Sibyl refuses them, passed as SIBYL_MONTHLY_SPEND_LIMIT_USD. 0 means no limit"
  type        = number
  default     = 0
}

variable "llm_model_prices" {
  description = "model=input/output in USD per million tokens, comma separated, passed to Sibyl as SIBYL_MODEL_PRICES. Every model in llm_models needs one when llm_monthly_spend_limit_usd is set"
  type        = string
  default     = ""
}

variable "monthly_spend_budget_usd" {
  description = "AWS cost budget per month, credits excluded. At 100 percent it denies Bedrock to bedrock_api_key_user. 0 means no budget"
  type        = number
  default     = 0
}

variable "bedrock_api_key_user" {
  description = "IAM user that holds Sibyl's Bedrock API key, the target of the budget's deny"
  type        = string
  default     = ""
}

variable "geolang_limits" {
  description = "Numeric GEOLANG_* limits passed to geolang-api by name (upload, tool run, output and retention caps), whole numbers, 0 or a missing key means no limit"
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for name, value in var.geolang_limits : startswith(name, "GEOLANG_") && value >= 0 && floor(value) == value])
    error_message = "geolang_limits keys must start with GEOLANG_ and values must be whole numbers, 0 or more."
  }
}

variable "sibyl_limits" {
  description = "Numeric SIBYL_* per-user daily limits passed to Sibyl by name, whole numbers, 0 or a missing key means no limit"
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for name, value in var.sibyl_limits : startswith(name, "SIBYL_") && value >= 0 && floor(value) == value])
    error_message = "sibyl_limits keys must start with SIBYL_ and values must be whole numbers, 0 or more."
  }
}

variable "ptolemy_limits" {
  description = "Numeric PTOLEMY_MAX_* per-user quotas passed to ptolemy by name, whole numbers, 0 or a missing key means no limit"
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for name, value in var.ptolemy_limits : startswith(name, "PTOLEMY_MAX_") && value >= 0 && floor(value) == value])
    error_message = "ptolemy_limits keys must start with PTOLEMY_MAX_ and values must be whole numbers, 0 or more."
  }
}

variable "tiletopia_limits" {
  description = "Numeric TILETOPIA_* signup and login limits passed to tiletopia by name, whole numbers, a missing key keeps tiletopia's default"
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for name, value in var.tiletopia_limits : startswith(name, "TILETOPIA_") && value >= 0 && floor(value) == value])
    error_message = "tiletopia_limits keys must start with TILETOPIA_ and values must be whole numbers, 0 or more."
  }
}

variable "llm_locked_profile" {
  description = "Sibyl profile id every run uses, passed as SIBYL_LOCKED_PROFILE. Empty lets each user pick"
  type        = string
  default     = ""
}

variable "jupyter_image" {
  description = "Pinned Jupyter Docker Stacks image"
  type        = string
  default     = "quay.io/jupyter/scipy-notebook:2025-12-31"
}

variable "runtime_secrets_ready" {
  description = "Start services after images, data, and runtime secrets are ready"
  type        = bool
  default     = false
}

variable "runtime_secret_arns" {
  description = "Existing Secrets Manager or SSM ARNs keyed by runtime secret name"
  type        = map(string)
  default     = {}
}

# ─── Networking ──────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 2
}

# ─── Monitoring ──────────────────────────────────────────────────────────────

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "enable_container_insights" {
  description = "Enable ECS Container Insights"
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alerts topic (empty = no subscriber)"
  type        = string
  default     = ""
}

# ─── S3 Storage ──────────────────────────────────────────────────────────────

variable "enable_s3_tiles" {
  description = "Create S3 bucket for tile/asset storage"
  type        = bool
  default     = true
}

# ─── Autoscaling ─────────────────────────────────────────────────────────────

variable "enable_autoscaling" {
  description = "Enable ECS service auto scaling"
  type        = bool
  default     = false
}

variable "autoscaling_config" {
  description = "Per-service autoscaling configuration"
  type = map(object({
    min_capacity  = optional(number, 1)
    max_capacity  = optional(number, 4)
    cpu_target    = optional(number, 70)
    memory_target = optional(number, 75)
  }))
  default = {}
}

# ─── Bastion Host ────────────────────────────────────────────────────────────

variable "enable_bastion" {
  description = "Deploy bastion host for SSH/SSM access to private resources"
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "Bastion EC2 instance type"
  type        = string
  default     = "t4g.nano"
}

variable "bastion_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH to bastion (empty = SSM only)"
  type        = list(string)
  default     = []
}

# ─── WAF ─────────────────────────────────────────────────────────────────────

variable "enable_waf" {
  description = "Deploy AWS WAF on the ALB"
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "WAF rate limit, max requests per 5-minute window per client address"
  type        = number
  default     = 2000
}

variable "cloudfront_rate_limits" {
  description = "Requests per client address per 5 minutes that a WAF on CloudFront allows, overall and to /api/v1/auth/. Null means no WAF on CloudFront"
  type = object({
    requests_per_ip      = number
    auth_requests_per_ip = number
  })
  default = null
}

variable "waf_blocked_countries" {
  description = "ISO country codes to block at WAF (e.g., [\"CN\", \"RU\"])"
  type        = list(string)
  default     = []
}

# ─── EFS Storage ─────────────────────────────────────────────────────────────

variable "enable_efs" {
  description = "Deploy EFS for persistent shared storage"
  type        = bool
  default     = false
}

# ─── Secrets Manager ─────────────────────────────────────────────────────────

variable "enable_secrets" {
  description = "Deploy Secrets Manager for credential management"
  type        = bool
  default     = false
}

# ─── Security (GuardDuty + VPC Flow Logs) ─────────────────────────────────────

variable "enable_security" {
  description = "Deploy GuardDuty threat detection and VPC Flow Logs"
  type        = bool
  default     = false
}

variable "enable_guardduty" {
  description = "Enable GuardDuty (within security module)"
  type        = bool
  default     = true
}

# ─── Backup ──────────────────────────────────────────────────────────────────

variable "enable_backup" {
  description = "Deploy AWS Backup vault for RDS and EFS"
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30
}

variable "enable_cross_region_backup" {
  description = "Enable cross-region backup copy for disaster recovery"
  type        = bool
  default     = false
}

variable "dr_region" {
  description = "AWS region for disaster recovery backup copies"
  type        = string
  default     = "us-west-2"
}
