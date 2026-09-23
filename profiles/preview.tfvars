# GeoLang - Hosted Preview Profile
#
# The flagship viewer and the services behind it, sized for demonstration
# rather than load: Fargate Spot tasks with public IPs, one Aurora Serverless
# v2 cluster that pauses when nothing is connected, and no NAT gateway.
#
# Usage:
#   terraform apply -var-file=profiles/preview.tfvars

aws_region  = "us-east-1"
environment = "prod"

# ── Service Toggles ──────────────────────────────────────────────
enable_ptolemy          = true
enable_tiletopia        = true
enable_agora            = true
enable_sibyl            = true
enable_geodukt          = true
enable_geolang_executor = true
enable_geolang          = true
enable_viewtopia        = true
enable_platform_proxy   = true

enable_geokode   = false
enable_itinera   = false
enable_interiora = false
enable_geoplumb  = false
enable_fenestra  = false
enable_jupyter   = false

# ── Database ─────────────────────────────────────────────────────
enable_database = true
db_max_capacity = 2

# ── CDN ──────────────────────────────────────────────────────────
enable_cdn = true
# no domain yet, so CloudFront reaches the load balancer in cleartext
allow_cleartext_origin = true

# ── DNS ──────────────────────────────────────────────────────────
enable_dns = false

# ── Storage and secrets ──────────────────────────────────────────
enable_efs      = true
enable_secrets  = true
enable_s3_tiles = false

# ── Off for a preview ────────────────────────────────────────────
enable_bastion     = false
enable_waf         = false
enable_security    = false
enable_backup      = false
enable_autoscaling = false

# ── Monitoring ───────────────────────────────────────────────────
enable_container_insights = false
log_retention_days        = 14

# ── Compute ──────────────────────────────────────────────────────
use_fargate_spot = true

nightly_scale_down = {
  timezone = "America/Toronto"
  hour     = 23
}

# Populate secrets and push the two ECR images before changing this to true.
runtime_secrets_ready = true

# ── Images ───────────────────────────────────────────────────────
# Everything already published to ghcr comes from there. Only viewtopia and the
# platform proxy are built into ECR, so only those two get a repository.
image_tag = "v0.1.5"

container_images = {
  ptolemy     = "ghcr.io/geolang/ptolemy:v0.2.1"
  tiletopia   = "ghcr.io/geolang/tiletopia:v0.4.0"
  agora       = "ghcr.io/geolang/agora:v0.1.0"
  sibyl       = "ghcr.io/geolang/sibyl:v0.1.0"
  geodukt     = "ghcr.io/geolang/geodukt:v0.2.0"
  geolang-api = "ghcr.io/geolang/geolang:v0.1.4"
}

# ── Sibyl model access ───────────────────────────────────────────
llm_api_base = "https://bedrock-mantle.us-east-1.api.aws/v1"
llm_models   = "openai.gpt-oss-120b,qwen.qwen3-235b-a22b-2507"

# ── Chat spend caps ──────────────────────────────────────────────
# signup is open, so the global cap is the real ceiling
geolang_chat_runs_per_day            = 300
geolang_chat_runs_per_caller_per_day = 40

# ── Sizing ───────────────────────────────────────────────────────
service_defaults = {
  cpu           = 256
  memory        = 512
  desired_count = 1
}

service_overrides = {
  ptolemy = {
    cpu    = 512
    memory = 1024
  }
  tiletopia = {
    cpu    = 512
    memory = 1024
  }
  geolang-api = {
    cpu    = 1024
    memory = 2048
  }
  geolang-executor = {
    cpu    = 2048
    memory = 8192
  }
}
