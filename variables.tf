# GeoLang Infrastructure — Input Variables
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

variable "enable_geolang" {
  description = "Deploy GeoLang AI agent (includes Letta)"
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

# ─── Database (RDS PostGIS) ──────────────────────────────────────────────────

variable "enable_database" {
  description = "Deploy RDS PostgreSQL with PostGIS"
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
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

variable "db_password" {
  description = "PostgreSQL master password (use SSM Parameter Store in production)"
  type        = string
  sensitive   = true
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS (production HA)"
  type        = bool
  default     = false
}

# ─── ECS / Fargate Sizing ────────────────────────────────────────────────────

variable "service_defaults" {
  description = "Default Fargate task sizing for all services"
  type = object({
    cpu           = number
    memory        = number
    desired_count = number
  })
  default = {
    cpu           = 256  # 0.25 vCPU
    memory        = 512  # 0.5 GB
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

variable "container_images" {
  description = "Docker image URIs per service (leave empty to use ECR defaults)"
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
