#!/usr/bin/env bash

set -euo pipefail

readonly TARGET_PLATFORM="linux/amd64"
readonly LOCAL_GEOPLUMB_BASE_IMAGE_NAME="geoplumb-base"
readonly OCI_TAG_PATTERN='^v[A-Za-z0-9_.-]{0,127}$'
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRASTRUCTURE_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
readonly WORKSPACE_DIRECTORY="$(cd -- "$INFRASTRUCTURE_DIRECTORY/.." && pwd)"

declare -Ar BUILD_CONTEXTS=(
  [ptolemy]="$WORKSPACE_DIRECTORY/ptolemy"
  [tiletopia]="$WORKSPACE_DIRECTORY/tiletopia"
  [geokode]="$WORKSPACE_DIRECTORY/geokode"
  [itinera]="$WORKSPACE_DIRECTORY/itinera"
  [interiora]="$WORKSPACE_DIRECTORY/interiora"
  [fenestra]="$WORKSPACE_DIRECTORY/fenestra"
  [agora]="$WORKSPACE_DIRECTORY/agora"
  [sibyl]="$WORKSPACE_DIRECTORY/sibyl"
  [geodukt]="$WORKSPACE_DIRECTORY/geodukt"
  [geolang-api]="$WORKSPACE_DIRECTORY/geolang"
  [viewtopia]="$WORKSPACE_DIRECTORY/viewtopia"
  [platform-proxy]="$INFRASTRUCTURE_DIRECTORY/containers/platform-proxy"
)

print_usage() {
  printf '%s\n' "usage: $(basename -- "$0") <immutable-tag>" >&2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

for required_command in terraform jq aws docker
do
  if ! command -v "$required_command" >/dev/null 2>&1
  then
    fail "required command not found: $required_command"
  fi
done

if [[ $# -ne 1 ]]
then
  print_usage
  exit 1
fi

readonly IMAGE_TAG="$1"

if [[ ! "$IMAGE_TAG" =~ $OCI_TAG_PATTERN ]]
then
  fail "image tag must be a valid OCI tag beginning with v: $IMAGE_TAG"
fi

cd -- "$INFRASTRUCTURE_DIRECTORY"
readonly REPOSITORIES_JSON="$(terraform output -json ecr_repositories)"

if ! REPOSITORY_ENTRIES_JSON="$(jq -ce '
  . as $repositories
  | if (($repositories | type) == "object") and (($repositories | [.[] | select(type != "string")] | length) == 0) then
      $repositories | [to_entries[] | [.key, .value]]
    else
      error("ecr_repositories must be a map of strings")
    end
' <<<"$REPOSITORIES_JSON")"
then
  fail "could not parse Terraform ecr_repositories output"
fi

if [[ "$REPOSITORY_ENTRIES_JSON" == "[]" ]]
then
  printf '%s\n' "no ECR repositories are enabled"
  exit 0
fi

if ! REPOSITORY_ENTRIES="$(jq -er '.[] | @tsv' <<<"$REPOSITORY_ENTRIES_JSON")"
then
  fail "could not parse Terraform ecr_repositories entries"
fi

declare -a REPOSITORY_KEYS=()
declare -A REPOSITORY_NAMES=()
declare -A IMAGE_REFERENCES=()

ECR_REGISTRY=""
AWS_REGION=""

while IFS=$'\t' read -r repository_key repository_url
do
  if [[ -z "${BUILD_CONTEXTS[$repository_key]+present}" && "$repository_key" != "geoplumb" ]]
  then
    fail "unknown Terraform ECR repository key: $repository_key"
  fi

  if [[ ! "$repository_url" =~ ^([0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com)/(.+)$ ]]
  then
    fail "invalid ECR repository URL for $repository_key: $repository_url"
  fi

  repository_registry="${BASH_REMATCH[1]}"
  repository_region="${BASH_REMATCH[2]}"
  repository_name="${BASH_REMATCH[3]}"

  if [[ -z "$ECR_REGISTRY" ]]
  then
    ECR_REGISTRY="$repository_registry"
    AWS_REGION="$repository_region"
  elif [[ "$repository_registry" != "$ECR_REGISTRY" ]]
  then
    fail "all ECR repository URLs must use the same registry"
  fi

  REPOSITORY_KEYS+=("$repository_key")
  REPOSITORY_NAMES["$repository_key"]="$repository_name"
  IMAGE_REFERENCES["$repository_key"]="$repository_url:$IMAGE_TAG"
done <<<"$REPOSITORY_ENTRIES"

for repository_key in "${REPOSITORY_KEYS[@]}"
do
  if ! matching_image_ids_json="$(aws ecr list-images \
    --repository-name "${REPOSITORY_NAMES[$repository_key]}" \
    --filter tagStatus=TAGGED \
    --query "imageIds[?imageTag=='$IMAGE_TAG']" \
    --output json \
    --region "$AWS_REGION")"
  then
    fail "could not check ECR tag for $repository_key"
  fi

  if ! existing_image_count="$(jq -er 'if type == "array" then length else error("expected image ID array") end' <<<"$matching_image_ids_json")"
  then
    fail "could not read ECR tag lookup for $repository_key"
  fi

  if [[ "$existing_image_count" != "0" ]]
  then
    fail "ECR repository $repository_key already has tag $IMAGE_TAG"
  fi
done

for repository_key in "${REPOSITORY_KEYS[@]}"
do
  image_reference="${IMAGE_REFERENCES[$repository_key]}"

  if [[ "$repository_key" == "geoplumb" ]]
  then
    local_geoplumb_base_image="$LOCAL_GEOPLUMB_BASE_IMAGE_NAME:$IMAGE_TAG"
    docker buildx build \
      --platform "$TARGET_PLATFORM" \
      --load \
      --tag "$local_geoplumb_base_image" \
      "$WORKSPACE_DIRECTORY/geoplumb"
    docker buildx build \
      --platform "$TARGET_PLATFORM" \
      --load \
      --build-arg "GEOPLUMB_BASE_IMAGE=$local_geoplumb_base_image" \
      --tag "$image_reference" \
      "$INFRASTRUCTURE_DIRECTORY/containers/geoplumb"
    continue
  fi

  docker buildx build \
    --platform "$TARGET_PLATFORM" \
    --load \
    --tag "$image_reference" \
    "${BUILD_CONTEXTS[$repository_key]}"
done

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for repository_key in "${REPOSITORY_KEYS[@]}"
do
  docker push "${IMAGE_REFERENCES[$repository_key]}"
done
