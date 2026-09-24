#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PUBLISH_INDEX_SCRIPT="$TEST_DIRECTORY/../scripts/publish-geokode-index.sh"
readonly INDEX_URL="s3://geolang-prod-tiles/geokode-index"
readonly TEST_VERSION="planet-2026-09-24"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/publish-geokode-index-test.XXXXXX")"
readonly temporary_directory
readonly fake_binary_directory="$temporary_directory/bin"
readonly index_directory="$temporary_directory/work/planet-index"

trap 'rm -rf "$temporary_directory"' EXIT

mkdir -p -- "$fake_binary_directory" "$index_directory"
printf '{}\n' >"$index_directory/meta.json"

fail() {
  printf '%s\n' "test failed: $1" >&2
  exit 1
}

assert_line() {
  local line_number="$1"
  local expected_text="$2"
  local file_path="$3"

  if [[ "$(sed -n "${line_number}p" "$file_path")" != "$expected_text" ]]
  then
    fail "line $line_number is not: $expected_text"
  fi
}

assert_no_aws_actions() {
  local action_log="$1"

  if grep -Fq -- 'aws ' "$action_log"
  then
    fail "aws ran when it should not have"
  fi
}

run_publisher() {
  local terraform_output="$1"
  local action_log="$2"
  local output_file="$3"
  shift 3

  : >"$action_log"
  (
    cd -- "$temporary_directory/work"
    PATH="$fake_binary_directory:$PATH" \
      TERRAFORM_OUTPUT="$terraform_output" \
      ACTION_LOG="$action_log" \
      "$PUBLISH_INDEX_SCRIPT" "$@"
  ) >"$output_file" 2>&1
}

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "terraform $*" >> "$ACTION_LOG"
printf "%s\n" "$TERRAFORM_OUTPUT"' >"$fake_binary_directory/terraform"

printf '%s\n' '#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "aws $*" >> "$ACTION_LOG"' >"$fake_binary_directory/aws"

chmod +x -- "$fake_binary_directory/terraform" "$fake_binary_directory/aws"

success_action_log="$temporary_directory/success-actions.log"
success_output="$temporary_directory/success-output.log"
run_publisher "\"$INDEX_URL\"" "$success_action_log" "$success_output" planet-index "$TEST_VERSION" \
  || fail "publish failed: $(cat "$success_output")"
assert_line 1 "terraform output -json geokode_index_url" "$success_action_log"
assert_line 2 "aws s3 sync $index_directory/ $INDEX_URL/$TEST_VERSION/ --exclude meta.json --delete --only-show-errors" "$success_action_log"
assert_line 3 "aws s3 cp $index_directory/meta.json $INDEX_URL/$TEST_VERSION/meta.json --only-show-errors" "$success_action_log"

unfinished_index_directory="$temporary_directory/work/unfinished-index"
mkdir -p -- "$unfinished_index_directory"
unfinished_action_log="$temporary_directory/unfinished-actions.log"
unfinished_output="$temporary_directory/unfinished-output.log"
if run_publisher "\"$INDEX_URL\"" "$unfinished_action_log" "$unfinished_output" unfinished-index "$TEST_VERSION"
then
  fail "index without meta.json succeeded"
fi
if [[ -s "$unfinished_action_log" ]]
then
  fail "index without meta.json invoked an external command"
fi

for invalid_version in "" "../planet" "planet/2026" "-planet"
do
  invalid_version_action_log="$temporary_directory/invalid-version-actions.log"
  invalid_version_output="$temporary_directory/invalid-version-output.log"
  if run_publisher "\"$INDEX_URL\"" "$invalid_version_action_log" "$invalid_version_output" planet-index "$invalid_version"
  then
    fail "invalid version succeeded: $invalid_version"
  fi
  if [[ -s "$invalid_version_action_log" ]]
  then
    fail "invalid version invoked an external command: $invalid_version"
  fi
done

for missing_bucket_output in 'null' '"S3 disabled"'
do
  missing_bucket_action_log="$temporary_directory/missing-bucket-actions.log"
  missing_bucket_output_file="$temporary_directory/missing-bucket-output.log"
  if run_publisher "$missing_bucket_output" "$missing_bucket_action_log" "$missing_bucket_output_file" planet-index "$TEST_VERSION"
  then
    fail "missing bucket succeeded: $missing_bucket_output"
  fi
  assert_no_aws_actions "$missing_bucket_action_log"
done

argument_count_action_log="$temporary_directory/argument-count-actions.log"
argument_count_output="$temporary_directory/argument-count-output.log"
if run_publisher "\"$INDEX_URL\"" "$argument_count_action_log" "$argument_count_output" planet-index
then
  fail "one argument succeeded"
fi
if [[ -s "$argument_count_action_log" ]]
then
  fail "one argument invoked an external command"
fi

printf '%s\n' "publish-geokode-index tests passed"
