# GeoLang - Full Platform Deployment Profile
#
# Complete geospatial platform with all services:
#   - PostGIS (RDS), enterprise geodatabase
#   - Ptolemy, geodatabase API + geoprocessing
#   - TileTopia, 3D Tiles / terrain / asset server
#   - Geokode, geocoding service
#   - Itinera, routing + isochrones
#   - Fenestra, Agora, and Geoplumb
#   - Sibyl, Geodukt, and isolated GeoLang API and executor tasks
#   - Jupyter notebook kernels
#   - ViewTopia and the platform edge proxy
#
# This profile creates two RDS instances, one for Ptolemy and one for Agora.
# The Agora instance duplicates the selected RDS compute and storage cost.
#
# Usage:
#   terraform apply -var-file=profiles/platform.tfvars

environment = "prod"

# ── Service Toggles (all enabled) ────────────────────────────────
enable_ptolemy          = true
enable_tiletopia        = true
enable_geokode          = true
enable_itinera          = true
enable_interiora        = true
enable_geoplumb         = true
enable_fenestra         = true
enable_agora            = true
enable_sibyl            = true
enable_geodukt          = true
enable_geolang_executor = true
enable_geolang          = true
enable_jupyter          = true
enable_viewtopia        = true
enable_platform_proxy   = true

# ── Database ─────────────────────────────────────────────────────
enable_database      = true
db_instance_class    = "db.t4g.micro"
db_allocated_storage = 20
db_multi_az          = false # Set true for production HA

# ── CDN ──────────────────────────────────────────────────────────
enable_cdn = true

# ── DNS ──────────────────────────────────────────────────────────
enable_dns  = true
domain_name = "geolang.com"

# ── S3 ───────────────────────────────────────────────────────────
enable_s3_tiles = true

# ── Sizing ───────────────────────────────────────────────────────
service_defaults = {
  cpu           = 256 # 0.25 vCPU
  memory        = 512 # 0.5 GB
  desired_count = 1
}

service_overrides = {
  # Ptolemy handles DB queries + geoprocessing
  ptolemy = {
    cpu    = 512
    memory = 1024
  }
  # TileTopia processes point clouds + 3D models
  tiletopia = {
    cpu    = 512
    memory = 1024
  }
  # GeoLang runs Python + QGIS + AI inference
  geolang-api = {
    cpu    = 1024
    memory = 2048
  }
  geolang-executor = {
    cpu    = 2048
    memory = 4096
  }
  geoplumb = {
    cpu    = 1024
    memory = 2048
  }
  jupyter = {
    cpu    = 1024
    memory = 2048
  }
  # Itinera builds and queries routing graphs
  itinera = {
    cpu    = 512
    memory = 1024
  }
}

# ── Autoscaling ──────────────────────────────────────────────────
enable_autoscaling = true

autoscaling_config = {
  ptolemy = {
    min_capacity  = 1
    max_capacity  = 3
    cpu_target    = 70
    memory_target = 75
  }
  tiletopia = {
    min_capacity  = 1
    max_capacity  = 4
    cpu_target    = 65
    memory_target = 70
  }
  geolang-api = {
    min_capacity  = 1
    max_capacity  = 3
    cpu_target    = 70
    memory_target = 75
  }
  viewtopia = {
    min_capacity  = 1
    max_capacity  = 4
    cpu_target    = 75
    memory_target = 80
  }
  platform-proxy = {
    min_capacity  = 1
    max_capacity  = 4
    cpu_target    = 70
    memory_target = 75
  }
}

# ── Bastion Host ─────────────────────────────────────────────────
enable_bastion = true

# ── WAF (Web Application Firewall) ──────────────────────────────
enable_waf     = true
waf_rate_limit = 2000

# ── ElastiCache (Redis) ─────────────────────────────────────────
enable_cache    = true
cache_node_type = "cache.t4g.micro"

# ── EFS (Shared Storage) ────────────────────────────────────────
enable_efs = true

# ── Secrets Manager ─────────────────────────────────────────────
enable_secrets = true

# Populate secrets, push images, and stage EFS data before changing this to true.
runtime_secrets_ready = false

# ── Security (GuardDuty + VPC Flow Logs) ─────────────────────────
enable_security  = true
enable_guardduty = true

# ── SQS Queues ──────────────────────────────────────────────────
enable_queues = true

# ── Backup & DR ─────────────────────────────────────────────────
enable_backup              = true
backup_retention_days      = 30
enable_cross_region_backup = false
# dr_region                = "us-west-2"
