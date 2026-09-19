#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRASTRUCTURE_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
readonly UP_DESIRED_COUNT=1
readonly DOWN_DESIRED_COUNT=0

print_usage() {
  printf '%s\n' "usage: $(basename -- "$0") up|down [--profile <aws profile>]" >&2
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

for required_command in terraform jq aws
do
  if ! command -v "$required_command" >/dev/null 2>&1
  then
    fail "required command not found: $required_command"
  fi
done

if [[ $# -lt 1 ]]
then
  print_usage
  exit 1
fi

case "$1" in
  up)
    readonly DESIRED_COUNT="$UP_DESIRED_COUNT"
    ;;
  down)
    readonly DESIRED_COUNT="$DOWN_DESIRED_COUNT"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
shift

if [[ $# -gt 0 ]]
then
  if [[ "$1" != "--profile" || $# -ne 2 || -z "$2" ]]
  then
    print_usage
    exit 1
  fi
  export AWS_PROFILE="$2"
fi

cd -- "$INFRASTRUCTURE_DIRECTORY"

if ! CLUSTER_NAME="$(terraform output -raw ecs_cluster)"
then
  fail "could not read the ecs_cluster Terraform output"
fi

if [[ -z "$CLUSTER_NAME" ]]
then
  fail "the ecs_cluster Terraform output is empty"
fi

if ! SERVICE_ARNS_JSON="$(aws ecs list-services --cluster "$CLUSTER_NAME" --output json)"
then
  fail "could not list services on cluster $CLUSTER_NAME"
fi

if ! SERVICE_COUNT="$(jq -er '
  if (.serviceArns | type) == "array" then .serviceArns | length else error("serviceArns must be an array") end
' <<<"$SERVICE_ARNS_JSON")"
then
  fail "could not parse the service list for cluster $CLUSTER_NAME"
fi

if [[ "$SERVICE_COUNT" == "0" ]]
then
  printf '%s\n' "no services on cluster $CLUSTER_NAME"
  exit 0
fi

if ! SERVICE_ARNS="$(jq -er '.serviceArns[]' <<<"$SERVICE_ARNS_JSON")"
then
  fail "could not read the service list for cluster $CLUSTER_NAME"
fi

while IFS= read -r service_arn
do
  service_name="${service_arn##*/}"
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$service_name" \
    --desired-count "$DESIRED_COUNT" \
    --output json >/dev/null
  printf '%s\n' "$service_name desired-count $DESIRED_COUNT"
done <<<"$SERVICE_ARNS"
