# GeoLang AWS infrastructure

Terraform for the GeoLang platform on AWS: ECS Fargate services behind CloudFront and one Application Load Balancer, with an Aurora Serverless v2 PostgreSQL cluster. `profiles/platform.tfvars` runs every service in viewtopia's `docker-compose.platform.yml` except Collecta and the aavaaz speech service. `profiles/preview.tfvars` is the smaller hosted subset, and `profiles/minimal.tfvars` runs four tasks with no database.

The preview profile runs in us-east-1 and serves at the CloudFront hostname in `terraform output platform_url`. The platform and minimal profiles have never been applied, so their sequences below are written from the configuration rather than from a run.

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

## Hosted preview

`profiles/preview.tfvars` runs nine services: Ptolemy, TileTopia, Agora, Sibyl, geodukt, the GeoLang API and executor, ViewTopia, and the platform proxy. It leaves out Geokode, Itinera, Interiora, geoplumb, Fenestra, and Jupyter, and turns off DNS, the bastion, WAF, GuardDuty and VPC flow logs, backups, autoscaling, and Container Insights.

The preview has no domain, so it sets `allow_cleartext_origin = true` and CloudFront reaches the load balancer over plain HTTP, Authorization headers and session cookies included.

Six services pull ghcr images named with their tags in `container_images`: Ptolemy, TileTopia, Agora, Sibyl, geodukt, and `geolang` for both the GeoLang API and the executor. A service named in `container_images` gets no ECR repository, so the preview creates two repositories, ViewTopia and the platform proxy, and `publish-images.sh` builds only those two from the sibling checkouts. ViewTopia is built into ECR because the Carto API key is a build argument and viewtopia's release workflow builds the ghcr image without one.

The GeoLang executor takes 2048 CPU units and 8192 MiB, which covers the two tool runs it allows at once at 3072 MiB each. Its task definition sets all three limits instead of leaving them to the image: `GEOLANG_TOOL_MEMORY_LIMIT_MB` 3072, `GEOLANG_TOOL_MAX_CONCURRENT` 2, and `GEOLANG_TOOL_TIMEOUT_SECONDS` 840.

Three settings cut the running cost. Tasks run on Fargate Spot with `use_fargate_spot`. They sit in the public subnets with a public IP each, so there is no NAT gateway. The Aurora cluster scales to zero.

CloudFront sends requests to an Application Load Balancer. The load balancer has one catch-all target, the platform proxy. The proxy resolves private ECS services through Cloud Map. Its rewrites are close to `viewtopia/deploy/nginx-platform.conf` but not identical, so use the routing list below as the contract rather than the compose config.

Two differences matter. The compose nginx routes `/collecta/*` to Collecta and `/speech/*` to the aavaaz speech service. Terraform deploys neither, so the hosted proxy returns 501 for `/collecta`, `/speech`, and everything under them. In the other direction the Caddyfile sends `/api/v1/assets`, `/api/v1/terrain/*`, and `/api/v1/catalog*` to TileTopia where nginx sends them to Ptolemy.

The proxy image is built from [containers/platform-proxy](containers/platform-proxy). Its Caddy image is pinned to `caddy:2.11.4-alpine`.

The Jupyter image is pinned to `quay.io/jupyter/scipy-notebook:2025-12-31` by `jupyter_image`. Jupyter keeps the `/jupyter` prefix so its kernel WebSocket URLs work through CloudFront and the proxy.

## Databases and storage

Ptolemy and Agora share one encrypted Aurora PostgreSQL 17.10 cluster with a single `db.serverless` writer. The cluster holds two databases, `ptolemy` and `agora`. Ptolemy connects with the RDS-managed master credential, which RDS keeps in Secrets Manager. Agora connects as an `agora` login role that owns the `agora` database, so its migrations create schema without the master password. Ptolemy enables its required PostGIS extensions during its own migrations.

`serverlessv2_scaling_configuration` runs from 0 to `db_max_capacity` ACUs and pauses the cluster after 300 seconds without a connection. Pausing only happens while the tasks are scaled to zero. Ptolemy's delivery worker polls every 5 seconds and Agora's watch scheduler every 30, so one running task of either keeps the cluster awake. Ptolemy's ECS health check uses `/api/v1/healthz` rather than `/api/v1/readyz` for the same reason. `readyz` runs `SELECT 1`, and the check fires every 30 seconds.

The cluster parameter group sets `rds.force_ssl`, so a plaintext connection is refused. The `ptolemy_database_url` and `agora_database_url` secret values must end in `?sslmode=verify-full&sslrootcert=/etc/ssl/rds-global-bundle.pem`. Ptolemy and Agora both build sqlx with the `tls-rustls-ring` backend.

Do not use `sslmode=require` here. Under `require`, sqlx installs a certificate verifier that accepts any certificate and ignores `sslrootcert`, so the connection is encrypted but the server is never authenticated and anything answering in the database's place can read and rewrite the session. Only `verify-ca` and `verify-full` check the chain.

