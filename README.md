# GeoLang AWS infrastructure

This Terraform stack deploys the GeoLang platform to AWS. The full profile matches the current ViewTopia platform compose path for the flagship viewer, collaboration, notebook, and agent workflows.

Terraform does not build images, populate secret values, load spatial data, create application users, or run database migrations itself. ECS services start at a desired count of zero until `runtime_secrets_ready` is set to `true`.

## Full platform

`profiles/platform.tfvars` enables:

- ViewTopia
- the Caddy platform proxy
- Ptolemy
- TileTopia
- Fenestra
- Geokode
- Itinera
- Interiora
- Agora
- geoplumb
- Sibyl
- geodukt
- GeoLang API
- GeoLang executor
- Jupyter

CloudFront sends requests to an Application Load Balancer. The load balancer has one catch-all target, the platform proxy. The proxy applies the same prefix rewrites as `viewtopia/deploy/nginx-platform.conf`, then resolves private ECS services through Cloud Map.

The proxy image is buildable from [containers/platform-proxy](containers/platform-proxy). Its Caddy image is pinned to `caddy:2.11.4-alpine`.

The Jupyter image is pinned to `quay.io/jupyter/scipy-notebook:2025-12-31`. That tag is documented by the official Jupyter Docker Stacks project. Jupyter keeps the `/jupyter` prefix so its kernel WebSocket URLs continue to work through CloudFront and the proxy.

## Databases and storage

Ptolemy and Agora use separate encrypted RDS PostgreSQL 16 instances. RDS manages each master password in Secrets Manager. Ptolemy enables its required PostGIS extensions during its own migrations.

Agora's separate instance is intentional. Terraform can create it without placing a database administrator credential in configuration or state. It also adds a second instance charge and a second allocation of RDS storage. With the platform profile defaults, changing `db_instance_class`, `db_allocated_storage`, or `db_multi_az` changes the cost of both databases.

EFS access points provide persistent storage for:

- TileTopia data
- Geokode and Itinera spatial source data
- Interiora venue data
- geoplumb's disk cache
- Fenestra coverages
- Sibyl's SQLite database
- GeoLang's cache
- GeoLang outputs, user data, and live data shared with geodukt and the executor
- Jupyter notebooks under `/home/jovyan/work`

Before starting services, place `region.osm.pbf` in the spatial data access point for Geokode. Itinera writes or reads `graph.bin` in that same access point. Place any Fenestra GeoTIFF coverages in its access point.

geoplumb uses a real public STAC layer configuration copied into its wrapper image from [containers/geoplumb/layers.toml](containers/geoplumb/layers.toml). The configuration has no credentials. Its image is built in two steps so the configuration is part of an immutable deployable artifact.

## Runtime secrets

No credential belongs in a Terraform value, generated file, image command, or process argument. ECS injects runtime values from AWS Secrets Manager or SSM Parameter Store.

When `enable_secrets` is true, Terraform creates the empty Secrets Manager resources needed by the enabled services. The full profile uses these keys:

- `platform_jwt`, shared by the platform JWT issuers and validators
- `ptolemy_database_url`, the complete Ptolemy PostgreSQL URL
- `agora_database_url`, the complete Agora PostgreSQL URL
- `geolang_executor`, shared only by the GeoLang API and executor
- `llm_api_key`, exposed to Sibyl as `XAI_API_KEY`
- `jupyter_token`, exposed to Jupyter as `JUPYTER_TOKEN`

Terraform deliberately creates no secret versions. Populate the values outside Terraform after the first infrastructure apply. The two database URL secrets can be assembled from the corresponding RDS endpoint and RDS managed credential secret. Keep those URLs out of shell arguments and command history. The AWS console or a command that reads the value from standard input is appropriate.

Existing secret resources can be supplied through `runtime_secret_arns`. Keys in that map override Terraform-managed secret ARNs. If an existing secret uses a customer managed KMS key, grant the ECS execution role permission to decrypt it.

`runtime_secrets_ready = true` is an operator assertion. Terraform verifies that an ARN exists for every secret required by the enabled services. Terraform cannot verify that an externally populated secret contains a usable value. Leave the flag false until all image, data, and secret inputs are ready. This keeps empty managed secrets and empty ECR repositories from causing ECS restart loops.

The Jupyter token must also match the token configured in ViewTopia's notebook settings. Do not put the token in a frontend build argument.

## Image build map

