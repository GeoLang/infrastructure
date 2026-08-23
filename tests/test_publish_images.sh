#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PUBLISH_IMAGES_SCRIPT="$TEST_DIRECTORY/../scripts/publish-images.sh"
readonly TEST_TAG="v1.2.3"
readonly ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/publish-images-test.XXXXXX")"
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

  if grep -Fqx -- "$expected_text" "$file_path"
  then
    fail "unexpected action: $expected_text"
  fi
}

assert_no_docker_actions() {
  local action_log="$1"

  if grep -Fq -- 'docker ' "$action_log"
  then
    fail "docker ran when it should not have"
  fi
}

run_publisher() {
  local terraform_output="$1"
  local aws_lookup_result="$2"
  local failing_image_reference="$3"
  local image_tag="$4"
  local action_log="$5"
  local output_file="$6"

  PATH="$fake_binary_directory:$PATH" \
    TERRAFORM_OUTPUT="$terraform_output" \
    AWS_LOOKUP_RESULT="$aws_lookup_result" \
    DOCKER_FAIL_IMAGE="$failing_image_reference" \
    ACTION_LOG="$action_log" \
    "$PUBLISH_IMAGES_SCRIPT" "$image_tag" >"$output_file" 2>&1
}

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "terraform $*" >> "$ACTION_LOG"
printf "%s\n" "$TERRAFORM_OUTPUT"' >"$fake_binary_directory/terraform"

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
action="aws"
for argument in "$@"
do
  action="$action $argument"
done
printf "%s\n" "$action" >> "$ACTION_LOG"
if [[ "$1" == "ecr" && "$2" == "list-images" ]]
then
  if [[ "$AWS_LOOKUP_RESULT" == "absent" ]]
  then
    printf "[]\n"
  elif [[ "$AWS_LOOKUP_RESULT" == "existing" ]]
  then
    printf '[{"imageTag":"existing"}]\n'
  elif [[ "$AWS_LOOKUP_RESULT" == "failure" ]]
  then
    exit 42
  fi
fi
if [[ "$1" == "ecr" && "$2" == "get-login-password" ]]
then
  printf "test-password\n"
fi' >"$fake_binary_directory/aws"

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
action="docker"
for argument in "$@"
do
  action="$action $argument"
done
printf "%s\n" "$action" >> "$ACTION_LOG"
if [[ "$1" == "buildx" && -n "$DOCKER_FAIL_IMAGE" && " $* " == *" $DOCKER_FAIL_IMAGE "* ]]
then
  exit 17
fi
if [[ "$1" == "login" ]]
then
  read -r password
fi' >"$fake_binary_directory/docker"

chmod +x -- "$fake_binary_directory/terraform" "$fake_binary_directory/aws" "$fake_binary_directory/docker"

complete_repositories='{
  "ptolemy":"123456789012.dkr.ecr.us-east-1.amazonaws.com/ptolemy",
  "tiletopia":"123456789012.dkr.ecr.us-east-1.amazonaws.com/tiletopia",
  "geokode":"123456789012.dkr.ecr.us-east-1.amazonaws.com/geokode",
  "itinera":"123456789012.dkr.ecr.us-east-1.amazonaws.com/itinera",
  "interiora":"123456789012.dkr.ecr.us-east-1.amazonaws.com/interiora",
  "geoplumb":"123456789012.dkr.ecr.us-east-1.amazonaws.com/geoplumb",
  "fenestra":"123456789012.dkr.ecr.us-east-1.amazonaws.com/fenestra",
  "agora":"123456789012.dkr.ecr.us-east-1.amazonaws.com/agora",
  "sibyl":"123456789012.dkr.ecr.us-east-1.amazonaws.com/sibyl",
  "geodukt":"123456789012.dkr.ecr.us-east-1.amazonaws.com/geodukt",
  "geolang-api":"123456789012.dkr.ecr.us-east-1.amazonaws.com/geolang-api",
  "viewtopia":"123456789012.dkr.ecr.us-east-1.amazonaws.com/viewtopia",
  "platform-proxy":"123456789012.dkr.ecr.us-east-1.amazonaws.com/platform-proxy"
}'

complete_action_log="$temporary_directory/complete-actions.log"
complete_output="$temporary_directory/complete-output.log"
run_publisher "$complete_repositories" absent "" "$TEST_TAG" "$complete_action_log" "$complete_output"

workspace_directory="$(cd -- "$TEST_DIRECTORY/../.." && pwd)"
for service_name in ptolemy tiletopia geokode itinera interiora fenestra agora sibyl geodukt viewtopia
do
  assert_contains "docker buildx build --platform linux/amd64 --load --tag $ECR_REGISTRY/$service_name:$TEST_TAG $workspace_directory/$service_name" "$complete_action_log"
