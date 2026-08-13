# GeoLang Platform - AWS Infrastructure
#
# Hosted deployment of the GeoLang geospatial suite.
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
# CloudFront and the ALB send all application traffic to the edge proxy.
# The proxy applies the compose path rewrites and reaches private tasks through
# Cloud Map. Ptolemy and Agora each use an isolated RDS PostgreSQL instance.

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # ── Determine which services to deploy ──────────────────────────
  enabled_services = compact([
    var.enable_ptolemy ? "ptolemy" : "",
    var.enable_tiletopia ? "tiletopia" : "",
    var.enable_geokode ? "geokode" : "",
    var.enable_itinera ? "itinera" : "",
    var.enable_interiora ? "interiora" : "",
    var.enable_geoplumb ? "geoplumb" : "",
    var.enable_fenestra ? "fenestra" : "",
    var.enable_agora ? "agora" : "",
    var.enable_sibyl ? "sibyl" : "",
    var.enable_geodukt ? "geodukt" : "",
    var.enable_geolang_executor ? "geolang-executor" : "",
    var.enable_geolang ? "geolang-api" : "",
    var.enable_jupyter ? "jupyter" : "",
    var.enable_viewtopia ? "viewtopia" : "",
    var.enable_platform_proxy ? "platform-proxy" : "",
  ])

  # ── Resolve container images ────────────────────────────────────
  # Use provided image or fall back to ECR repository URL.
  ecr_services = compact([
    var.enable_ptolemy ? "ptolemy" : "",
    var.enable_tiletopia ? "tiletopia" : "",
    var.enable_geokode ? "geokode" : "",
    var.enable_itinera ? "itinera" : "",
    var.enable_interiora ? "interiora" : "",
    var.enable_geoplumb ? "geoplumb" : "",
    var.enable_fenestra ? "fenestra" : "",
    var.enable_agora ? "agora" : "",
    var.enable_sibyl ? "sibyl" : "",
    var.enable_geodukt ? "geodukt" : "",
    var.enable_geolang || var.enable_geolang_executor ? "geolang-api" : "",
    var.enable_viewtopia ? "viewtopia" : "",
    var.enable_platform_proxy ? "platform-proxy" : "",
  ])

  ecr_service_images = {
    for service in local.ecr_services : service => "${module.ecr.repository_urls[service]}:latest"
  }
  geolang_executor_image = lookup(
    var.container_images,
    "geolang-executor",
    lookup(var.container_images, "geolang-api", try(local.ecr_service_images["geolang-api"], "")),
  )
  service_images = merge(
    local.ecr_service_images,
    {
      geolang-executor = local.geolang_executor_image
      jupyter          = var.jupyter_image
    },
    var.container_images,
  )

  # ── Resolve Fargate sizing per service ──────────────────────────
  service_sizing = {
    for svc in local.enabled_services : svc => {
      cpu           = coalesce(try(var.service_overrides[svc].cpu, null), var.service_defaults.cpu)
      memory        = coalesce(try(var.service_overrides[svc].memory, null), var.service_defaults.memory)
      desired_count = coalesce(try(var.service_overrides[svc].desired_count, null), var.service_defaults.desired_count)
    }
  }

  # ── Service discovery DNS suffix ────────────────────────────────
  sd_suffix = "${var.project_name}-${var.environment}.local"

  # ── Database URL (only when RDS is enabled) ─────────────────────
  platform_origin = (
    var.enable_dns && var.domain_name != ""
    ? "https://${var.domain_name}"
    : var.enable_cdn
    ? "https://${module.cdn[0].domain_name}"
    : "http://${module.loadbalancer.alb_dns_name}"
  )
  platform_host = (
    var.enable_dns && var.domain_name != ""
    ? var.domain_name
    : var.enable_cdn
    ? module.cdn[0].domain_name
    : module.loadbalancer.alb_dns_name
  )

  managed_runtime_secret_arns = var.enable_secrets ? module.secrets[0].secret_arns : {}
  runtime_secret_arns         = merge(local.managed_runtime_secret_arns, var.runtime_secret_arns)
  required_runtime_secrets = toset(compact([
    var.enable_ptolemy ? "platform_jwt" : "",
    var.enable_ptolemy ? "ptolemy_database_url" : "",
    var.enable_tiletopia ? "platform_jwt" : "",
    var.enable_interiora ? "platform_jwt" : "",
    var.enable_fenestra ? "platform_jwt" : "",
    var.enable_agora ? "platform_jwt" : "",
    var.enable_agora ? "agora_database_url" : "",
    var.enable_sibyl ? "llm_api_key" : "",
    var.enable_geodukt ? "platform_jwt" : "",
    var.enable_geolang_executor ? "geolang_executor" : "",
    var.enable_geolang ? "platform_jwt" : "",
    var.enable_geolang && var.enable_geolang_executor ? "geolang_executor" : "",
    var.enable_jupyter ? "jupyter_token" : "",
  ]))

  persistent_access_points = merge(
    var.enable_tiletopia ? { tiletopia = { path = "/tiletopia", uid = 1000, gid = 1000 } } : {},
    var.enable_geokode || var.enable_itinera ? { spatial-data = { path = "/spatial-data", uid = 1000, gid = 1000 } } : {},
    var.enable_interiora ? { interiora = { path = "/interiora", uid = 1000, gid = 1000 } } : {},
    var.enable_geoplumb ? { geoplumb-cache = { path = "/geoplumb-cache", uid = 1000, gid = 1000 } } : {},
    var.enable_sibyl ? { sibyl = { path = "/sibyl", uid = 1000, gid = 1000 } } : {},
    var.enable_geolang || var.enable_geolang_executor || var.enable_geodukt ? {
      geolang-outputs   = { path = "/geolang/outputs", uid = 1000, gid = 1000 }
      geolang-user-data = { path = "/geolang/user-data", uid = 1000, gid = 1000 }
      geolang-live-data = { path = "/geolang/live-data", uid = 1000, gid = 1000 }
    } : {},
    var.enable_geolang ? { geolang-cache = { path = "/geolang/cache", uid = 1000, gid = 1000 } } : {},
    var.enable_fenestra ? { fenestra-coverages = { path = "/fenestra-coverages", uid = 1000, gid = 1000 } } : {},
    var.enable_jupyter ? { jupyter-work = { path = "/jupyter-work", uid = 1000, gid = 100 } } : {},
  )

  efs_volumes = var.enable_efs ? {
    for name, access_point_id in module.storage[0].access_points : name => {
      file_system_id  = module.storage[0].file_system_id
      access_point_id = access_point_id
    }
  } : {}
}