The URL must name the RDS endpoint directly, since a CNAME in front of it fails hostname verification. Each service image fetches the AWS RDS global CA bundle to the path above during its build.

Terraform creates neither the `agora` database nor the `agora` role, because that would put a database administrator credential in configuration and state. The refresh Lambda creates both through the RDS Data API, which the cluster exposes with `enable_http_endpoint`.

The username in `agora_database_url` tells the Lambda what to do. When it already reads `agora`, the Lambda makes no Data API call at all. That matters because any such call resumes a paused cluster, and the schedule runs every 15 minutes. When the secret is empty or its username is still the master user, the Lambda:

1. generates a 32-byte password
2. creates the `agora` role with it, or resets the password of an existing one
3. grants the master user inheriting membership in that role, which `REASSIGN OWNED` needs
4. creates the database owned by that role, or hands an existing database over with `ALTER DATABASE ... OWNER TO`
5. runs `REASSIGN OWNED` inside it, so tables Agora's migrations created as the master user become the role's
6. writes the URL and forces one Agora deployment

Every rerun takes the same path until the write lands, so a failure part way through only costs a repeat.

It refuses any database, role, or master user name outside `^[a-z_][a-z0-9_]*$`. The password reaches the `agora_database_url` secret and nothing else. It is not in Terraform configuration or state, not in a process argument, not in a log, and not in CloudTrail, which records `sql` as `**********` for Data API calls.

To test a rotation end to end, force one and watch both services come back. The managed secret takes a minute or two to hold the new password, and the Lambda's schedule would pick it up within 15 minutes anyway, so the invoke below only saves the wait. It runs for as long as the ECS deployment takes:

```bash
aws rds modify-db-cluster --profile geolang --db-cluster-identifier geolang-prod-postgis \
  --rotate-master-user-password --apply-immediately

aws lambda invoke --profile geolang --cli-read-timeout 0 \
  --function-name geolang-prod-database-secret-refresh /dev/stdout

aws ecs wait services-stable --profile geolang --cluster geolang-prod \
  --services geolang-prod-ptolemy geolang-prod-agora

curl -si https://d2dkw27j378mpo.cloudfront.net/api/v1/healthz | head -1
curl -si https://d2dkw27j378mpo.cloudfront.net/agora/health | head -1
```

The invoke prints one entry per target. Ptolemy's reads `"changed": true` and Agora's reads `"changed": false`, because only Ptolemy's URL carries the master password. A `false` for Ptolemy means the rotation has not reached the managed secret yet, so invoke again. Both health routes answer `200`.

EFS access points provide persistent storage for:

- TileTopia data
- Itinera spatial source data
- Interiora venue data
- geoplumb's disk cache
- Fenestra coverages
- Sibyl's SQLite database
- GeoLang's cache
- GeoLang Natural Earth reference data at `/app/geolang/natural_earth`, read-write in the API and read-only in the executor
- GeoLang outputs, user data, and live data shared with geodukt and the executor
- Jupyter notebooks under `/home/jovyan/work`

Itinera writes or reads `graph.bin` in the spatial data access point. Place any Fenestra GeoTIFF coverages in its access point. GeoLang downloads Natural Earth data on demand into its own directory, so its access point needs nothing staged. The executor's read-only mount needs a geolang image whose Natural Earth download falls back to the caller's own directory when the shared one is read-only.

The file system policy denies every client that connects without an access point or without TLS. It allows nothing itself, so a client without IAM credentials is refused. Every task mounts with its task role, and each role holds `ClientMount` on the access points its services mount and `ClientWrite` on the ones they mount read-write, never `ClientRootAccess`. The executor and Jupyter each have their own role, so code that escapes either sandbox can reach only that service's access points. The other services share one role. To stage files, mount one access point with `mount -t efs -o tls,iam,accesspoint=<access point id> <file system id> /mnt`, using credentials that hold `ClientWrite` on it. A plain NFS mount of the file system root is refused.

A stack that already runs EFS-backed tasks without IAM mounts has to roll them before the policy lands, or their mounts are refused. The policy depends on the ECS module, but `aws_ecs_service` returns before its deployment finishes, so apply in two steps. The waiter takes at most ten services per call.

```bash
terraform apply -var-file=profiles/preview.tfvars -target=module.ecs
aws ecs wait services-stable --cluster "$(terraform output -raw ecs_cluster)" --services <EFS-backed service names> --profile geolang
terraform apply -var-file=profiles/preview.tfvars
```

geoplumb serves the public STAC layers in [containers/geoplumb/layers.toml](containers/geoplumb/layers.toml), a Copernicus DEM hillshade and a Sentinel-2 NDVI, copied into its wrapper image. The configuration has no credentials. The image is built in two steps so the configuration is part of an immutable image.

## Geokode index

Geokode serves an index directory built by `geokode build`, about 6.5 GB for the planet. The index sits in the tiles bucket under `geokode-index/<geokode_index_version>/`. Each geokode task starts with an init container on `public.ecr.aws/aws-cli/aws-cli:2.37.1` that copies that folder into a task-local volume. Geokode starts only once the copy exits 0, mounts the volume read-only at `/index`, and memory-maps it. The task has 30 GiB of ephemeral storage for the index and both images. Every task start copies the whole index, so after a wake or the morning scale-up geokode answers later than the other services.

