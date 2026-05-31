# GeoLang — Full Platform Deployment Profile
#
# Complete geospatial platform with all 8 services:
#   - PostGIS (RDS) — Enterprise geodatabase
#   - Ptolemy — Geodatabase API + geoprocessing
#   - TileTopia — 3D Tiles / terrain / asset server
#   - Geokode — Geocoding service
#   - Itinera — Routing + isochrones
#   - GeoLang — AI/NLP geospatial agent
#   - Letta — Agent memory server
#   - ViewTopia — Frontend viewer + A2UI
#
# Estimated cost: ~$150-250/month (Fargate + RDS + NAT + ALB + CloudFront)
#
# Usage:
#   terraform apply -var-file=profiles/platform.tfvars

environment = "prod"

# ── Service Toggles (all enabled) ────────────────────────────────
enable_ptolemy   = true
enable_tiletopia = true
enable_geokode   = true
enable_itinera   = true
enable_geolang   = true
enable_viewtopia = true

# ── Database ─────────────────────────────────────────────────────
enable_database      = true
db_instance_class    = "db.t4g.micro"
db_allocated_storage = 20
db_multi_az          = false  # Set true for production HA

# ── CDN ──────────────────────────────────────────────────────────
enable_cdn = true

# ── DNS ──────────────────────────────────────────────────────────
enable_dns  = true
domain_name = "geolang.com"

# ── S3 ───────────────────────────────────────────────────────────
enable_s3_tiles = true

# ── Sizing ───────────────────────────────────────────────────────
service_defaults = {
  cpu           = 256   # 0.25 vCPU
  memory        = 512   # 0.5 GB
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
  geolang = {
    cpu    = 1024
    memory = 2048
  }
  # Itinera builds and queries routing graphs
  itinera = {
    cpu    = 512
    memory = 1024
  }
  # Letta agent memory
  letta = {
    cpu    = 256
    memory = 512
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
  geolang = {
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
}

# ── Bastion Host ─────────────────────────────────────────────────
enable_bastion = true

# ── WAF (Web Application Firewall) ──────────────────────────────
enable_waf     = true
waf_rate_limit = 2000

# ── ElastiCache (Redis) ─────────────────────────────────────────
enable_cache   = true
cache_node_type = "cache.t4g.micro"

# ── EFS (Shared Storage) ────────────────────────────────────────
enable_efs = true

# ── Secrets Manager ─────────────────────────────────────────────
enable_secrets = true

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