# services start with desired_count > 0 as soon as runtime_secrets_ready flips, so a
# missing ARN has to stop the apply rather than warn
resource "terraform_data" "runtime_secrets" {
  lifecycle {
    precondition {
      condition = !var.runtime_secrets_ready || alltrue([
        for name in local.required_runtime_secrets : lookup(local.runtime_secret_arns, name, "") != ""
      ])
      error_message = "runtime_secrets_ready requires an ARN for every enabled service secret."
    }
  }
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
  vpc_cidr          = module.networking.vpc_cidr_block
  public_subnet_ids = module.networking.public_subnet_ids
  # the ALB needs a certificate from its own region, not the us-east-1 one
  # CloudFront requires
  certificate_arn = var.enable_dns && var.domain_name != "" ? module.dns[0].alb_certificate_arn : ""
  tags            = local.tags
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
  multi_az          = var.db_multi_az

  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : ""

  tags = local.tags
}

module "agora_database" {
  source = "./modules/database"
  count  = var.enable_database && var.enable_agora ? 1 : 0

  name_prefix           = "${local.name_prefix}-agora"
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  ecs_security_group_id = module.loadbalancer.ecs_security_group_id

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  db_name           = "agora"
  db_username       = "agora"
  multi_az          = var.db_multi_az

  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : ""