The copy uses the shared task role. Its `s3-access` policy already grants read, write, and delete on every `geolang-prod-*` bucket, so every service on that role can read the index and can also overwrite it.

To serve a new index on the preview:

1. On the build machine, run `geokode build --pbf planet.osm.pbf --out planet-index`.
2. Apply once with `enable_s3_tiles = true` so the tiles bucket exists. The preview profile sets it.
3. Run `./scripts/publish-geokode-index.sh planet-index <version>`. It reads `geokode_index_url` from Terraform state, uploads every file but `meta.json`, then uploads `meta.json`. It takes no `--profile` flag, so export `AWS_PROFILE=geolang` first.
4. Tag a geokode release and set `geokode = "ghcr.io/geolang/geokode:<tag>"` in `container_images`. Without that entry the preview creates a geokode ECR repository instead, and the service cannot start until `publish-images.sh` pushes the image under a new `image_tag`.
5. Set `geokode_index_version = "<version>"` and `enable_geokode = true` in `profiles/preview.tfvars`.
6. Review `terraform plan -var-file=profiles/preview.tfvars`, then apply it. The apply also rolls the platform proxy, the GeoLang API, and the executor, since their environments gain the geokode route and address.

Validation rejects `enable_geokode = true` with an empty `geokode_index_version` or with `enable_s3_tiles = false`. Publish each build under a new version. The bucket keeps versioning on, so republishing a version keeps the replaced objects as noncurrent versions.

## Runtime secrets

No credential belongs in a Terraform value, checked-in file, image command, or process argument. ECS injects runtime values from AWS Secrets Manager or SSM Parameter Store.

When `enable_secrets` is true, Terraform creates the empty Secrets Manager resources needed by the enabled services. The full profile uses these keys:

- `platform_jwt`, shared by the platform JWT issuers and validators
- `ptolemy_database_url`, the complete Ptolemy PostgreSQL URL
- `agora_database_url`, the complete Agora PostgreSQL URL
- `geolang_executor`, shared only by the GeoLang API and executor
- `llm_api_key`, exposed to Sibyl as `SIBYL_CLOUD_API_KEY`
- `jupyter_token`, exposed to Jupyter as `JUPYTER_TOKEN`

Terraform creates no secret versions. Populate the four operator-managed values after the first infrastructure apply. Each command reads the value from a silent prompt or standard input, writes it through a mode 600 temporary file, and removes that file on exit. The script takes no `--profile` flag, so export `AWS_PROFILE` first:

```bash
./scripts/put-runtime-secret.sh platform_jwt
./scripts/put-runtime-secret.sh geolang_executor
./scripts/put-runtime-secret.sh llm_api_key
./scripts/put-runtime-secret.sh jupyter_token
```

Do not use this command for the two database URLs. When `enable_database_secret_refresh` is true, Terraform deploys a Python 3.13 Lambda and an EventBridge schedule for those values. Every 15 minutes it reads the RDS-managed credentials, builds Ptolemy's verified direct-endpoint URL, updates the secret if it changed, forces Ptolemy's ECS service to deploy new tasks, and waits for the service to stabilize. A failed ECS update restores the previous secret version so the next schedule retries. No password enters Terraform configuration, state, process arguments, or logs.

The first scheduled run creates the `agora` role and database and writes both URL secret versions. From then on the Lambda only rewrites Ptolemy's URL. RDS rotates the managed master password every seven days by default, so new Ptolemy connections can fail between a rotation and the next run. Agora's URL keeps the `agora` role's password, which no rotation touches, so a master rotation does not redeploy Agora.

Existing secret resources can be supplied through `runtime_secret_arns`. Keys in that map override Terraform-managed secret ARNs. The two database URL targets must be full Secrets Manager ARNs when automatic refresh is enabled. Other runtime values may use Secrets Manager or SSM. If an existing secret uses a customer managed KMS key, grant the ECS execution role permission to decrypt it. The refresh Lambda has no wildcard KMS permission, so a customer managed key for either database secret needs an explicit policy change before use.

`runtime_secrets_ready = true` is an operator assertion. Terraform verifies that an ARN exists for every secret required by the enabled services. Terraform cannot verify that an externally populated secret contains a usable value. Leave the flag false until all image, data, and secret inputs are ready. This keeps empty managed secrets and empty ECR repositories from causing ECS restart loops.

There is no deployment-time place to configure the Jupyter token for ViewTopia. ViewTopia keeps it in per-browser `localStorage` with a hardcoded default of `viewtopia-local`, so every user pastes the deployed token into notebook settings by hand. Do not put the token in a frontend build argument.

One token also means one shared credential to a server that runs arbitrary code as whoever holds it. Anyone given the token has the same access as everyone else, and revoking it means rotating the secret and telling every user to paste a new one.

