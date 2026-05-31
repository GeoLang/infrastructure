# GeoLang — Minimal Deployment Profile
#
# Lightweight development/demo stack with 4 services:
#   - TileTopia (3D Tiles / terrain)
#   - GeoLang (AI agent)
#   - Letta (agent memory)
#   - ViewTopia (web frontend)
#
# No database, geocoding, or routing services.
# Estimated cost: ~$50-80/month (Fargate + NAT + ALB)
#
# Usage:
#   terraform apply -var-file=profiles/minimal.tfvars

environment = "dev"

# ── Service Toggles ──────────────────────────────────────────────
enable_ptolemy   = false
enable_tiletopia = true
enable_geokode   = false
enable_itinera   = false
enable_geolang   = true
enable_viewtopia = true

# ── Database ─────────────────────────────────────────────────────
enable_database = false

# ── CDN ──────────────────────────────────────────────────────────
enable_cdn = false

# ── DNS ──────────────────────────────────────────────────────────
enable_dns = false

# ── S3 ───────────────────────────────────────────────────────────
enable_s3_tiles = true

# ── Sizing (smallest Fargate) ────────────────────────────────────
service_defaults = {
  cpu           = 256   # 0.25 vCPU
  memory        = 512   # 0.5 GB
  desired_count = 1
}

# GeoLang (Python + QGIS) needs more memory
service_overrides = {
  geolang = {
    cpu    = 512
    memory = 1024
  }
  letta = {
    cpu    = 256
    memory = 512
  }
}