  tags = merge(local.tags, { Service = "agora" })
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONTAINER REGISTRY (ECR)
# ═══════════════════════════════════════════════════════════════════════════════

module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  services    = local.ecr_services
  tags        = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# ECS FARGATE (Compute)
# ═══════════════════════════════════════════════════════════════════════════════

module "ecs" {
  source = "./modules/ecs"

  name_prefix                      = local.name_prefix
  aws_region                       = var.aws_region
  vpc_id                           = module.networking.vpc_id
  private_subnet_ids               = module.networking.private_subnet_ids
  ecs_security_group_id            = module.loadbalancer.ecs_security_group_id
  untrusted_code_security_group_id = module.loadbalancer.untrusted_code_security_group_id
  enable_container_insights        = var.enable_container_insights
  log_retention_days               = var.log_retention_days

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
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["ptolemy"].desired_count : 0
        container_port = 3000
        health_path    = "/api/v1/readyz"
        command        = ["serve", "--bind", "0.0.0.0:3000"]
        environment = [
          { name = "RUST_LOG", value = "info,ptolemy_api=debug" },
          { name = "PTOLEMY_PORT", value = "3000" },
        ]
        secrets = concat(
          lookup(local.runtime_secret_arns, "ptolemy_database_url", "") != "" ? [{ name = "DATABASE_URL", valueFrom = local.runtime_secret_arns["ptolemy_database_url"] }] : [],
          lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [{ name = "PTOLEMY_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] }] : [],
        )
      }
    } : {},