Sibyl's model endpoint is two plain variables next to that key. `llm_api_base` becomes `SIBYL_CLOUD_API_BASE` and `llm_models` becomes `SIBYL_CLOUD_MODELS`, and each is left off the task when empty. The preview profile points at the Bedrock mantle endpoint, `https://bedrock-mantle.us-east-1.api.aws/v1`, which serves `GET /models`, streams, and returns `tool_calls`. The `bedrock-runtime` OpenAI path refuses this account on a daily token quota. Only the key itself is a secret.

That key is a long-term Bedrock credential on the IAM user `geolang-sibyl-bedrock`, and it expires on 2027-09-19. Nothing rotates it. Create a replacement before that date, put it with `./scripts/put-runtime-secret.sh llm_api_key`, and force a new Sibyl deployment, since a task reads the secret only at start. `aws iam list-service-specific-credentials --user-name geolang-sibyl-bedrock --profile geolang` prints the expiry.

### Monthly spend cap

Two limits hold the preview to 100 USD a month. `llm_monthly_spend_limit_usd` and `llm_model_prices` become `SIBYL_MONTHLY_SPEND_LIMIT_USD` and `SIBYL_MODEL_PRICES`, and Sibyl refuses model calls once that many dollars are spent in a UTC month. The preview sets 50, and every model in `llm_models` needs a price. Take prices from the AWS price list:

```bash
aws pricing get-products --region us-east-1 --service-code AmazonBedrock --filters Type=TERM_MATCH,Field=regionCode,Value=us-east-1 --profile geolang
```

`monthly_spend_budget_usd` creates an AWS cost budget that leaves credits out. It emails at 80 percent, and at 100 percent it attaches a deny on `bedrock:*` and `bedrock-mantle:*` to `bedrock_api_key_user`, which stops every Sibyl model call. Budgets data arrives 8 to 12 hours late, so spend overshoots before the deny lands. The deny leaves ECS, RDS and EFS running. It stays on until someone detaches it, either in the Budgets console or with `aws iam detach-user-policy --user-name geolang-sibyl-bedrock --policy-arn <deny-model-calls arn> --profile geolang`.

Both alerts go to the `spend_cap_topic_arn` output. Subscribe once after the first apply, then confirm the email:

```bash
aws sns subscribe --topic-arn "$(terraform output -raw spend_cap_topic_arn)" --protocol email --notification-endpoint <you@example.com> --profile geolang
```

`geolang_limits` is a map of `GEOLANG_*` names to whole numbers, each passed to geolang-api as an environment variable and left off when 0. The names and their meaning are in the geolang README. The preview caps uploads at 51 MB a request, 50 MB a file, a zip at 100 entries and 200 MB unzipped, and a day at 300 files or 2048 MB overall and 20 files or 200 MB per caller. It caps tool runs at 1200 a day per caller and 10000 overall, one at a time per caller, tool outputs at 500 MB a day per caller, and deletes uploads after 30 days.

`ptolemy_limits` and `tiletopia_limits` are maps of `PTOLEMY_MAX_*` and `TILETOPIA_*` names passed to those services, with their meaning in each repo's README. The preview gives a user 5 workspaces, 20 projects and 200 attachments totalling 200 MB in ptolemy. tiletopia closes public signup at 500 accounts or 30 signups an hour, and locks an account for 15 minutes after 5 failed logins.

`llm_locked_profile` becomes `SIBYL_LOCKED_PROFILE`, so every run uses that model and nobody can switch. `sibyl_limits` is a map of `SIBYL_*` per-user daily limits passed to Sibyl by name, stored in sibyl.db so restarts keep them. The preview locks `cloud:openai.gpt-oss-120b` and allows a user 40 runs and 2 million tokens a day, and an admin, for eval sweeps, 500 runs and 50 million tokens.

## Image build map

Terraform creates ECR repositories but does not build or push images. Use the repository URLs from `terraform output -json ecr_repositories`.

Repository tags are immutable. A repository rejects a push to a tag it already holds, so every build needs its own tag and there is no moving `latest`. Every ECR service deploys the tag in `image_tag`, which defaults to `v0.1.0`. Push the new tag, then change `image_tag` to roll the platform. The repository lifecycle policy keeps the last ten tags beginning with `v`.

After the first infrastructure apply creates the repositories, publish every enabled image from the sibling checkouts with one tag:

```bash
./scripts/publish-images.sh v0.1.0
```

The command reads `ecr_repositories` from Terraform state, rejects any tag that already exists, builds every image for Linux x86_64, then logs in and pushes only after all builds pass. Export `VITE_CARTO_API_KEY` first. The ViewTopia build bakes it in, and without it the 2D tab's Carto basemaps carry an "API KEY REQUIRED" watermark. Like `put-runtime-secret.sh`, it takes no `--profile` flag. It requires Terraform, the AWS CLI, Docker Buildx, and jq. The tag passed here must also be the Terraform `image_tag` used for the readiness apply.

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

The platform profile creates thirteen ECR repositories. The table lists twelve, and geoplumb is the thirteenth. Both the GeoLang API and the GeoLang executor deploy from `geolang-api`, so it is one build and one push for two services. Every service named in `container_images` is skipped, which is how the preview profile comes down to two repositories.

