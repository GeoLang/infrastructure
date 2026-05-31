# GeoLang Platform — AWS Infrastructure
#
# One-click deployment of the GeoLang intelligent geospatial suite.
#
# Quick start:
#   cp terraform.tfvars.example terraform.tfvars
#   # Edit terraform.tfvars with your settings
#   terraform init
#   terraform apply
#
# Deployment profiles:
#   terraform apply -var-file=profiles/minimal.tfvars   # Dev: 4 services
#   terraform apply -var-file=profiles/platform.tfvars  # Full: all services + RDS
#
# Architecture:
#   ┌─────────────────────────────────────────────────────────────┐
#   │                      CloudFront CDN                        │
#   │            (geolang.com → tile caching at edge)            │
#   └─────────────────────────┬───────────────────────────────────┘
#                             │
#   ┌─────────────────────────▼───────────────────────────────────┐
#   │              Application Load Balancer                      │
#   │         (path-based routing to all services)                │
#   │                                                             │
#   │  /agent/*  → GeoLang    /tiles/* → TileTopia               │
#   │  /api/*    → Ptolemy    /api/geocode/* → Geokode           │
#   │  /*        → ViewTopia  /api/route* → Itinera              │
#   └─────────────────────────┬───────────────────────────────────┘
#                             │
#   ┌─────────────────────────▼───────────────────────────────────┐
#   │              ECS Fargate (private subnets)                  │
#   │                                                             │
#   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
#   │  │ ViewTopia│ │ Ptolemy  │ │TileTopia │ │ GeoLang  │      │
#   │  │ (nginx)  │ │ (Rust)   │ │ (Rust)   │ │ (Python) │      │
#   │  └──────────┘ └──────────┘ └──────────┘ └────┬─────┘      │
#   │  ┌──────────┐ ┌──────────┐                    │            │
#   │  │ Geokode  │ │ Itinera  │               ┌────▼─────┐     │
#   │  │ (Rust)   │ │ (Rust)   │               │  Letta   │     │
#   │  └──────────┘ └──────────┘               │ (AI Mem) │     │
#   │                                           └──────────┘     │
#   │  Service Discovery: *.geolang.local (Cloud Map)            │
#   └─────────────────────────┬───────────────────────────────────┘
#                             │
#   ┌─────────────────────────▼───────────────────────────────────┐
#   │              RDS PostgreSQL 16 + PostGIS                    │
#   │              (private subnets, encrypted)                   │
#   └─────────────────────────────────────────────────────────────┘

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # ── Determine which services to deploy ──────────────────────────
  # Letta is implicitly enabled when GeoLang is enabled.
  enabled_services = compact([
    var.enable_ptolemy ? "ptolemy" : "",
    var.enable_tiletopia ? "tiletopia" : "",
    var.enable_geokode ? "geokode" : "",
    var.enable_itinera ? "itinera" : "",
    var.enable_geolang ? "geolang" : "",
    var.enable_geolang ? "letta" : "",
    var.enable_viewtopia ? "viewtopia" : "",
  ])

  # ── Resolve container images ────────────────────────────────────
  # Use provided image or fall back to ECR repository URL.
  service_images = {
    for svc in local.enabled_services : svc => (
      lookup(var.container_images, svc, "") != ""
      ? var.container_images[svc]
      : "${module.ecr.repository_urls[svc]}:latest"
    )
  }

  # ── Resolve Fargate sizing per service ──────────────────────────
  service_sizing = {
    for svc in local.enabled_services : svc => {
      cpu           = lookup(lookup(var.service_overrides, svc, {}), "cpu", null) != null ? var.service_overrides[svc].cpu : var.service_defaults.cpu
      memory        = lookup(lookup(var.service_overrides, svc, {}), "memory", null) != null ? var.service_overrides[svc].memory : var.service_defaults.memory
      desired_count = lookup(lookup(var.service_overrides, svc, {}), "desired_count", null) != null ? var.service_overrides[svc].desired_count : var.service_defaults.desired_count
    }
  }

  # ── Service discovery DNS suffix ────────────────────────────────
  sd_suffix = "${var.project_name}-${var.environment}.local"

  # ── Database URL (only when RDS is enabled) ─────────────────────
  database_url = var.enable_database ? module.database[0].database_url : ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORKING
# ═══════════════════════════════════════════════════════════════════════════════

