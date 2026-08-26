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

CloudFront sends requests to an Application Load Balancer. The load balancer has one catch-all target, the platform proxy. The proxy resolves private ECS services through Cloud Map. Its rewrites are close to `viewtopia/deploy/nginx-platform.conf` but not identical, so use the routing table below as the contract rather than the compose config.

Two differences matter. The compose nginx routes `/collecta/*` to Collecta with the prefix stripped. Terraform deploys no Collecta service, so the hosted proxy returns 501 for `/collecta` and `/collecta/*`. In the other direction the Caddyfile sends `/api/v1/assets`, `/api/v1/terrain/*`, and `/api/v1/catalog*` to TileTopia where nginx sends them to Ptolemy.

The proxy image is buildable from [containers/platform-proxy](containers/platform-proxy). Its Caddy image is pinned to `caddy:2.11.4-alpine`.

The Jupyter image is pinned to `quay.io/jupyter/scipy-notebook:2025-12-31`. That tag is documented by the official Jupyter Docker Stacks project. Jupyter keeps the `/jupyter` prefix so its kernel WebSocket URLs continue to work through CloudFront and the proxy.

## Databases and storage

Ptolemy and Agora use separate encrypted RDS PostgreSQL 16 instances. RDS manages each master password in Secrets Manager. Ptolemy enables its required PostGIS extensions during its own migrations.

Both instances set `rds.force_ssl`, so a plaintext connection is refused. The `ptolemy_database_url` and `agora_database_url` secret values must end in `?sslmode=verify-full&sslrootcert=/etc/ssl/rds-global-bundle.pem`. Ptolemy and Agora already use the `sqlx` Rustls backend.

Do not use `sslmode=require` here. Under `require`, sqlx installs a certificate verifier that accepts any certificate and ignores `sslrootcert`, so the connection is encrypted but the server is never authenticated and anything answering in the database's place can read and rewrite the session. Only `verify-ca` and `verify-full` check the chain.

The URL must name the RDS endpoint directly, since a CNAME in front of it fails hostname verification. Each service image fetches the AWS RDS global CA bundle to the path above during its build.

Agora's separate instance is intentional. Terraform can create it without placing a database administrator credential in configuration or state. It also adds a second instance charge and a second allocation of RDS storage. With the platform profile defaults, changing `db_instance_class`, `db_allocated_storage`, or `db_multi_az` changes the cost of both databases.

EFS access points provide persistent storage for:

- TileTopia data
- Geokode and Itinera spatial source data
- Interiora venue data
- geoplumb's disk cache
- Fenestra coverages
- Sibyl's SQLite database
- GeoLang's cache
- GeoLang Natural Earth reference data shared by the API and executor at `/app/geolang/natural_earth`
- GeoLang outputs, user data, and live data shared with geodukt and the executor
- Jupyter notebooks under `/home/jovyan/work`

Before starting services, place `region.osm.pbf` in the spatial data access point for Geokode. Itinera writes or reads `graph.bin` in that same access point. Place any Fenestra GeoTIFF coverages in its access point. Place GeoLang Natural Earth data in the GeoLang Natural Earth access point.

geoplumb uses a real public STAC layer configuration copied into its wrapper image from [containers/geoplumb/layers.toml](containers/geoplumb/layers.toml). The configuration has no credentials. Its image is built in two steps so the configuration is part of an immutable deployable artifact.

## Runtime secrets

No credential belongs in a Terraform value, checked-in file, image command, or process argument. ECS injects runtime values from AWS Secrets Manager or SSM Parameter Store.

When `enable_secrets` is true, Terraform creates the empty Secrets Manager resources needed by the enabled services. The full profile uses these keys:

- `platform_jwt`, shared by the platform JWT issuers and validators
- `ptolemy_database_url`, the complete Ptolemy PostgreSQL URL
- `agora_database_url`, the complete Agora PostgreSQL URL
- `geolang_executor`, shared only by the GeoLang API and executor
- `llm_api_key`, exposed to Sibyl as `SIBYL_CLOUD_API_KEY`
- `jupyter_token`, exposed to Jupyter as `JUPYTER_TOKEN`

Terraform deliberately creates no secret versions. Populate the four operator-managed values after the first infrastructure apply. Each command reads the value from a silent prompt or standard input, writes it through a mode 600 temporary file, and removes that file on exit:

```bash
./scripts/put-runtime-secret.sh platform_jwt
./scripts/put-runtime-secret.sh geolang_executor
./scripts/put-runtime-secret.sh llm_api_key
./scripts/put-runtime-secret.sh jupyter_token
```

Do not use this command for the two database URLs. When `enable_database_secret_refresh` is true, Terraform deploys a Python 3.13 Lambda and an EventBridge schedule for those values. Every 15 minutes it reads the RDS-managed credentials, builds the verified direct-endpoint URL, updates a changed runtime URL secret, forces the matching ECS service to deploy new tasks, and waits for the service to stabilize. A failed ECS update restores the previous secret version so the next schedule retries. No password enters Terraform configuration, state, process arguments, or logs.