    # ── TileTopia (3D Tiles / Terrain) ────────────────────────────
    var.enable_tiletopia ? {
      tiletopia = {
        image          = local.service_images["tiletopia"]
        cpu            = local.service_sizing["tiletopia"].cpu
        memory         = local.service_sizing["tiletopia"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["tiletopia"].desired_count : 0
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
        secrets = lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [
          { name = "TILETOPIA_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] },
        ] : []
        efs_volumes = var.enable_efs ? { tiletopia = local.efs_volumes["tiletopia"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "tiletopia", container_path = "/data" },
        ] : []
      }
    } : {},

    # ── Geokode (Geocoding) ───────────────────────────────────────
    var.enable_geokode ? {
      geokode = {
        image          = local.service_images["geokode"]
        cpu            = local.service_sizing["geokode"].cpu
        memory         = local.service_sizing["geokode"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["geokode"].desired_count : 0
        container_port = 3000
        health_path    = "/health"
        command        = ["serve", "--data", "/data/region.osm.pbf", "--bind", "0.0.0.0:3000"]
        environment = [
          { name = "RUST_LOG", value = "info,geokode=debug" },
        ]
        efs_volumes = var.enable_efs ? { spatial-data = local.efs_volumes["spatial-data"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "spatial-data", container_path = "/data", read_only = true },
        ] : []
      }
    } : {},

    # ── Itinera (Routing) ─────────────────────────────────────────
    var.enable_itinera ? {
      itinera = {
        image          = local.service_images["itinera"]
        cpu            = local.service_sizing["itinera"].cpu
        memory         = local.service_sizing["itinera"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["itinera"].desired_count : 0
        container_port = 3000
        health_path    = "/health"
        command        = ["serve", "--bind", "0.0.0.0:3000", "--graph", "/data/graph.bin"]
        environment = [
          { name = "RUST_LOG", value = "info,itinera=debug" },
        ]
        efs_volumes = var.enable_efs ? { spatial-data = local.efs_volumes["spatial-data"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "spatial-data", container_path = "/data" },
        ] : []
      }
    } : {},

    # ── Interiora (Indoor maps + indoor routing) ──────────────────
    var.enable_interiora ? {
      interiora = {
        image          = local.service_images["interiora"]
        cpu            = local.service_sizing["interiora"].cpu
        memory         = local.service_sizing["interiora"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["interiora"].desired_count : 0
        container_port = 3000
        health_path    = "/health"
        command        = []
        environment = [
          { name = "PORT", value = "3000" },
          { name = "INTERIORA_DATA_DIR", value = "/data" },
          { name = "RUST_LOG", value = "info,interiora=debug" },
        ]
        secrets = lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [
          { name = "PLATFORM_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] },
        ] : []
        efs_volumes = var.enable_efs ? { interiora = local.efs_volumes["interiora"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "interiora", container_path = "/data" },
        ] : []
      }
    } : {},

    # ── Geoplumb (Windowed raster tiles over STAC) ────────────────
    var.enable_geoplumb ? {
      geoplumb = {
        image          = local.service_images["geoplumb"]
        cpu            = local.service_sizing["geoplumb"].cpu
        memory         = local.service_sizing["geoplumb"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["geoplumb"].desired_count : 0
        container_port = 3000
        health_path    = "/health"
        command        = []
        environment = [
          { name = "PORT", value = "3000" },
          { name = "RUST_LOG", value = "info,geoplumb=debug" },
          { name = "GEOPLUMB_LAYERS", value = "/etc/geoplumb/layers.toml" },
          # 128 MiB is per layer, so the two layers in layers.toml hold 256 MiB of the task memory
          { name = "GEOPLUMB_CACHE_BYTES", value = "134217728" },
          { name = "GEOPLUMB_DISK_CACHE", value = "/cache" },
        ]
        efs_volumes = var.enable_efs ? { geoplumb-cache = local.efs_volumes["geoplumb-cache"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "geoplumb-cache", container_path = "/cache" },
        ] : []
      }
    } : {},

    # ── Fenestra (OGC services gateway) ───────────────────────────
    var.enable_fenestra ? {
      fenestra = {
        image          = local.service_images["fenestra"]
        cpu            = local.service_sizing["fenestra"].cpu
        memory         = local.service_sizing["fenestra"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["fenestra"].desired_count : 0
        container_port = 8080
        health_path    = "/readyz"
        environment = [
          { name = "RUST_LOG", value = "info,fenestra=debug" },
          { name = "FENESTRA_HOST", value = "0.0.0.0" },
          { name = "FENESTRA_PORT", value = "8080" },
          { name = "PTOLEMY_URL", value = "http://ptolemy.${local.sd_suffix}:3000" },
          { name = "FENESTRA_PUBLIC_URL", value = "${local.platform_origin}/ogc" },
          { name = "COVERAGE_DIR", value = "/coverages" },
        ]
        secrets = lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [
          { name = "FENESTRA_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] },
        ] : []
        efs_volumes = var.enable_efs ? { fenestra-coverages = local.efs_volumes["fenestra-coverages"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "fenestra-coverages", container_path = "/coverages", read_only = true },
        ] : []
      }
    } : {},

    var.enable_agora ? {
      agora = {
        image          = local.service_images["agora"]
        cpu            = local.service_sizing["agora"].cpu
        memory         = local.service_sizing["agora"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["agora"].desired_count : 0
        container_port = 3000
        health_path    = "/health"
        environment = [
          { name = "PORT", value = "3000" },
          { name = "RUST_LOG", value = "info" },
        ]
        secrets = concat(
          lookup(local.runtime_secret_arns, "agora_database_url", "") != "" ? [{ name = "DATABASE_URL", valueFrom = local.runtime_secret_arns["agora_database_url"] }] : [],
          lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [{ name = "PLATFORM_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] }] : [],
        )
      }
    } : {},

    var.enable_sibyl ? {
      sibyl = {
        image          = local.service_images["sibyl"]
        cpu            = local.service_sizing["sibyl"].cpu
        memory         = local.service_sizing["sibyl"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["sibyl"].desired_count : 0
        container_port = 8090
        health_path    = "/health"
        environment = [
          { name = "SIBYL_HOST", value = "0.0.0.0" },
          { name = "SIBYL_PORT", value = "8090" },
          { name = "SIBYL_DB_PATH", value = "/data/sibyl.db" },
          { name = "GEOLANG_URL", value = "http://geolang-api.${local.sd_suffix}:8080" },
          { name = "RUST_LOG", value = "info" },
        ]
        secrets = lookup(local.runtime_secret_arns, "llm_api_key", "") != "" ? [
          { name = "XAI_API_KEY", valueFrom = local.runtime_secret_arns["llm_api_key"] },
        ] : []
        efs_volumes = var.enable_efs ? { sibyl = local.efs_volumes["sibyl"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "sibyl", container_path = "/data" },
        ] : []
      }
    } : {},

    var.enable_geodukt ? {
      geodukt = {
        image             = local.service_images["geodukt"]
        cpu               = local.service_sizing["geodukt"].cpu
        memory            = local.service_sizing["geodukt"].memory
        desired_count     = var.runtime_secrets_ready ? local.service_sizing["geodukt"].desired_count : 0
        container_port    = 8100
        health_path       = "/health"
        command           = ["serve", "--bind", "0.0.0.0:8100"]
        working_directory = "/app/geolang"
        user              = "1000:1000"
        environment = [
          { name = "RUST_LOG", value = "info,geodukt=debug" },
        ]
        secrets = lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [
          { name = "PLATFORM_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] },
        ] : []
        efs_volumes = var.enable_efs ? {
          geolang-outputs   = local.efs_volumes["geolang-outputs"]
          geolang-user-data = local.efs_volumes["geolang-user-data"]
          geolang-live-data = local.efs_volumes["geolang-live-data"]
        } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "geolang-outputs", container_path = "/app/geolang/outputs" },
          { source_volume = "geolang-user-data", container_path = "/app/geolang/user_data" },
          { source_volume = "geolang-live-data", container_path = "/app/geolang/live_data" },
        ] : []
      }
    } : {},

    var.enable_geolang_executor ? {
      geolang-executor = {
        image                = local.service_images["geolang-executor"]
        cpu                  = local.service_sizing["geolang-executor"].cpu
        memory               = local.service_sizing["geolang-executor"].memory
        desired_count        = var.runtime_secrets_ready ? local.service_sizing["geolang-executor"].desired_count : 0
        container_port       = 8081
        health_path          = "/health"
        command              = ["uvicorn", "src.api.executor:app", "--host", "0.0.0.0", "--port", "8081"]
        user                 = "1000:1000"
        dropped_capabilities = ["ALL"]
        runs_untrusted_code  = true
        environment = [
          { name = "TOOL_EXEC_DIR", value = "/app/geolang" },
          { name = "PTOLEMY_URL", value = "http://ptolemy.${local.sd_suffix}:3000" },
          { name = "TILETOPIA_URL", value = "http://tiletopia.${local.sd_suffix}:3000" },
          { name = "GEOKODE_URL", value = "http://geokode.${local.sd_suffix}:3000" },
          { name = "ITINERA_URL", value = "http://itinera.${local.sd_suffix}:3000" },
          { name = "GEODUKT_URL", value = "http://geodukt.${local.sd_suffix}:8100" },
          { name = "QT_QPA_PLATFORM", value = "offscreen" },
          { name = "QGIS_PREFIX_PATH", value = "/usr" },
          { name = "HOME", value = "/tmp" },
        ]
        secrets = lookup(local.runtime_secret_arns, "geolang_executor", "") != "" ? [
          { name = "GEOLANG_EXECUTOR_SECRET", valueFrom = local.runtime_secret_arns["geolang_executor"] },
        ] : []
        efs_volumes = var.enable_efs ? {
          geolang-outputs   = local.efs_volumes["geolang-outputs"]
          geolang-user-data = local.efs_volumes["geolang-user-data"]
          geolang-live-data = local.efs_volumes["geolang-live-data"]
        } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "geolang-outputs", container_path = "/app/geolang/outputs" },
          { source_volume = "geolang-user-data", container_path = "/app/geolang/user_data" },
          { source_volume = "geolang-live-data", container_path = "/app/geolang/live_data" },
        ] : []
      }
    } : {},

    var.enable_geolang ? {
      geolang-api = {
        image          = local.service_images["geolang-api"]
        cpu            = local.service_sizing["geolang-api"].cpu
        memory         = local.service_sizing["geolang-api"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["geolang-api"].desired_count : 0
        container_port = 8080
        health_path    = "/health"
        environment = concat(
          [
            { name = "CORS_ORIGINS", value = local.platform_origin },
            { name = "MCP_ALLOWED_HOSTS", value = local.platform_host },
            { name = "GEOLANG_PUBLIC_URL", value = "${local.platform_origin}/agent" },
            { name = "TOOL_EXEC_DIR", value = "/app/geolang" },
          ],
          var.enable_sibyl ? [{ name = "SIBYL_URL", value = "http://sibyl.${local.sd_suffix}:8090" }] : [],
          var.enable_agora ? [{ name = "AGORA_URL", value = "http://agora.${local.sd_suffix}:3000" }] : [],
          var.enable_ptolemy ? [{ name = "PTOLEMY_URL", value = "http://ptolemy.${local.sd_suffix}:3000" }] : [],
          var.enable_tiletopia ? [{ name = "TILETOPIA_URL", value = "http://tiletopia.${local.sd_suffix}:3000" }] : [],
          var.enable_geokode ? [{ name = "GEOKODE_URL", value = "http://geokode.${local.sd_suffix}:3000" }] : [],
          var.enable_itinera ? [{ name = "ITINERA_URL", value = "http://itinera.${local.sd_suffix}:3000" }] : [],
          var.enable_geodukt ? [{ name = "GEODUKT_URL", value = "http://geodukt.${local.sd_suffix}:8100" }] : [],
          var.enable_geolang_executor ? [{ name = "GEOLANG_EXECUTOR_URL", value = "http://geolang-executor.${local.sd_suffix}:8081" }] : [],
        )
        secrets = concat(
          lookup(local.runtime_secret_arns, "platform_jwt", "") != "" ? [{ name = "PLATFORM_JWT_SECRET", valueFrom = local.runtime_secret_arns["platform_jwt"] }] : [],
          lookup(local.runtime_secret_arns, "geolang_executor", "") != "" ? [{ name = "GEOLANG_EXECUTOR_SECRET", valueFrom = local.runtime_secret_arns["geolang_executor"] }] : [],
        )
        efs_volumes = var.enable_efs ? {
          geolang-cache     = local.efs_volumes["geolang-cache"]
          geolang-outputs   = local.efs_volumes["geolang-outputs"]
          geolang-user-data = local.efs_volumes["geolang-user-data"]
          geolang-live-data = local.efs_volumes["geolang-live-data"]
        } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "geolang-cache", container_path = "/app/cache" },
          { source_volume = "geolang-outputs", container_path = "/app/geolang/outputs" },
          { source_volume = "geolang-user-data", container_path = "/app/geolang/user_data" },
          { source_volume = "geolang-live-data", container_path = "/app/geolang/live_data" },
        ] : []
      }
    } : {},

    var.enable_jupyter ? {
      jupyter = {
        image               = local.service_images["jupyter"]
        cpu                 = local.service_sizing["jupyter"].cpu
        memory              = local.service_sizing["jupyter"].memory
        desired_count       = var.runtime_secrets_ready ? local.service_sizing["jupyter"].desired_count : 0
        container_port      = 8888
        health_path         = "/jupyter/api"
        health_command      = ["CMD-SHELL", "wget -q -O /dev/null http://localhost:8888/jupyter/api || exit 1"]
        runs_untrusted_code = true
        command = [
          "start-notebook.py",
          "--ServerApp.base_url=/jupyter",
          "--ServerApp.allow_remote_access=True",
          "--ServerApp.trust_xheaders=True",
        ]
        environment = []
        secrets = lookup(local.runtime_secret_arns, "jupyter_token", "") != "" ? [
          { name = "JUPYTER_TOKEN", valueFrom = local.runtime_secret_arns["jupyter_token"] },
        ] : []
        efs_volumes = var.enable_efs ? { jupyter-work = local.efs_volumes["jupyter-work"] } : {}
        mount_points = var.enable_efs ? [
          { source_volume = "jupyter-work", container_path = "/home/jovyan/work" },
        ] : []
      }
    } : {},

    # ── ViewTopia (Frontend) ──────────────────────────────────────
    var.enable_viewtopia ? {
      viewtopia = {
        image          = local.service_images["viewtopia"]
        cpu            = local.service_sizing["viewtopia"].cpu
        memory         = local.service_sizing["viewtopia"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["viewtopia"].desired_count : 0
        container_port = 5174
        health_path    = "/"
        health_command = ["CMD-SHELL", "wget -q -O /dev/null http://localhost:5174/ || exit 1"]
        environment = [
          { name = "NGINX_PORT", value = "5174" },
        ]
      }
    } : {},

    var.enable_platform_proxy ? {
      platform-proxy = {
        image          = local.service_images["platform-proxy"]
        cpu            = local.service_sizing["platform-proxy"].cpu
        memory         = local.service_sizing["platform-proxy"].memory
        desired_count  = var.runtime_secrets_ready ? local.service_sizing["platform-proxy"].desired_count : 0
        container_port = 8080
        health_path    = "/health"
        health_command = ["CMD-SHELL", "wget -q -O /dev/null http://localhost:8080/health || exit 1"]
        public         = true
        environment = [
          { name = "SERVICE_DISCOVERY_NAMESPACE", value = local.sd_suffix },
        ]
      }
    } : {},
  )

  depends_on = [module.ecr, module.database, module.agora_database, module.storage, module.secrets]
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

  name_prefix  = local.name_prefix
  alb_dns_name = module.loadbalancer.alb_dns_name
  domain_name  = var.domain_name

  # built from the domain rather than read back from the dns module, so the two
  # modules do not have to depend on each other in both directions
  origin_domain_name = var.enable_dns && var.domain_name != "" ? "origin.${var.domain_name}" : ""

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
    aws          = aws.us_east_1
    aws.regional = aws
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
  rds_instance_ids = toset(concat(
    var.enable_database ? [module.database[0].identifier] : [],
    var.enable_database && var.enable_agora ? [module.agora_database[0].identifier] : [],
  ))

  services = module.ecs.service_names

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# AUTOSCALING
# ═══════════════════════════════════════════════════════════════════════════════

module "autoscaling" {
  source = "./modules/autoscaling"
  count  = var.enable_autoscaling && var.runtime_secrets_ready ? 1 : 0

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
    if contains(keys(var.autoscaling_config), svc_name)
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

  name_prefix        = local.name_prefix
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  ecs_security_group_ids = [
    module.loadbalancer.ecs_security_group_id,
    module.loadbalancer.untrusted_code_security_group_id,
  ]
  access_points = local.persistent_access_points

  tags = local.tags
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECRETS MANAGER
# ═══════════════════════════════════════════════════════════════════════════════

module "secrets" {
  source = "./modules/secrets"
  count  = var.enable_secrets ? 1 : 0

  name_prefix  = local.name_prefix
  secret_names = local.required_runtime_secrets

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

  name_prefix = local.name_prefix
  rds_arns = concat(
    [module.database[0].arn],
    var.enable_agora ? [module.agora_database[0].arn] : [],
  )
  efs_arn             = var.enable_efs ? module.storage[0].file_system_arn : ""
  retention_days      = var.backup_retention_days
  enable_cross_region = var.enable_cross_region_backup
  dr_region           = var.dr_region

  tags = local.tags
}