module "networking" {
  source = "./modules/networking"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.availability_zone_count
  tags        = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOAD BALANCER
# ═══════════════════════════════════════════════════════════════════════════════

module "loadbalancer" {
  source = "./modules/loadbalancer"

  name_prefix       = local.name_prefix
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  certificate_arn   = var.enable_dns && var.domain_name != "" ? module.dns[0].certificate_arn : ""
  tags              = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# DATABASE (RDS PostGIS)
# ═══════════════════════════════════════════════════════════════════════════════

module "database" {
  source = "./modules/database"
  count  = var.enable_database ? 1 : 0

  name_prefix           = local.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  ecs_security_group_id = module.loadbalancer.ecs_security_group_id

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  multi_az          = var.db_multi_az

  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : ""

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONTAINER REGISTRY (ECR)
# ═══════════════════════════════════════════════════════════════════════════════

module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  services    = local.enabled_services
  tags        = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# ECS FARGATE (Compute)
# ═══════════════════════════════════════════════════════════════════════════════

module "ecs" {
  source = "./modules/ecs"

  name_prefix               = local.name_prefix
  aws_region                = var.aws_region
  vpc_id                    = module.networking.vpc_id
  private_subnet_ids        = module.networking.private_subnet_ids
  ecs_security_group_id     = module.loadbalancer.ecs_security_group_id
  enable_container_insights = var.enable_container_insights
  log_retention_days        = var.log_retention_days
  vpc_cidr                  = module.networking.vpc_cidr_block

  alb_listener_arn       = module.loadbalancer.http_listener_arn
  alb_listener_https_arn = module.loadbalancer.https_listener_arn

  tags = local.tags

  # ── Service Definitions ───────────────────────────────────────────
  services = merge(
    # ── Ptolemy (Geodatabase API) ─────────────────────────────────
    var.enable_ptolemy ? {
      ptolemy = {
        image          = local.service_images["ptolemy"]
        cpu            = local.service_sizing["ptolemy"].cpu
        memory         = local.service_sizing["ptolemy"].memory
        desired_count  = local.service_sizing["ptolemy"].desired_count
        container_port = 3000
        health_path    = "/api/v1/health"
        command        = ["ptolemy", "serve", "--bind", "0.0.0.0:3000", "--database-url", local.database_url]
        environment = [
          { name = "RUST_LOG", value = "info,ptolemy_api=debug" },
          { name = "PTOLEMY_PORT", value = "3000" },
        ]
      }
    } : {},

    # ── TileTopia (3D Tiles / Terrain) ────────────────────────────
    var.enable_tiletopia ? {
      tiletopia = {
        image          = local.service_images["tiletopia"]
        cpu            = local.service_sizing["tiletopia"].cpu
        memory         = local.service_sizing["tiletopia"].memory
        desired_count  = local.service_sizing["tiletopia"].desired_count
        container_port = 3000
        health_path    = "/api/v1/health"
        command        = []
        environment = [
          { name = "TILETOPIA_PORT", value = "3000" },
          { name = "TILETOPIA_HOST", value = "0.0.0.0" },
          { name = "TILETOPIA_DATA_DIR", value = "/data" },
          { name = "RUST_LOG", value = "info,tiletopia=debug" },
          { name = "AWS_S3_BUCKET", value = var.enable_s3_tiles ? aws_s3_bucket.tiles[0].id : "" },
          { name = "AWS_REGION", value = var.aws_region },
        ]
      }
    } : {},

    # ── Geokode (Geocoding) ───────────────────────────────────────
    var.enable_geokode ? {
      geokode = {
        image          = local.service_images["geokode"]
        cpu            = local.service_sizing["geokode"].cpu
        memory         = local.service_sizing["geokode"].memory
        desired_count  = local.service_sizing["geokode"].desired_count
        container_port = 3000
        health_path    = "/health"
        command        = ["serve", "--bind", "0.0.0.0:3000"]
        environment = [
          { name = "RUST_LOG", value = "info,geokode=debug" },
        ]
      }
    } : {},

    # ── Itinera (Routing) ─────────────────────────────────────────
    var.enable_itinera ? {
      itinera = {
        image          = local.service_images["itinera"]
        cpu            = local.service_sizing["itinera"].cpu
        memory         = local.service_sizing["itinera"].memory
        desired_count  = local.service_sizing["itinera"].desired_count
        container_port = 3000
        health_path    = "/health"
        command        = ["itinera", "serve", "--bind", "0.0.0.0:3000"]
        environment = [
          { name = "RUST_LOG", value = "info,itinera=debug" },
        ]
      }
    } : {},

    # ── Letta (AI Agent Memory Server) ────────────────────────────
    var.enable_geolang ? {
      letta = {
        image          = "letta/letta:latest"
        cpu            = local.service_sizing["letta"].cpu
        memory         = local.service_sizing["letta"].memory
        desired_count  = local.service_sizing["letta"].desired_count
        container_port = 8283
        health_path    = "/v1/health"
        command        = []
        environment = [
          { name = "LETTA_SERVER_PASSWORD", value = "" },
        ]
      }
    } : {},

    # ── GeoLang (AI/NLP Geospatial Agent) ─────────────────────────
    var.enable_geolang ? {
      geolang = {
        image          = local.service_images["geolang"]
        cpu            = local.service_sizing["geolang"].cpu
        memory         = local.service_sizing["geolang"].memory
        desired_count  = local.service_sizing["geolang"].desired_count
        container_port = 8080
        health_path    = "/health"
        command        = []
        environment = concat(
          [
            { name = "GEOLANG_HOST", value = "0.0.0.0" },
            { name = "GEOLANG_PORT", value = "8080" },
            { name = "LETTA_BASE_URL", value = "http://letta.${local.sd_suffix}:8283" },
          ],
          var.enable_ptolemy ? [{ name = "PTOLEMY_URL", value = "http://ptolemy.${local.sd_suffix}:3000" }] : [],
          var.enable_tiletopia ? [{ name = "TILETOPIA_URL", value = "http://tiletopia.${local.sd_suffix}:3000" }] : [],
          var.enable_geokode ? [{ name = "GEOKODE_URL", value = "http://geokode.${local.sd_suffix}:3000" }] : [],
          var.enable_itinera ? [{ name = "ITINERA_URL", value = "http://itinera.${local.sd_suffix}:3000" }] : [],
        )
      }
    } : {},

    # ── ViewTopia (Frontend) ──────────────────────────────────────
    var.enable_viewtopia ? {
      viewtopia = {
        image          = local.service_images["viewtopia"]
        cpu            = local.service_sizing["viewtopia"].cpu
        memory         = local.service_sizing["viewtopia"].memory
        desired_count  = local.service_sizing["viewtopia"].desired_count
        container_port = 5174
        health_path    = "/"
        command        = []
        environment = [
          { name = "NGINX_PORT", value = "5174" },
        ]
      }
    } : {},
  )