The first scheduled run creates the Ptolemy and Agora URL versions. RDS rotates each managed master password every seven days by default. After a rotation, new database connections can fail until the next scheduled run and ECS replacement complete. A live rotation test remains required before public use.

Existing secret resources can be supplied through `runtime_secret_arns`. Keys in that map override Terraform-managed secret ARNs. The two database URL targets must be full Secrets Manager ARNs when automatic refresh is enabled. Other runtime values may use Secrets Manager or SSM. If an existing secret uses a customer managed KMS key, grant the ECS execution role permission to decrypt it. The refresh Lambda has no wildcard KMS permission, so a customer managed key for either database secret needs an explicit policy change before use.

`runtime_secrets_ready = true` is an operator assertion. Terraform verifies that an ARN exists for every secret required by the enabled services. Terraform cannot verify that an externally populated secret contains a usable value. Leave the flag false until all image, data, and secret inputs are ready. This keeps empty managed secrets and empty ECR repositories from causing ECS restart loops.

There is no deployment-time place to configure the Jupyter token for ViewTopia. ViewTopia keeps it in per-browser `localStorage` with a hardcoded default of `viewtopia-local`, so every user pastes the deployed token into notebook settings by hand. Do not put the token in a frontend build argument.

One token also means one shared credential to a server that runs arbitrary code as whoever holds it. Anyone given the token has the same access as everyone else, and revoking it means rotating the secret and telling every user to paste a new one.

## Image build map

Terraform creates ECR repositories but does not build or push images. Use the repository URLs from `terraform output -json ecr_repositories`.

Repository tags are immutable. A repository rejects a push to a tag it already holds, so every build needs its own tag and there is no moving `latest`. Every service deploys the tag in `image_tag`, which defaults to `v0.1.0`. Push the new tag, then change `image_tag` to roll the platform. The repository lifecycle policy keeps the last ten tags beginning with `v`.

After the first infrastructure apply creates the repositories, publish every enabled image from the sibling checkouts with one tag:

```bash
./scripts/publish-images.sh v0.1.0
```

The command reads `ecr_repositories` from Terraform state, rejects any tag that already exists, builds every image for Linux x86_64, then logs in and pushes only after all builds pass. It requires Terraform, the AWS CLI, Docker Buildx, and jq. The tag passed here must also be the Terraform `image_tag` used for the readiness apply.

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
geolang-api      ../geolang
platform-proxy   containers/platform-proxy
```

There are thirteen ECR repositories. `geolang-api` is the thirteenth, and both the GeoLang API and the GeoLang executor deploy from it, so it is one build and one push for two services.

The publication command builds the geoplumb base first, then builds its wrapper with the same local base image. The platform proxy uses its explicit context under `containers/platform-proxy`.

GeoLang API and GeoLang executor use the same image from the `geolang-api` repository. The image contains `src/` and uses a deny-first `.dockerignore` so local runtime data and secret files do not enter the build context. A local build verified both API entry points and both health routes without a bind mount on 2026-08-22. The image still needs an immutable ECR tag before hosted scale-up.

Jupyter pulls its pinned Quay image directly and has no ECR repository.

## Deployment sequence

Copy the example and choose a profile:

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -var-file=profiles/platform.tfvars
```

The first apply must keep `runtime_secrets_ready = false`. It creates the network, databases, EFS access points, ECR repositories, secret containers, task definitions, and zero-count ECS services.

On the platform profile the first apply cannot finish in one pass. The load balancer security group needs the certificate ARN, the certificate needs ACM validation, validation needs the domain's nameservers delegated at the registrar, and the hosted zone that publishes those nameservers is created by the same apply. So the load balancer, and with it every ECS service and target group, cannot be created until delegation exists. The working sequence is:

1. Apply once. ACM validation eventually times out and the apply fails part way. Everything that does not depend on the certificate is created, including the Route53 zone.
2. Read `terraform output name_servers`.
3. Set those nameservers at the domain registrar and wait for the delegation to propagate.
4. Apply again. Validation completes and the load balancer, target groups, and zero-count services are created.

After that second apply:

1. Run `./scripts/publish-images.sh <image_tag>` to build and push every enabled ECR image.
2. Stage the required files in EFS.
3. Populate the four operator-managed runtime secrets and wait for the database refresh job to create both URL secret versions.
4. Distribute the Jupyter token to the people who need notebooks. There is nothing to configure at deploy time, because each user pastes the token into ViewTopia's notebook settings in their own browser.
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
- `/collecta` and `/collecta/*` to the explicit undeployed-service 501 response
- remaining requests to ViewTopia

Every route is gated on an `ENABLE_*` environment variable that Terraform sets from the profile's service toggles. A profile that leaves a service out answers 501 on that service's paths instead of proxying to a Cloud Map name that does not resolve. The gates default to closed, so the proxy serves a route only when the deployment names the service.

