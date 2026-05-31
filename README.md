# GeoLang Infrastructure

One-click AWS deployment for the **GeoLang Intelligent Geospatial Suite** — agent-driven GIS intelligence.

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │         geolang.com (Route53)         │
                    │         ACM TLS Certificate           │
                    └──────────────┬───────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────┐
                    │        CloudFront CDN                 │
                    │   (tile caching at 50+ edge PoPs)     │
                    └──────────────┬───────────────────────┘
                                   │
    ┌──────────────────────────────▼───────────────────────────────┐
    │              Application Load Balancer                       │
    │            (path-based routing to services)                  │
    │                                                              │
    │   /agent/*       → GeoLang AI Agent     (port 8080)         │
    │   /tiles/*       → TileTopia 3D Tiles   (port 3000)         │
    │   /api/geocode/* → Geokode Geocoding    (port 3000)         │
    │   /api/route*    → Itinera Routing      (port 3000)         │
    │   /api/*         → Ptolemy Geodatabase  (port 3000)         │
    │   /*             → ViewTopia Frontend   (port 5174)         │
    └──────────────────────────────┬───────────────────────────────┘
                                   │
    ┌──────────────────────────────▼───────────────────────────────┐
    │                  ECS Fargate (Private Subnets)                │
    │                                                              │
    │   ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐  │
    │   │ ViewTopia │ │  Ptolemy  │ │ TileTopia │ │  GeoLang  │  │
    │   │  (Nginx)  │ │  (Rust)   │ │  (Rust)   │ │ (Python)  │  │
    │   └───────────┘ └───────────┘ └───────────┘ └─────┬─────┘  │
    │   ┌───────────┐ ┌───────────┐                     │        │
    │   │  Geokode  │ │  Itinera  │                ┌────▼────┐   │
    │   │  (Rust)   │ │  (Rust)   │                │  Letta  │   │
    │   └───────────┘ └───────────┘                │ (AI Mem)│   │
    │                                               └─────────┘   │
    │   Service Discovery: *.geolang-prod.local (Cloud Map)       │
    └──────────────────────────────┬───────────────────────────────┘
                                   │
    ┌──────────────────────────────▼───────────────────────────────┐
    │          RDS PostgreSQL 16 + PostGIS (Private Subnets)       │
    │                  (encrypted, auto-backup)                    │
    └─────────────────────────────────────────────────────────────┘
```

## Services

| Service | Description | Port | Language | Required |
|---------|-------------|------|----------|----------|
| **ViewTopia** | Web frontend — CesiumJS, MapLibre GL, deck.gl | 5174 | Node/Nginx | Yes |
| **Ptolemy** | Enterprise geodatabase API + geoprocessing | 3000 | Rust | Platform |
| **TileTopia** | 3D Tiles, terrain, point cloud, asset server | 3000 | Rust | Yes |
| **Geokode** | Forward/reverse geocoding | 3000 | Rust | Platform |
| **Itinera** | Routing, isochrones, delivery optimization | 3000 | Rust | Platform |
| **GeoLang** | AI/NLP geospatial agent (Letta + QGIS) | 8080 | Python | Yes |
| **Letta** | AI agent persistent memory server | 8283 | Python | With GeoLang |
| **PostGIS** | PostgreSQL 16 with PostGIS extensions | 5432 | — | Platform |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2 configured with credentials
- [Docker](https://docs.docker.com/get-docker/) for building container images
- An AWS account with permissions for ECS, RDS, S3, CloudFront, Route53, IAM, VPC

## Quick Start

### 1. Configure

```bash
cd infrastructure/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your settings. At minimum, set:

```hcl
db_password = "your-strong-password-here"
```

### 2. Deploy

```bash
# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Deploy everything
terraform apply
```

### 3. Build & Push Images

After `terraform apply`, the output includes deployment commands. The essential steps:

```bash
# Authenticate Docker with ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com

# Build and push each service (from workspace root)
for service in ptolemy tiletopia geokode itinera viewtopia; do
  docker build -t $(terraform output -json ecr_repositories | jq -r ".${service}"):latest ../${service}/
  docker push $(terraform output -json ecr_repositories | jq -r ".${service}"):latest
done

# GeoLang (separate — different directory structure)
docker build -t $(terraform output -json ecr_repositories | jq -r '.geolang'):latest ../geolang/
docker push $(terraform output -json ecr_repositories | jq -r '.geolang'):latest

# Force ECS to pull new images
aws ecs update-service --cluster geolang-prod --service geolang-prod-ptolemy --force-new-deployment
# (repeat for each service)
```

### 4. Verify

```bash
# Check platform health
curl $(terraform output -raw platform_url)/api/v1/health

# Open the web UI
open $(terraform output -raw platform_url)
```

## Deployment Profiles

### Minimal (Dev/Demo) — ~$50-80/month

4 services, no database, no CDN. Good for development and demos.

```bash
terraform apply -var-file=profiles/minimal.tfvars -var="db_password=unused"
```

**Includes:** TileTopia, GeoLang, Letta, ViewTopia

### Full Platform — ~$150-250/month

All 8 services with RDS PostGIS, CloudFront CDN, and Route53 DNS.

```bash
terraform apply -var-file=profiles/platform.tfvars -var="db_password=your-password"
```

**Includes:** PostGIS, Ptolemy, TileTopia, Geokode, Itinera, GeoLang, Letta, ViewTopia

## Configuration Reference

### Service Toggles

Each service can be independently enabled/disabled:

```hcl
enable_ptolemy   = true    # Geodatabase API (requires enable_database)
enable_tiletopia = true    # 3D Tiles / terrain server
enable_geokode   = false   # Geocoding service
enable_itinera   = false   # Routing service
enable_geolang   = true    # AI agent (auto-enables Letta)
enable_viewtopia = true    # Web frontend
enable_database  = true    # RDS PostGIS
enable_cdn       = true    # CloudFront CDN
enable_dns       = true    # Route53 + ACM certificate
```

### Enterprise Feature Toggles

```hcl
enable_waf       = true    # WAF on ALB (OWASP, rate limiting, geo-blocking)
enable_cache     = true    # ElastiCache Redis for caching
enable_efs       = true    # EFS shared persistent storage
enable_secrets   = true    # Secrets Manager for credentials
enable_security  = true    # GuardDuty + VPC Flow Logs
enable_queues    = true    # SQS queues for async processing
enable_backup    = true    # AWS Backup vault (daily + weekly)
enable_bastion   = true    # Bastion host with SSM Session Manager
```

### Fargate Sizing

Default sizing applies to all services. Override per-service for workloads that need more resources:

```hcl
service_defaults = {
  cpu           = 256   # 0.25 vCPU
  memory        = 512   # 0.5 GB
  desired_count = 1
}

service_overrides = {
  geolang = {
    cpu    = 1024   # 1 vCPU (Python + QGIS + AI inference)
    memory = 2048   # 2 GB
  }
  ptolemy = {
    cpu    = 512    # 0.5 vCPU (geoprocessing queries)
    memory = 1024   # 1 GB
  }
}
```

Valid CPU/Memory combinations (AWS Fargate):

| CPU (units) | Memory (MB) | Approx. Monthly Cost |
|-------------|-------------|---------------------|
| 256 (0.25 vCPU) | 512–2048 | ~$8–12 |
| 512 (0.5 vCPU) | 1024–4096 | ~$15–25 |
| 1024 (1 vCPU) | 2048–8192 | ~$30–50 |
| 2048 (2 vCPU) | 4096–16384 | ~$60–100 |
| 4096 (4 vCPU) | 8192–30720 | ~$120–200 |

### Container Images

By default, Terraform creates ECR repositories and expects you to push images. You can also use external registries:

```hcl
container_images = {
  ptolemy   = "ghcr.io/geolang/ptolemy:v1.0.0"
  tiletopia = "ghcr.io/geolang/tiletopia:v1.0.0"
}
```

### Custom Domain (geolang.com)

To use your domain:

1. Enable DNS in your tfvars:
   ```hcl
   enable_dns  = true
   domain_name = "geolang.com"
   ```

2. After `terraform apply`, update your domain registrar's name servers to the values from:
   ```bash
   terraform output name_servers
   ```

3. Wait for DNS propagation (can take up to 48 hours).

4. The ACM certificate will auto-validate via DNS once propagation completes.

## Module Structure

```
infrastructure/
├── main.tf                    # Root module — wires everything together
├── variables.tf               # All input variables
├── outputs.tf                 # Platform URLs, deploy commands
├── versions.tf                # Provider version constraints
├── terraform.tfvars.example   # Example configuration
├── .gitignore                 # Terraform-specific ignores
├── profiles/
│   ├── minimal.tfvars         # Dev/demo: 4 services, ~$50-80/mo
│   └── platform.tfvars        # Full platform: 8 services, ~$150-250/mo
├── .github/
│   └── workflows/
│       └── deploy.yml         # CI/CD: build, push, deploy pipeline
└── modules/
    ├── networking/            # VPC, subnets, NAT, route tables
    │   └── main.tf
    ├── database/              # RDS PostGIS 16, security group
    │   └── main.tf
    ├── ecr/                   # Container registries (1 per service)
    │   └── main.tf
    ├── ecs/                   # Fargate cluster, tasks, service discovery
    │   └── main.tf
    ├── loadbalancer/          # ALB, path-based routing, security groups
    │   └── main.tf
    ├── cdn/                   # CloudFront with tile-optimized caching
    │   └── main.tf
    ├── dns/                   # Route53 zone, ACM certificate
    │   └── main.tf
    ├── monitoring/            # CloudWatch dashboards, alarms, SNS
    │   └── main.tf
    ├── autoscaling/           # ECS target tracking (CPU/memory)
    │   └── main.tf
    └── bastion/               # EC2 bastion with SSM Session Manager
        └── main.tf
```

### Module Descriptions

| Module | Purpose | Key Resources |
|--------|---------|---------------|
| **networking** | Network foundation | VPC, 2+ public subnets, 2+ private subnets, IGW, NAT Gateway |
| **database** | PostGIS database | RDS PostgreSQL 16, DB subnet group, security group |
| **ecr** | Container registries | 1 ECR repo per service, lifecycle policies, scan-on-push |
| **ecs** | Compute layer | Fargate cluster, task definitions, ECS services, Cloud Map service discovery |
| **loadbalancer** | Traffic routing | ALB, target groups, path-based listener rules, ALB + ECS security groups |
| **cdn** | Edge caching | CloudFront distribution with tile-optimized cache behaviors |
| **dns** | Domain management | Route53 hosted zone, ACM certificate with DNS validation |
| **monitoring** | Observability | CloudWatch dashboard, CPU/memory/5xx alarms, SNS alert topic |
| **autoscaling** | Auto scaling | ECS target tracking policies for CPU and memory utilization |
| **bastion** | Secure access | EC2 bastion host with SSM Session Manager, DB port forwarding |
| **waf** | Web firewall | WAF v2 with OWASP rules, rate limiting, geo-blocking, logging |
| **cache** | Caching | ElastiCache Redis for geocoding, routing, tile metadata cache |
| **storage** | Shared storage | EFS with per-service access points (TileTopia, GeoLang, Letta) |
| **secrets** | Credentials | Secrets Manager for DB creds, API keys, Letta password |
| **security** | Threat detection | GuardDuty, VPC Flow Logs, ECS Exec IAM policy |
| **queues** | Async processing | SQS queues with DLQs for tiles, geocoding, AI, ETL |
| **backup** | Disaster recovery | AWS Backup vault with daily/weekly schedules, cross-region copy |

## Networking

The VPC uses a standard public/private subnet architecture:

- **Public subnets** — ALB, NAT Gateway
- **Private subnets** — ECS Fargate tasks, RDS database
- **NAT Gateway** — Single NAT for outbound internet (ECR pulls, external APIs)
- **Security Groups** — ALB allows 80/443 inbound; ECS allows traffic from ALB only; RDS allows 5432 from ECS only

### Inter-Service Communication

Services communicate via [AWS Cloud Map](https://docs.aws.amazon.com/cloud-map/latest/dg/what-is-cloud-map.html) service discovery:

```
ptolemy.geolang-prod.local:3000
tiletopia.geolang-prod.local:3000
geokode.geolang-prod.local:3000
itinera.geolang-prod.local:3000
geolang.geolang-prod.local:8080
letta.geolang-prod.local:8283
```

GeoLang (the AI agent) uses these DNS names to call other services internally, matching the Docker Compose service discovery pattern.

## Monitoring & Alerts

### CloudWatch Dashboard

After deployment, access the dashboard at the URL from:

```bash
terraform output dashboard_url
```

The dashboard shows CPU/memory utilization for each service and ALB request metrics.

### Alarms

Alarms are pre-configured for:

- **ECS CPU > 80%** (per service, 3 consecutive periods)
- **ECS Memory > 85%** (per service, 3 consecutive periods)
- **ALB 5xx > 10** (2 consecutive periods)
- **RDS CPU > 80%** (when database is enabled)
- **RDS Storage < 2 GB** (when database is enabled)

Subscribe to alerts:

```bash
aws sns subscribe \
  --topic-arn $(terraform output -raw alerts_topic_arn) \
  --protocol email \
  --notification-endpoint your@email.com
```

## Cost Breakdown

### Minimal Profile (~$50-80/month)

| Resource | Monthly Cost |
|----------|-------------|
| ECS Fargate (4 tasks × 0.25 vCPU) | ~$30 |
| NAT Gateway + data | ~$35 |
| ALB | ~$16 |
| S3 (small usage) | ~$1 |
| CloudWatch Logs | ~$1 |
| **Total** | **~$80** |

### Platform Profile (~$150-250/month)

| Resource | Monthly Cost |
|----------|-------------|
| ECS Fargate (8 tasks, mixed sizing) | ~$80 |
| RDS db.t4g.micro | ~$12 |
| NAT Gateway + data | ~$35 |
| ALB | ~$16 |
| CloudFront (light usage) | ~$5 |
| ElastiCache (cache.t4g.micro) | ~$12 |
| EFS (elastic, light usage) | ~$3 |
| WAF (managed rules) | ~$10 |
| S3 | ~$2 |
| Route53 | ~$1 |
| CloudWatch + GuardDuty | ~$5 |
| Bastion (t4g.nano) | ~$3 |
| **Total** | **~$185** |

> **Cost-saving tip:** For dev environments, you can stop ECS services after hours by setting `desired_count = 0` and restarting them when needed.

## Operations

### Scaling a Service

```bash
# Scale up Ptolemy to 3 instances
aws ecs update-service --cluster geolang-prod \
  --service geolang-prod-ptolemy \
  --desired-count 3

# Or update Terraform:
# service_overrides = { ptolemy = { desired_count = 3 } }
# terraform apply
```

### Viewing Logs

```bash
# Tail logs for a specific service
aws logs tail /ecs/geolang-prod/ptolemy --follow

# Search logs
aws logs filter-log-events \
  --log-group-name /ecs/geolang-prod/geolang \
  --filter-pattern "ERROR"
```

### Updating a Service

```bash
# Rebuild and push new image
docker build -t <ecr-url>:latest ../ptolemy/
docker push <ecr-url>:latest

# Force new deployment
aws ecs update-service --cluster geolang-prod \
  --service geolang-prod-ptolemy \
  --force-new-deployment

# Watch deployment progress
aws ecs wait services-stable --cluster geolang-prod \
  --services geolang-prod-ptolemy
```

### Database Access

The RDS instance is in private subnets with no public access. Connect via the bastion host:

```bash
# Enable bastion in your tfvars:
# enable_bastion = true

# Connect to bastion via SSM (no SSH keys needed):
terraform output -raw bastion_ssm_command
# → aws ssm start-session --target i-0abc123def456

# Port-forward to RDS for local psql access:
terraform output -raw bastion_db_tunnel_command
# → aws ssm start-session --target i-0abc123def456 \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"portNumber":["5432"],"localPortNumber":["5432"]}'

# Then in another terminal:
psql -h localhost -U ptolemy -d ptolemy
```

## Autoscaling

The platform profile enables autoscaling by default. Services scale based on CPU and memory utilization:

```hcl
enable_autoscaling = true

autoscaling_config = {
  ptolemy = {
    min_capacity  = 1
    max_capacity  = 3
    cpu_target    = 70    # Scale out when CPU > 70%
    memory_target = 75    # Scale out when memory > 75%
  }
  tiletopia = {
    min_capacity  = 1
    max_capacity  = 4
    cpu_target    = 65
    memory_target = 70
  }
}
```

**How it works:**

- **Scale out** — When average CPU or memory exceeds the target for 60 seconds, a new task is added (up to `max_capacity`).
- **Scale in** — When metrics drop below target for 5 minutes, tasks are removed (down to `min_capacity`).
- Each service scales independently based on its own utilization.

## CI/CD Pipeline (GitHub Actions)

The included GitHub Actions workflow (`.github/workflows/deploy.yml`) automates the full build-deploy cycle.

### Pipeline Stages

```
┌──────────┐    ┌───────────┐    ┌───────────┐    ┌──────────┐    ┌─────────────┐
│ Detect   │───▶│ Terraform │───▶│   Build   │───▶│  Deploy  │───▶│ Health      │
│ Changes  │    │ Plan/Apply│    │ & Push    │    │ to ECS   │    │ Check       │
└──────────┘    └───────────┘    └───────────┘    └──────────┘    └─────────────┘
```

### Triggers

| Trigger | Action |
|---------|--------|
| Push to `main` | Auto-deploy changed services to **prod** |
| Push to `develop` | Auto-deploy changed services to **dev** |
| Manual dispatch | Deploy selected services to chosen environment |

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user with ECR/ECS/Terraform permissions |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_REGION` | AWS region (e.g., `us-east-1`) |
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID |
| `TF_VAR_db_password` | RDS database password |

### Manual Deployment

Trigger a manual deployment from the GitHub Actions tab:

1. Go to **Actions → Deploy GeoLang Platform → Run workflow**
2. Select:
   - **Services**: comma-separated list or `all`
   - **Environment**: `dev`, `staging`, or `prod`
   - **Terraform action**: `plan`, `apply`, or `destroy`

### Change Detection

The pipeline automatically detects which services changed:

- Changes in `ptolemy/` → only rebuilds and deploys Ptolemy
- Changes in `infrastructure/` → runs Terraform plan/apply
- Changes in multiple services → builds all changed services in parallel

### Teardown

```bash
# Destroy all resources
terraform destroy

# Or destroy a specific profile
terraform destroy -var-file=profiles/minimal.tfvars
```

## Remote State (Recommended for Teams)

For team usage, configure S3 backend for state management:

1. Create a state bucket and DynamoDB lock table:
   ```bash
   aws s3 mb s3://geolang-terraform-state --region us-east-1
   aws dynamodb create-table \
     --table-name geolang-terraform-locks \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST
   ```

2. Uncomment the `backend "s3"` block in `versions.tf`.

3. Run `terraform init -migrate-state` to migrate existing state.

## Security Notes

- **WAF** — OWASP core rules, SQL injection protection, known bad inputs, rate limiting, geo-blocking
- **RDS** — Private subnets only, encrypted at rest, no public access
- **ECS** — Private subnets, outbound via NAT Gateway
- **S3** — Public access blocked, server-side encryption (AES-256)
- **EFS** — Encrypted at rest, per-service access points for isolation
- **ALB** — TLS 1.3 when ACM certificate is attached
- **IAM** — Least-privilege roles; ECS tasks only access their own S3 bucket
- **Bastion** — SSM Session Manager (no SSH keys); IMDSv2 enforced; encrypted EBS
- **GuardDuty** — Threat detection with S3 monitoring and malware protection
- **VPC Flow Logs** — Full network audit trail (90-day retention)
- **Secrets Manager** — Centralized credential storage with rotation support
- **Backup** — Daily + weekly automated backups with optional cross-region DR
- **Secrets** — `terraform.tfvars` is gitignored; use Secrets Manager in production/CI

## License

AGPL-3.0-or-later — matching the GeoLang suite license.