The publication command builds the geoplumb base from `../geoplumb` first, then builds its wrapper from `containers/geoplumb` on that local base image.

The GeoLang image contains `src/` and uses a deny-first `.dockerignore` so local runtime data and secret files do not enter the build context.

Jupyter pulls its pinned Quay image directly and has no ECR repository.

## Deployment sequence

State lives in the `geolang-terraform-state-000152811496` bucket in us-west-2 under `infrastructure/terraform.tfstate`, locked with `use_lockfile` rather than a DynamoDB table, which needs Terraform 1.10 or newer. The bucket's region is independent of the region a profile deploys to.

Copy the example and choose a profile:

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -var-file=profiles/preview.tfvars
```

The first apply must keep `runtime_secrets_ready = false`. It creates the network, the database cluster, EFS access points, ECR repositories, secret containers, task definitions, and zero-count ECS services. `profiles/preview.tfvars` sets the flag to `true` because the preview is running, so set it to `false` for a fresh deployment from that profile.

On the platform profile the load balancer security group needs the certificate ARN, the certificate needs ACM validation, and validation needs the domain's nameservers delegated at the registrar. Set `existing_hosted_zone_id` to a zone that is already delegated and one apply completes, because validation records go into a zone the registrar already points at.

Without it, the apply creates the zone that publishes those nameservers, so delegation cannot exist yet and the load balancer, every ECS service, and every target group cannot be created. The sequence is then:

1. Apply once. ACM validation eventually times out and the apply fails part way. Everything that does not depend on the certificate is created, including the Route53 zone.
2. Read `terraform output name_servers`.
3. Set those nameservers at the domain registrar and wait for the delegation to propagate.
4. Apply again. Validation completes and the load balancer, target groups, and zero-count services are created.

After the apply that creates the load balancer:

1. Run `./scripts/publish-images.sh <image_tag>` to build and push every enabled ECR image.
2. Stage the required files in EFS through their access points.
3. Populate the operator-managed runtime secrets and wait for the database refresh job to create the `agora` role and database and both URL secret versions.
4. On a profile that runs Jupyter, give the Jupyter token to the people who need notebooks. Each user pastes it into ViewTopia's notebook settings in their own browser.
5. Set `runtime_secrets_ready = true`.
6. Review a new plan before applying it.

Terraform outputs the cluster endpoint, its managed credential secret ARN, runtime secret ARNs, ECR repositories, and EFS access points needed for those steps.

Do not use `terraform apply -auto-approve` for the readiness transition. A normal plan shows the service scale-up before it changes AWS.

## Redeploying a service after a change

Which path a service takes depends on where its image comes from.

The six ghcr services (Ptolemy, TileTopia, Agora, Sibyl, geodukt, and the GeoLang API and executor from the geolang repo) get a new image from a tag push on their own repo. Each repo's `release.yml` workflow, `docker.yml` in ptolemy, builds and pushes `ghcr.io/geolang/<repo>:<tag>` on any `v*` tag:

```bash
git -C ../ptolemy tag v0.2.2
git -C ../ptolemy push origin v0.2.2
```

Wait for the workflow to finish, set the new tag on that service in `container_images` in `profiles/preview.tfvars`, then apply:

```bash
terraform apply -var-file=profiles/preview.tfvars
```

ViewTopia and the platform proxy are built into ECR by `publish-images.sh`. Export `VITE_CARTO_API_KEY`, publish under a tag no repository holds yet, set `image_tag` to it, then apply:

```bash
export VITE_CARTO_API_KEY=...
./scripts/publish-images.sh v0.1.6
terraform apply -var-file=profiles/preview.tfvars
```

`image_tag` is one value for both ECR images, so publishing rolls both even when only one changed. Either apply replaces the task definition and ECS rolls the service. Do not apply near 23:00 America/Toronto. The nightly scale-down fires on schedule even with a rollout in flight.

## Scaling the preview up and down

Once the services are running, the cost of an idle stack is the load balancer, the CloudFront distribution, EFS, and whatever the tasks use. `scripts/platform-scale.sh` sets every service on the cluster to a desired count of 0 or 1 without a Terraform run:

```bash
./scripts/platform-scale.sh down --profile geolang
./scripts/platform-scale.sh up --profile geolang
```

It reads the cluster name from `terraform output -raw ecs_cluster`, lists the cluster's services, and prints one line per service. It accepts nothing but `up`, `down`, and an optional `--profile`.

`nightly_scale_down` does the down half on a schedule. Set a timezone and an hour and each service gets an EventBridge schedule that calls `ecs:UpdateService` with a desired count of 0 at that local hour. The preview profile uses 23:00 America/Toronto. The tasks stop, the cluster pauses five minutes later, and `platform-scale.sh up` or a Terraform apply brings both back.

A second schedule per service does the up half at `morning_scale_up_hour` in the same timezone, 08:00 by default, so the preview runs from 08:00 to 23:00 Toronto time. It sets the desired count Terraform gives the service, which is 0 while `runtime_secrets_ready` is false. The morning schedule also undoes a manual scale-down, so before an absence set `nightly_scale_down = null` and apply to drop both schedules.

## Demo landing page

`enable_demo_landing_page` serves a static page at `/try/` on the CloudFront hostname, so it answers while every task is stopped. The preview turns it on, and `terraform output demo_landing_page_url` prints the address. The path is `/try` because viewtopia already serves files under `/demo`.

The page is the three files in [demo-landing-page](demo-landing-page). Terraform uploads them to a private S3 bucket, `geolang-demo-landing-page-prod`, along with a generated `config.json` that holds the wake URL and the hours. CloudFront reads the bucket through an origin access control. A CloudFront Function redirects `/try` to `/try/` and serves `index.html` for `/try/`. CloudFront caches the page for five minutes, so an edit shows up within five minutes of the apply that uploads it.

The flag needs `enable_cdn`, `enable_geolang`, and `nightly_scale_down`.

### Waking the stack

1. The start button copies the prompt to the clipboard and sends a POST to the `geolang-prod-demo-wake` function URL.
2. The function adds one data point to the `DemoActivity` metric in the `GeoLang/geolang-prod` namespace, then sets every service to the desired count Terraform gives it. That is the same `ecs:UpdateService` call `platform-scale.sh up` makes.
3. The page requests `/health`, `/agent/health`, and `/` every ten seconds. When all three answer 200 it opens the viewer. The start takes two to three minutes and the page gives up after ten.

The function URL takes no authentication, so anyone who reads `config.json` can start the stack. Its CORS setting admits only the platform origin, which stops other sites calling it from a browser but not a script.

The function runs one call at a time (`reserved_concurrent_executions = 1`), so a script calling it in a loop cannot take the Lambda slots the idle scale-down and the secret refresh need. Lambda always leaves 100 units unreserved, and a new account's limit is 10, so the apply fails until the quota is raised:

```bash
aws service-quotas request-service-quota-increase --service-code lambda --quota-code L-B99A9384 --desired-value 1000 --region us-east-1 --profile geolang
```

### Idle scale-down

A CloudWatch Logs metric filter on the geolang-api log group adds one to `DemoActivity` for each uvicorn access log line containing `POST /chat/agui`. geolang-api's log is the one place the stack already records chat runs. The Caddy proxy writes no access log, and the load balancer has access logs off and no per-path metric.

Every five minutes outside the demo hours, an EventBridge schedule invokes `geolang-prod-demo-idle-scale-down`. When `DemoActivity` sums to zero over the last thirty minutes, the function sets every service to 0. The wake press counts as activity, so a stack that is still starting is not stopped. The schedule never runs between `morning_scale_up_hour` and `nightly_scale_down.hour`, 08:00 to 23:00 Toronto time on the preview, so it cannot undo the morning scale-up.

To run the idle check by hand, which stops the stack if nothing has happened in the last thirty minutes:

```bash
aws lambda invoke --profile geolang \
  --function-name geolang-prod-demo-idle-scale-down /dev/stdout