The minimal profile runs TileTopia, GeoLang API, and ViewTopia, so its Collecta, Fenestra, Agora, geoplumb, Jupyter, Geokode, Itinera, Interiora, geodukt, and Ptolemy paths all return 501. One combination stays approximate: when Ptolemy runs and TileTopia does not, TileTopia's `/api/v1` paths reach Ptolemy's catch-all and take its 404 instead of a 501. Neither profile uses that combination.

CloudFront has zero-cache behaviors for the TileTopia, Ptolemy, Agora, and Jupyter WebSocket paths. It forwards the WebSocket subprotocol header used for bearer authentication. Static frontend assets and public immutable tile paths (`/tiles/v1/assets/*/tileset.json`, `/tiles/v1/assets/*/tiles/*`, `/tiles/v1/terrain/*`) keep long TTLs. Those are the URLs the viewer requests; the proxy rewrites them to tiletopia after CloudFront.

When `enable_cdn` is true, the load balancer admits only the AWS-managed `com.amazonaws.global.cloudfront.origin-facing` prefix list, so the CDN cannot be bypassed by calling the load balancer name directly. That prefix list counts as 55 of a security group's 60 rules, which leaves room for one port. The admitted port is 443 when a domain is configured, because CloudFront then reaches the origin over HTTPS, and 80 otherwise. Without a CDN the load balancer is the only way in and stays open.

The port 80 case is the shipped default, since `enable_cdn = true` and no domain is set. With no certificate, CloudFront uses `origin_protocol_policy = "http-only"`, so every request it forwards crosses the public internet to the load balancer in cleartext, Authorization headers and session cookies included. The Terraform says so in a comment. Configure a domain and certificate before carrying real credentials.

## Task network isolation

ECS tasks are split across four security groups.

Most services share one group that reaches every other service, the Ptolemy database, and the internet. On the platform profile that group holds twelve tasks: Ptolemy, TileTopia, Geokode, Itinera, Interiora, geoplumb, Fenestra, Sibyl, geodukt, ViewTopia, the platform proxy, and the GeoLang API. The Agora database ingress names only the Agora security group, so the shared group cannot reach it.

Agora has its own group because it listens on the same port the executor's tool calls use. Its ingress admits the whole shared group, so any of those twelve tasks can call it, not only the proxy and the GeoLang API. What the group actually buys is exclusion: the GeoLang executor and Jupyter, the two tasks running user-supplied code, cannot reach Agora at all.

That is a second layer, not the only one. Agora authenticates its own requests. Every route needs a token except `/health`, share-link resolution, and attachment reads, and those last two carry per-document capability tokens.

The GeoLang executor has a group whose egress is limited to its tool call targets, DNS, EFS, and outbound HTTPS. Jupyter has a fourth group with no tool call egress at all, since notebooks call no platform service. Both of those run user-supplied code and use a task role that holds no policies.

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
- `name_servers`, the hosted zone nameservers to set at the registrar between the first and second apply
- `ecr_repositories`
- `database_endpoint`
- `database_master_user_secret_arn`
- `agora_database_endpoint`
- `agora_database_master_user_secret_arn`
- `runtime_secret_arns`
- `efs_access_points`
- `service_discovery_namespace`

## Monitoring and unused resources

The load balancer CloudWatch alarms and both load balancer dashboard widgets pass the ALB DNS name where the metric dimension needs the ARN suffix, so they match no metric and report no data instead of failing.

The ElastiCache and SQS resources the platform profile enables have no consumer. No service is given a Redis endpoint or a queue URL, so both cost money and carry no traffic.

## Safe apply blockers

The infrastructure can be planned before these are resolved, with all services held at zero:

- The Ptolemy and Agora database URL secrets must use `sslmode=verify-full` with `sslrootcert`, or they cannot connect to a database that forces SSL. The image side of this is already done: both services name the `tls-rustls-ring` sqlx backend.
- Every enabled ECR image must be pushed under the tag in `image_tag`.
- EFS spatial, coverage, and GeoLang Natural Earth data must be staged.
- All required secret containers must have a current value.
- DNS delegation and ACM validation must complete when the platform profile uses `geolang.com`.
- The RDS engine version is pinned to `16.4`, released in August 2024. Verify that minor is still offered in the target region before applying, since RDS drops old minors and the instance create fails if it is gone.
- GuardDuty is created unconditionally. `aws_guardduty_detector` fails if the account already has a detector in that region.
- The Route53 zone is created unconditionally. If the domain already has a hosted zone, this makes a second one with different nameservers, and ACM validation never resolves because the registrar points at the old zone.
- The S3 backend is commented out. `terraform init` in CI runs against empty state, so the workflow's manual plan job always reports that it will create everything. It cannot serve as the pre-apply review described above.
- The load balancer security group assumes the CloudFront managed prefix list counts 55 of its 60 rules. AWS raises that list's `MaxEntries` over time, and at 60 the security group create fails.

Review the second plan after setting `runtime_secrets_ready = true`. It is the point where ECS begins running the platform.