  depends_on = [module.ecr]
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 STORAGE (Tile & Asset Bucket)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "tiles" {
  count  = var.enable_s3_tiles ? 1 : 0
  bucket = "${local.name_prefix}-tiles"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "tiles" {
  count  = var.enable_s3_tiles ? 1 : 0
  bucket = aws_s3_bucket.tiles[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tiles" {
  count  = var.enable_s3_tiles ? 1 : 0
  bucket = aws_s3_bucket.tiles[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tiles" {
  count                   = var.enable_s3_tiles ? 1 : 0
  bucket                  = aws_s3_bucket.tiles[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tiles" {
  count  = var.enable_s3_tiles ? 1 : 0
  bucket = aws_s3_bucket.tiles[0].id
  rule {
    id     = "intelligent-tiering"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CDN (CloudFront)
# ═══════════════════════════════════════════════════════════════════════════════

module "cdn" {
  source = "./modules/cdn"
  count  = var.enable_cdn ? 1 : 0

  name_prefix     = local.name_prefix
  alb_dns_name    = module.loadbalancer.alb_dns_name
  domain_name     = var.domain_name
  certificate_arn = var.enable_dns && var.domain_name != "" ? module.dns[0].certificate_arn : ""
  tags            = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# DNS (Route53 + ACM)
# ═══════════════════════════════════════════════════════════════════════════════

module "dns" {
  source = "./modules/dns"
  count  = var.enable_dns && var.domain_name != "" ? 1 : 0

  providers = {
    aws = aws.us_east_1
  }

  name_prefix = local.name_prefix
  domain_name = var.domain_name

  cloudfront_domain_name    = var.enable_cdn ? module.cdn[0].domain_name : ""
  cloudfront_hosted_zone_id = var.enable_cdn ? module.cdn[0].hosted_zone_id : ""
  alb_dns_name              = module.loadbalancer.alb_dns_name
  alb_zone_id               = module.loadbalancer.alb_zone_id

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# MONITORING
# ═══════════════════════════════════════════════════════════════════════════════

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix      = local.name_prefix
  aws_region       = var.aws_region
  ecs_cluster_name = module.ecs.cluster_name
  alb_arn_suffix   = module.loadbalancer.alb_dns_name
  rds_instance_id  = var.enable_database ? "${local.name_prefix}-postgis" : ""

  services = module.ecs.service_names

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# AUTOSCALING
# ═══════════════════════════════════════════════════════════════════════════════

module "autoscaling" {
  source = "./modules/autoscaling"
  count  = var.enable_autoscaling ? 1 : 0

  name_prefix      = local.name_prefix
  ecs_cluster_name = module.ecs.cluster_name

  services = {
    for svc_name, svc_ecs_name in module.ecs.service_names : svc_name => {
      ecs_service_name = svc_ecs_name
      min_capacity     = lookup(lookup(var.autoscaling_config, svc_name, {}), "min_capacity", 1)
      max_capacity     = lookup(lookup(var.autoscaling_config, svc_name, {}), "max_capacity", 4)
      cpu_target       = lookup(lookup(var.autoscaling_config, svc_name, {}), "cpu_target", 70)
      memory_target    = lookup(lookup(var.autoscaling_config, svc_name, {}), "memory_target", 75)
    }
  }

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# BASTION HOST
# ═══════════════════════════════════════════════════════════════════════════════

module "bastion" {
  source = "./modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  name_prefix      = local.name_prefix
  vpc_id           = module.networking.vpc_id
  public_subnet_id = module.networking.public_subnet_ids[0]
  instance_type    = var.bastion_instance_type
  allowed_cidrs    = var.bastion_allowed_cidrs

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# WAF (Web Application Firewall)
# ═══════════════════════════════════════════════════════════════════════════════

module "waf" {
  source = "./modules/waf"
  count  = var.enable_waf ? 1 : 0

  name_prefix       = local.name_prefix
  alb_arn           = module.loadbalancer.alb_arn
  rate_limit        = var.waf_rate_limit
  blocked_countries = var.waf_blocked_countries

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# ELASTICACHE (Redis)
# ═══════════════════════════════════════════════════════════════════════════════

module "cache" {
  source = "./modules/cache"
  count  = var.enable_cache ? 1 : 0

  name_prefix           = local.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  ecs_security_group_id = module.loadbalancer.ecs_security_group_id
  node_type             = var.cache_node_type

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# EFS (Shared Persistent Storage)
# ═══════════════════════════════════════════════════════════════════════════════

module "storage" {
  source = "./modules/storage"
  count  = var.enable_efs ? 1 : 0

  name_prefix           = local.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  ecs_security_group_id = module.loadbalancer.ecs_security_group_id

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECRETS MANAGER
# ═══════════════════════════════════════════════════════════════════════════════

module "secrets" {
  source = "./modules/secrets"
  count  = var.enable_secrets ? 1 : 0

  name_prefix = local.name_prefix
  db_username = var.db_username
  db_password = var.db_password
  db_host     = var.enable_database ? module.database[0].address : ""
  db_port     = var.enable_database ? module.database[0].port : 5432
  db_name     = var.db_name

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECURITY (GuardDuty + VPC Flow Logs + ECS Exec)
# ═══════════════════════════════════════════════════════════════════════════════

module "security" {
  source = "./modules/security"
  count  = var.enable_security ? 1 : 0

  name_prefix        = local.name_prefix
  vpc_id             = module.networking.vpc_id
  log_retention_days = 90
  enable_guardduty   = var.enable_guardduty

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# SQS QUEUES (Async Processing)
# ═══════════════════════════════════════════════════════════════════════════════

module "queues" {
  source = "./modules/queues"
  count  = var.enable_queues ? 1 : 0

  name_prefix = local.name_prefix

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# AWS BACKUP (Disaster Recovery)
# ═══════════════════════════════════════════════════════════════════════════════

module "backup" {
  source = "./modules/backup"
  count  = var.enable_backup && var.enable_database ? 1 : 0

  name_prefix         = local.name_prefix
  rds_arn             = module.database[0].arn
  efs_arn             = var.enable_efs ? module.storage[0].file_system_arn : ""
  retention_days      = var.backup_retention_days
  enable_cross_region = var.enable_cross_region_backup
  dr_region           = var.dr_region

  tags = local.tags
}
