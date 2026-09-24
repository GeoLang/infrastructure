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

enable_geokode   = true
enable_itinera   = false
enable_interiora = false
enable_geoplumb  = false
enable_fenestra  = false
enable_jupyter   = false

geokode_index_version = "planet-260914-v2"

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
enable_s3_tiles = true

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

enable_demo_landing_page = true

# Populate secrets and push the two ECR images before changing this to true.
runtime_secrets_ready = true

# ── Images ───────────────────────────────────────────────────────
# Everything already published to ghcr comes from there. Only viewtopia and the
# platform proxy are built into ECR, so only those two get a repository.
image_tag = "v0.1.7"

container_images = {
  ptolemy     = "ghcr.io/geolang/ptolemy:v0.2.3"
  tiletopia   = "ghcr.io/geolang/tiletopia:v0.4.2"
  agora       = "ghcr.io/geolang/agora:v0.1.0"
  sibyl       = "ghcr.io/geolang/sibyl:v0.1.2"
  geodukt     = "ghcr.io/geolang/geodukt:v0.2.0"
  geolang-api = "ghcr.io/geolang/geolang:v0.1.9"
  geokode     = "ghcr.io/geolang/geokode:v0.4.0"
}

# ── Sibyl model access ───────────────────────────────────────────
llm_api_base = "https://bedrock-mantle.us-east-1.api.aws/v1"
llm_models   = "openai.gpt-oss-120b,qwen.qwen3-235b-a22b-2507"

# ── Spend caps ───────────────────────────────────────────────────
# USD per million tokens from the us-east-1 price list, 2026-09-23
llm_monthly_spend_limit_usd = 50
llm_model_prices            = "openai.gpt-oss-120b=0.15/0.60,qwen.qwen3-235b-a22b-2507=0.22/0.88"
monthly_spend_budget_usd    = 100
bedrock_api_key_user        = "geolang-sibyl-bedrock"

# ── Rate limits at CloudFront ────────────────────────────────────
cloudfront_rate_limits = {
  requests_per_ip      = 3000
  auth_requests_per_ip = 20
}

# ── Per-user limits ──────────────────────────────────────────────
# signup is open and one person can hold several accounts, so the monthly spend cap is the real ceiling
llm_locked_profile = "cloud:openai.gpt-oss-120b"
sibyl_limits = {
  SIBYL_RUNS_PER_USER_PER_DAY    = 40
  SIBYL_TOKENS_PER_USER_PER_DAY  = 2000000
  SIBYL_RUNS_PER_ADMIN_PER_DAY   = 500
  SIBYL_TOKENS_PER_ADMIN_PER_DAY = 50000000
}

# ── geolang-api caps ─────────────────────────────────────────────
# a chat user inside sibyl's limits makes at most 40 runs of 30 tool calls,
# the global PER_DAY caps sit at per-caller times TILETOPIA_MAX_USERS
geolang_limits = {
  GEOLANG_UPLOAD_MAX_REQUEST_MEGABYTES        = 51
  GEOLANG_UPLOAD_MAX_FILE_MEGABYTES           = 50
  GEOLANG_UPLOAD_MAX_ZIP_ENTRIES              = 100
  GEOLANG_UPLOAD_MAX_UNZIPPED_MEGABYTES       = 200
  GEOLANG_UPLOAD_FILES_PER_DAY                = 10000
  GEOLANG_UPLOAD_FILES_PER_CALLER_PER_DAY     = 20
  GEOLANG_UPLOAD_MEGABYTES_PER_DAY            = 100000
  GEOLANG_UPLOAD_MEGABYTES_PER_CALLER_PER_DAY = 200
  GEOLANG_TOOL_RUNS_PER_CALLER_PER_DAY        = 1200
  GEOLANG_TOOL_RUNS_PER_DAY                   = 600000
  GEOLANG_TOOL_RUNS_AT_ONCE_PER_CALLER        = 1
  GEOLANG_OUTPUT_MEGABYTES_PER_CALLER_PER_DAY = 500
  GEOLANG_USER_DATA_RETENTION_DAYS            = 30
}

# ── ptolemy quotas and tiletopia signup limits ──────────────────
ptolemy_limits = {
  PTOLEMY_MAX_ATTACHMENT_MEGABYTES_PER_USER = 200
  PTOLEMY_MAX_ATTACHMENTS_PER_USER          = 200
  PTOLEMY_MAX_WORKSPACES_PER_USER           = 5
  PTOLEMY_MAX_PROJECTS_PER_USER             = 20
  PTOLEMY_MAX_INVITATIONS_PER_USER          = 100
  PTOLEMY_MAX_MEMBERS_PER_WORKSPACE         = 50
  PTOLEMY_MAX_MEMBERS_PER_PROJECT           = 50
  PTOLEMY_MAX_STATE_KEYS_PER_PROJECT        = 20
}
tiletopia_limits = {
  TILETOPIA_MAX_USERS              = 500
  TILETOPIA_SIGNUPS_PER_HOUR       = 30
  TILETOPIA_LOGIN_LOCKOUT_FAILURES = 5
  TILETOPIA_LOGIN_LOCKOUT_MINUTES  = 15
  # CloudFront, the ALB and the platform proxy each append to X-Forwarded-For
  TILETOPIA_TRUSTED_PROXY_HOPS = 3
}

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
  geokode = {
    cpu    = 1024
    memory = 2048
  }
}