done
assert_contains "docker buildx build --platform linux/amd64 --load --tag $ECR_REGISTRY/geolang-api:$TEST_TAG $workspace_directory/geolang" "$complete_action_log"
assert_contains "docker buildx build --platform linux/amd64 --load --tag geoplumb-base:$TEST_TAG $workspace_directory/geoplumb" "$complete_action_log"
assert_contains "docker buildx build --platform linux/amd64 --load --build-arg GEOPLUMB_BASE_IMAGE=geoplumb-base:$TEST_TAG --tag $ECR_REGISTRY/geoplumb:$TEST_TAG $workspace_directory/infrastructure/containers/geoplumb" "$complete_action_log"
assert_contains "docker buildx build --platform linux/amd64 --load --tag $ECR_REGISTRY/platform-proxy:$TEST_TAG $workspace_directory/infrastructure/containers/platform-proxy" "$complete_action_log"
assert_contains "docker login --username AWS --password-stdin $ECR_REGISTRY" "$complete_action_log"
for service_name in ptolemy tiletopia geokode itinera interiora geoplumb fenestra agora sibyl geodukt geolang-api viewtopia platform-proxy
do
  assert_contains "docker push $ECR_REGISTRY/$service_name:$TEST_TAG" "$complete_action_log"
done

build_failure_repositories='{
  "ptolemy":"123456789012.dkr.ecr.us-east-1.amazonaws.com/ptolemy",
  "tiletopia":"123456789012.dkr.ecr.us-east-1.amazonaws.com/tiletopia"
}'
build_failure_action_log="$temporary_directory/build-failure-actions.log"
build_failure_output="$temporary_directory/build-failure-output.log"
if run_publisher "$build_failure_repositories" absent "$ECR_REGISTRY/tiletopia:$TEST_TAG" "$TEST_TAG" "$build_failure_action_log" "$build_failure_output"
then
  fail "build failure succeeded"
fi
assert_not_contains "docker login --username AWS --password-stdin $ECR_REGISTRY" "$build_failure_action_log"
assert_not_contains "docker push $ECR_REGISTRY/ptolemy:$TEST_TAG" "$build_failure_action_log"
assert_not_contains "docker push $ECR_REGISTRY/tiletopia:$TEST_TAG" "$build_failure_action_log"

single_repository='{ "ptolemy":"123456789012.dkr.ecr.us-east-1.amazonaws.com/ptolemy" }'
existing_action_log="$temporary_directory/existing-actions.log"
existing_output="$temporary_directory/existing-output.log"
if run_publisher "$single_repository" existing "" "$TEST_TAG" "$existing_action_log" "$existing_output"
then
  fail "existing tag succeeded"
fi
assert_no_docker_actions "$existing_action_log"

unknown_action_log="$temporary_directory/unknown-actions.log"
unknown_output="$temporary_directory/unknown-output.log"
if run_publisher '{ "unknown":"123456789012.dkr.ecr.us-east-1.amazonaws.com/unknown" }' absent "" "$TEST_TAG" "$unknown_action_log" "$unknown_output"
then
  fail "unknown repository key succeeded"
fi
assert_not_contains "aws ecr list-images --repository-name unknown --filter tagStatus=TAGGED --query imageIds[?imageTag=='$TEST_TAG'] --output json --region us-east-1" "$unknown_action_log"
assert_no_docker_actions "$unknown_action_log"

malformed_action_log="$temporary_directory/malformed-actions.log"
malformed_output="$temporary_directory/malformed-output.log"
if run_publisher "$single_repository" absent "" invalid-tag "$malformed_action_log" "$malformed_output"
then
  fail "malformed tag succeeded"
fi
if [[ -s "$malformed_action_log" ]]
then
  fail "malformed tag invoked an external command"
fi

mixed_registry_action_log="$temporary_directory/mixed-registry-actions.log"
mixed_registry_output="$temporary_directory/mixed-registry-output.log"
if run_publisher '{ "ptolemy":"123456789012.dkr.ecr.us-east-1.amazonaws.com/ptolemy", "tiletopia":"210987654321.dkr.ecr.us-west-2.amazonaws.com/tiletopia" }' absent "" "$TEST_TAG" "$mixed_registry_action_log" "$mixed_registry_output"
then
  fail "mixed registries succeeded"
fi
assert_no_docker_actions "$mixed_registry_action_log"
if grep -Fq -- 'aws ecr list-images' "$mixed_registry_action_log"
then
  fail "mixed registries queried ECR"
fi

aws_failure_action_log="$temporary_directory/aws-failure-actions.log"
aws_failure_output="$temporary_directory/aws-failure-output.log"
if run_publisher "$single_repository" failure "" "$TEST_TAG" "$aws_failure_action_log" "$aws_failure_output"
then
  fail "AWS lookup failure succeeded"
fi
assert_contains "aws ecr list-images --repository-name ptolemy --filter tagStatus=TAGGED --query imageIds[?imageTag=='$TEST_TAG'] --output json --region us-east-1" "$aws_failure_action_log"
assert_no_docker_actions "$aws_failure_action_log"

for invalid_terraform_output in 'not JSON' '[]'
do
  invalid_output_action_log="$temporary_directory/invalid-output-actions.log"
  invalid_output_file="$temporary_directory/invalid-output.log"
  if run_publisher "$invalid_terraform_output" absent "" "$TEST_TAG" "$invalid_output_action_log" "$invalid_output_file"
  then
    fail "invalid Terraform output succeeded"
  fi
  assert_no_docker_actions "$invalid_output_action_log"
  if grep -Fq -- 'aws ecr list-images' "$invalid_output_action_log"
  then
    fail "invalid Terraform output queried ECR"
  fi
done

printf '%s\n' "publish-images tests passed"
