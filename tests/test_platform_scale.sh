#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PLATFORM_SCALE_SCRIPT="$TEST_DIRECTORY/../scripts/platform-scale.sh"
readonly CLUSTER_NAME="geolang-prod"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/platform-scale-test.XXXXXX")"
readonly temporary_directory
readonly fake_binary_directory="$temporary_directory/bin"

trap 'rm -rf "$temporary_directory"' EXIT

mkdir -p -- "$fake_binary_directory"

fail() {
  printf '%s\n' "test failed: $1" >&2
  exit 1
}

assert_contains() {
  local expected_text="$1"
  local file_path="$2"

  if ! grep -Fqx -- "$expected_text" "$file_path"
  then
    fail "missing action: $expected_text"
  fi
}

assert_not_contains() {
  local expected_text="$1"
  local file_path="$2"

  if grep -Fq -- "$expected_text" "$file_path"
  then
    fail "unexpected action: $expected_text"
  fi
}

run_scaler() {
  local terraform_output="$1"
  local service_arns_json="$2"
  local action_log="$3"
  local output_file="$4"
  shift 4

  env -u AWS_PROFILE \
    PATH="$fake_binary_directory:$PATH" \
    TERRAFORM_OUTPUT="$terraform_output" \
    SERVICE_ARNS_JSON="$service_arns_json" \
    ACTION_LOG="$action_log" \
    "$PLATFORM_SCALE_SCRIPT" "$@" >"$output_file" 2>&1
}

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "terraform $*" >> "$ACTION_LOG"
printf "%s\n" "profile ${AWS_PROFILE:-none}" >> "$ACTION_LOG"
printf "%s\n" "$TERRAFORM_OUTPUT"' >"$fake_binary_directory/terraform"

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "aws $*" >> "$ACTION_LOG"
printf "%s\n" "profile ${AWS_PROFILE:-none}" >> "$ACTION_LOG"
if [[ "$1" == "ecs" && "$2" == "list-services" ]]
then
  printf "%s\n" "$SERVICE_ARNS_JSON"
fi' >"$fake_binary_directory/aws"

chmod +x -- "$fake_binary_directory/terraform" "$fake_binary_directory/aws"

readonly SERVICES_JSON='{"serviceArns":[
  "arn:aws:ecs:us-west-2:000152811496:service/geolang-prod/geolang-prod-ptolemy",
  "arn:aws:ecs:us-west-2:000152811496:service/geolang-prod/geolang-prod-viewtopia"
]}'

down_action_log="$temporary_directory/down-actions.log"
down_output="$temporary_directory/down-output.log"
run_scaler "$CLUSTER_NAME" "$SERVICES_JSON" "$down_action_log" "$down_output" down

assert_contains "terraform output -raw ecs_cluster" "$down_action_log"
assert_contains "aws ecs list-services --cluster $CLUSTER_NAME --output json" "$down_action_log"
for service_name in geolang-prod-ptolemy geolang-prod-viewtopia
do
  assert_contains "aws ecs update-service --cluster $CLUSTER_NAME --service $service_name --desired-count 0 --output json" "$down_action_log"
  assert_contains "$service_name desired-count 0" "$down_output"
done

up_action_log="$temporary_directory/up-actions.log"
up_output="$temporary_directory/up-output.log"
run_scaler "$CLUSTER_NAME" "$SERVICES_JSON" "$up_action_log" "$up_output" up --profile geolang

for service_name in geolang-prod-ptolemy geolang-prod-viewtopia
do
  assert_contains "aws ecs update-service --cluster $CLUSTER_NAME --service $service_name --desired-count 1 --output json" "$up_action_log"
  assert_contains "$service_name desired-count 1" "$up_output"
done
assert_contains "profile geolang" "$up_action_log"
assert_not_contains "profile none" "$up_action_log"

empty_action_log="$temporary_directory/empty-actions.log"
empty_output="$temporary_directory/empty-output.log"
run_scaler "$CLUSTER_NAME" '{"serviceArns":[]}' "$empty_action_log" "$empty_output" down

assert_not_contains "aws ecs update-service" "$empty_action_log"
assert_contains "no services on cluster $CLUSTER_NAME" "$empty_output"

malformed_action_log="$temporary_directory/malformed-actions.log"
malformed_output="$temporary_directory/malformed-output.log"
if run_scaler "$CLUSTER_NAME" 'not JSON' "$malformed_action_log" "$malformed_output" down
then
  fail "malformed service list succeeded"
fi
assert_not_contains "aws ecs update-service" "$malformed_action_log"

for invalid_arguments in "sideways" "up down" "up --profile" "--profile geolang" "up --region us-west-2"
do
  invalid_action_log="$temporary_directory/invalid-actions.log"
  invalid_output="$temporary_directory/invalid-output.log"
  rm -f -- "$invalid_action_log"
  # shellcheck disable=SC2086
  if run_scaler "$CLUSTER_NAME" "$SERVICES_JSON" "$invalid_action_log" "$invalid_output" $invalid_arguments
  then
    fail "invalid arguments succeeded: $invalid_arguments"
  fi
  if [[ -s "$invalid_action_log" ]]
  then
    fail "invalid arguments invoked an external command: $invalid_arguments"
  fi
done

no_arguments_action_log="$temporary_directory/no-arguments-actions.log"
no_arguments_output="$temporary_directory/no-arguments-output.log"
if run_scaler "$CLUSTER_NAME" "$SERVICES_JSON" "$no_arguments_action_log" "$no_arguments_output"
then
  fail "missing arguments succeeded"
fi
if [[ -s "$no_arguments_action_log" ]]
then
  fail "missing arguments invoked an external command"
fi

printf '%s\n' "platform-scale tests passed"
