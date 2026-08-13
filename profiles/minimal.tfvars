# GeoLang - Minimal Deployment Profile
#
# Lightweight development/demo stack with 4 ECS tasks:
#   - TileTopia (3D Tiles / terrain)
#   - GeoLang (AI agent)
#   - ViewTopia (web frontend)
#   - Platform proxy (public routing edge)
#
# No database, geocoding, or routing services.
# Estimated cost: ~$50-80/month (Fargate + NAT + ALB)
#
# Usage:
#   terraform apply -var-file=profiles/minimal.tfvars

environment = "dev"

# ── Service Toggles ──────────────────────────────────────────────
enable_ptolemy          = false
enable_tiletopia        = true
enable_geokode          = false
enable_itinera          = false
enable_interiora        = false
enable_geoplumb         = false
enable_fenestra         = false
enable_agora            = false
enable_sibyl            = false
enable_geodukt          = false
enable_geolang_executor = false
enable_geolang          = true
enable_jupyter          = false
enable_viewtopia        = true
enable_platform_proxy   = true

# ── Database ─────────────────────────────────────────────────────
enable_database = false

# ── CDN ──────────────────────────────────────────────────────────
enable_cdn = false

# ── DNS ──────────────────────────────────────────────────────────
enable_dns = false

# ── S3 ───────────────────────────────────────────────────────────
enable_s3_tiles = true

# Create empty secret containers. Populate them before enabling gated tasks.
enable_secrets = true

# ── Sizing (smallest Fargate) ────────────────────────────────────
service_defaults = {
  cpu           = 256 # 0.25 vCPU
  memory        = 512 # 0.5 GB
  desired_count = 1
}

# GeoLang (Python + QGIS) needs more memory
service_overrides = {
  geolang-api = {
    cpu    = 512
    memory = 1024
  }
}