Terraform creates ECR repositories but does not build or push images. Use the repository URLs from `terraform output -json ecr_repositories`.

Build these repositories from their existing service contexts:

```text
ptolemy          ../ptolemy
tiletopia        ../tiletopia
geokode          ../geokode
itinera          ../itinera
interiora        ../interiora
fenestra         ../fenestra
agora            ../agora
sibyl            ../sibyl
geodukt          ../geodukt
viewtopia        ../viewtopia
platform-proxy   containers/platform-proxy
```

Build the geoplumb wrapper with the same final base image name used in its first build:

```bash
docker build -t geoplumb-base:local ../geoplumb
docker build --build-arg GEOPLUMB_BASE_IMAGE=geoplumb-base:local -t <geoplumb-ecr-url>:latest containers/geoplumb
```

The platform proxy has an explicit build context:

```bash
docker build -t <platform-proxy-ecr-url>:latest containers/platform-proxy
```

GeoLang API and GeoLang executor use the same image. The current `../geolang/Dockerfile` installs dependencies but does not copy the application source because compose bind mounts the repository into `/app/geolang`. Do not set `runtime_secrets_ready` to true until the operator supplies a corrected image that contains the GeoLang source. This is the remaining image blocker for a hosted launch.

Jupyter pulls its pinned Quay image directly and has no ECR repository.

## Deployment sequence

Copy the example and choose a profile:

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -var-file=profiles/platform.tfvars
```

The first apply must keep `runtime_secrets_ready = false`. It creates the network, databases, EFS access points, ECR repositories, secret containers, task definitions, and zero-count ECS services.

After that apply:

1. Build and push every enabled ECR image.
2. Stage the required files in EFS.
3. Populate all required runtime secret values.
4. Confirm the ViewTopia Jupyter setting uses the deployed token.
5. Set `runtime_secrets_ready = true`.
6. Review a new plan before applying it.

Terraform outputs the RDS endpoints, RDS managed credential secret ARNs, runtime secret ARNs, ECR repositories, and EFS access points needed for those steps.

Do not use `terraform apply -auto-approve` for the readiness transition. A normal plan makes the service scale-up visible before it changes AWS.

## Routing

The proxy preserves or strips paths according to the current platform compose contract:

- `/agent/*` to GeoLang API with `/agent` removed
- `/api/v1/realtime/*` to TileTopia with the path preserved
- `/tiles/*` to TileTopia as `/api/*`
- `/ogc/*` to Fenestra with `/ogc` removed
- `/api/delivery/*`, `/api/route`, `/api/isochrone`, and `/api/network/*` to Itinera
- `/api/pipeline/runs*` to geodukt as `/runs*`
- `/api/indoor/*` to Interiora with the full prefix removed
- `/agora/*` to Agora with `/agora` removed
- `/plumb/*` to geoplumb with `/plumb` removed
- `/api/geocode/*` to Geokode with the prefix removed
- `/api/v1/auth/oidc/*`, remaining `/api/*`, and `/ws/*` to Ptolemy
- TileTopia auth, portal, assets, terrain, and catalog paths to TileTopia
- `/jupyter/*` to Jupyter with the path preserved
- remaining requests to ViewTopia

CloudFront has zero-cache behaviors for the TileTopia, Ptolemy, Agora, and Jupyter WebSocket paths. It forwards the WebSocket subprotocol header used for bearer authentication. Static frontend assets and public immutable tile paths keep their existing cache policies.

## Validation

Run the local checks without contacting AWS:

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

The GitHub workflow runs the same format and validation checks. Its manual plan job needs AWS credentials because `terraform plan` reads account and region data sources. No runtime application credential is passed to Terraform.

## Important outputs

- `platform_url`
- `ecr_repositories`
- `database_endpoint`
- `database_master_user_secret_arn`
- `agora_database_endpoint`
- `agora_database_master_user_secret_arn`
- `runtime_secret_arns`
- `efs_access_points`
- `service_discovery_namespace`

## Safe apply blockers

The infrastructure can be planned before these are resolved, with all services held at zero:

- The GeoLang image must be changed or supplied so it contains the application source.
- Every enabled ECR image must be pushed.
- EFS spatial and coverage data must be staged.
- All required secret containers must have a current value.
- DNS delegation and ACM validation must complete when the platform profile uses `geolang.com`.

Review the second plan after setting `runtime_secrets_ready = true`. It is the point where ECS begins running the platform.