```

It prints the activity sum and whether it scaled down.

A browser that has opened the viewer before gets the viewer instead of the landing page at `/try/`, because viewtopia's service worker answers every navigation outside the backend prefixes in its `navigateFallbackDenylist`.

## Routing

The proxy preserves or strips paths according to the current platform compose contract:

- `/agent/*` to GeoLang API with `/agent` removed
- `/api/v1/realtime/*` to TileTopia with the path preserved
- `/tiles/*` to TileTopia as `/api/*`
- `/martin/*` to TileTopia with the path preserved, for vector tile archives
- `/ogc/*` to Fenestra with `/ogc` removed
- `/api/delivery/*`, `/api/route`, `/api/isochrone`, and `/api/network/*` to Itinera with `/api` removed
- `/api/pipeline/runs*` to geodukt as `/runs*`
- `/api/indoor/*` to Interiora with the full prefix removed
- `/agora/*` to Agora with `/agora` removed
- `/plumb/*` to geoplumb with `/plumb` removed
- `/api/geocode/*` to Geokode with the prefix removed
- `/api/v1/auth/oidc/*`, remaining `/api/*`, and `/ws/*` to Ptolemy
- TileTopia auth, portal, assets, terrain, and catalog paths to TileTopia
- `/jupyter/*` to Jupyter with the path preserved
- `/collecta`, `/collecta/*`, `/speech`, and `/speech/*` to the undeployed-service 501 response. The Caddyfile has aavaaz handles for `/speech/*` behind `ENABLE_AAVAAZ`, which Terraform never sets.
- `/health` to the proxy's own `ok`, which is what the load balancer target group checks
- `/metrics` to a 404 from the proxy, so no service's Prometheus output reaches the edge
- remaining requests to ViewTopia

Every service route is gated on an `ENABLE_*` environment variable that Terraform sets from the profile's service toggles. A profile that leaves a service out answers 501 on that service's paths instead of proxying to a Cloud Map name that does not resolve. The gates default to closed, so the proxy serves a route only when the deployment names the service.

Paths under `/api` need one more step, because Ptolemy's `/api/*` catch-all would otherwise take them and answer 404. After the per-service handles, the proxy matches the Geokode, Interiora, Itinera, geodukt, and TileTopia `/api` paths again and returns 501 for any of them a closed gate left unhandled. On the preview that covers `/api/geocode/*`, `/api/indoor/*`, `/api/delivery/*`, `/api/route*`, `/api/isochrone*`, and `/api/network/*`. `/api/v1/auth/*` is left out of that second match on purpose. It goes to TileTopia when TileTopia runs and falls through to Ptolemy when it does not, since Ptolemy serves the platform's auth routes itself.

The minimal profile runs TileTopia, GeoLang API, ViewTopia, and the proxy, so its Collecta, speech, Fenestra, Agora, geoplumb, Jupyter, Geokode, Itinera, Interiora, geodukt, and Ptolemy paths all return 501. Its `/martin/*` paths reach TileTopia along with the rest of its tile paths. When Ptolemy runs and TileTopia does not, TileTopia's portal, assets, terrain, catalog, and realtime paths answer 501.

CloudFront has zero-cache behaviors for the TileTopia, Ptolemy, Agora, and Jupyter WebSocket paths. It forwards the WebSocket subprotocol header used for bearer authentication. Static frontend assets and public immutable tile paths (`/tiles/v1/assets/*/tileset.json`, `/tiles/v1/assets/*/tiles/*`, `/tiles/v1/terrain/*`) keep long TTLs. Those are the URLs the viewer requests, and the proxy rewrites them to TileTopia after CloudFront.

When `enable_cdn` is true, the load balancer admits only the AWS-managed `com.amazonaws.global.cloudfront.origin-facing` prefix list, so the CDN cannot be bypassed by calling the load balancer name directly. That list admits every CloudFront distribution in every account, so CloudFront also sends an `X-Origin-Verify` header with a random value Terraform generates and keeps in state, and the listener rule forwards to the proxy only when the header matches. A request without it gets the listener default response. Target health checks go from the load balancer to the tasks directly and do not need the header. That prefix list counts as 55 of a security group's 60 rules, which leaves room for one port. The admitted port is 443 when a domain is configured, because CloudFront then reaches the origin over HTTPS, and 80 otherwise. Without a CDN the load balancer is the only way in and stays open.

The port 80 case is what `enable_cdn = true` with no domain gives you: `origin_protocol_policy = "http-only"`, so every request CloudFront forwards crosses the public internet to the load balancer in cleartext, Authorization headers and session cookies included. A precondition on the CloudFront distribution stops the plan for that combination unless an origin hostname is configured. The error names the two ways out: set `domain_name` with `enable_dns`, or set `allow_cleartext_origin = true` to accept the cleartext hop.

## Task network isolation

ECS tasks are placed in four security groups, plus a fifth the platform proxy and the GeoLang API carry as a second group.

Most services share one group that reaches every other service, the database cluster, and the internet. On the platform profile that group holds twelve tasks: Ptolemy, TileTopia, Geokode, Itinera, Interiora, geoplumb, Fenestra, Sibyl, geodukt, ViewTopia, the platform proxy, and the GeoLang API. The cluster admits 5432 from that group and from Agora's, and from nothing else.

Tasks carry a public IP because there is no NAT gateway. That changes no inbound rule. The shared group admits only the load balancer and the groups named here, and the two user-code groups admit only what the paragraphs below describe.

Agora has its own group because it listens on the same port the executor's tool calls use. Its one ingress rule admits port 3000 from the session callers group. That group has no ingress rules of its own, and only the platform proxy and the GeoLang API carry it, each alongside the shared group. The other ten tasks in the shared group cannot open a connection to Agora, and neither can the GeoLang executor or Jupyter, the two tasks running user-supplied code.

Agora also authenticates its own requests. Every route needs a token except `/health`, share-link resolution, and attachment reads, and those last two carry per-document capability tokens.

The GeoLang executor has a group whose egress is limited to its tool call targets, DNS, EFS, and outbound HTTPS. Jupyter has a fourth group with no tool call egress at all, since notebooks call no platform service. Both of those run user-supplied code, and each has its own task role that holds only EFS client grants for that service's access points.

## Bastion, firewall, and backups

The platform profile turns on three things the sections above do not cover.

`enable_bastion` puts a `bastion_instance_type` Amazon Linux 2023 instance in a public subnet with the SSM managed instance policy, IMDSv2 only, and an encrypted root volume. It opens no SSH port unless `bastion_allowed_cidrs` names a CIDR. Its security group is admitted to the database cluster on 5432, next to the shared task group and Agora's. `terraform output bastion_ssm_command` prints the session command. `bastion_db_tunnel_command` prints a ready-to-run `AWS-StartPortForwardingSessionToRemoteHost` command whose `host` parameter is the database hostname. It forwards local port 5432 to the database, so it prints `Bastion or database disabled` unless both `enable_bastion` and `enable_database` are true.

`enable_waf` creates a regional web ACL, attaches it to the load balancer, and logs to the `aws-waf-logs-geolang-prod` CloudWatch group for 30 days. It default-allows and adds a rate limit of `waf_rate_limit` requests per five minutes, the AWS common, known bad inputs, SQL injection, and Linux managed rule groups, and a country block when `waf_blocked_countries` is set. The common rule set counts rather than blocks `SizeRestrictions_BODY` and `CrossSiteScripting_BODY`, since large and XML-shaped geospatial payloads trip both. The rate limit aggregates on the address the load balancer sees. With `enable_cdn` set the load balancer sees a CloudFront edge, so the rule keys on the first address in `X-Forwarded-For` instead. A request whose `X-Forwarded-For` is malformed is not counted and not blocked. A client can put any address first in that header, so this rate limit does not hold against a script.

`cloudfront_rate_limits` attaches a web ACL to the CloudFront distribution instead, where the rate keys on the real client address. It blocks an address for the rest of a five-minute window once it passes `requests_per_ip` requests, or `auth_requests_per_ip` requests to any path containing `/v1/auth/` after URL decoding and path normalization, which covers signup and login under both `/api/v1/auth/` and the proxy's `/tiles/v1/auth/` rewrite. The preview sets 3000 and 20. It costs about 7 USD a month plus 0.60 USD per million requests. Both counts include cached requests, so a heavy map session has to stay under `requests_per_ip`. The `requests-per-ip` metric in CloudWatch shows blocks.

`enable_backup` creates a vault and a plan covering the database cluster and the EFS file system. A daily backup at 03:00 UTC is deleted after `backup_retention_days`, and a Sunday backup is kept three times as long. Cross-region copies are off unless `enable_cross_region_backup` is set, and the copy target is the `Default` vault in `dr_region`, which this stack does not create.

## Validation

Run the local checks without contacting AWS:

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

The GitHub workflow runs the same format and validation checks with Terraform 1.16.1, since `fmt` output tracks the toolchain version. `-backend=false` keeps that job away from the state bucket. Its manual plan job takes a profile, runs a real `terraform init`, and needs AWS credentials, both for the bucket and because `terraform plan` reads account and region data sources. It takes a long-lived access key pair from the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` repository secrets, not an OIDC role that mints a short-lived one. No runtime application credential is passed to Terraform.

The four shell commands and the two Lambda sources have their own tests, which stub the AWS CLI, Docker, Terraform, and boto3 and so contact nothing:

```bash
bash tests/test_publish_images.sh
bash tests/test_publish_geokode_index.sh
bash tests/test_put_runtime_secret.sh
bash tests/test_platform_scale.sh
python3 tests/test_refresh_database_secrets.py
python3 tests/test_demo_scaling.py
```

The workflow runs all six on every push to master and every pull request.

## Important outputs

- `platform_url`
- `demo_landing_page_url`
- `name_servers`, the hosted zone nameservers to set at the registrar between the first and second apply
- `ecr_repositories`
- `ecs_cluster`
- `database_endpoint`
- `database_master_user_secret_arn`
- `runtime_secret_arns`
- `efs_access_points`
- `geokode_index_url`
- `service_discovery_namespace`

## Monitoring and unused resources

Each service gets a CPU and a memory alarm, the database writer gets CPU and free storage alarms, and the load balancer gets a 5xx alarm. Every alarm publishes to one SNS topic. Set `alert_email` to subscribe an address to it. AWS emails a confirmation link that has to be accepted before any alarm is delivered. Left empty, the topic has no subscriber and an alarm reaches nobody. `terraform output dashboard_url` links the CloudWatch dashboard.

The tiles S3 bucket holds only the geokode index.

## Safe apply blockers

The infrastructure can be planned before these are resolved, with all services held at zero:

- The Ptolemy and Agora database URL secrets must use `sslmode=verify-full` with `sslrootcert`, or they cannot connect to a database that forces SSL.
- Every enabled ECR image must be pushed under the tag in `image_tag`.
- EFS spatial and coverage data must be staged on a profile that runs Itinera or Fenestra.
- A profile that runs Geokode needs its index published under `geokode_index_version`.
- All required secret containers must have a current value.
- DNS delegation and ACM validation must complete when the platform profile uses `geolang.com`. Until the certificate exists, that profile's plan stops on the HTTPS listener count, which cannot be resolved before apply.
- Set `enable_guardduty = false` when the account already has a detector in the deployment region. `aws_guardduty_detector` fails against an account that already has one.
- Set `existing_hosted_zone_id` when the domain already has a hosted zone. Left empty, the apply creates a second zone with different nameservers, and ACM validation never resolves because the registrar points at the old zone.
- Fargate Spot tasks are reclaimed with two minutes of warning. A preview task can disappear mid-request and come back when capacity allows.
- The load balancer security group assumes the CloudFront managed prefix list counts 55 of its 60 rules. AWS raises that list's `MaxEntries` over time, and at 60 the security group create fails.

Review the second plan after setting `runtime_secrets_ready = true`. It is the point where ECS begins running the platform.
