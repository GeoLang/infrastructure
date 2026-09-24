#!/usr/bin/env bash

set -euo pipefail

readonly INDEX_VERSION_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly INDEX_META_FILE="meta.json"
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRASTRUCTURE_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"

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

if [[ $# -ne 2 ]]
then
  fail "usage: $(basename -- "$0") <index-directory> <index-version>"
fi

readonly INDEX_VERSION="$2"

if [[ ! "$INDEX_VERSION" =~ $INDEX_VERSION_PATTERN ]]
then
  fail "index version must be letters, digits, dots, dashes and underscores: $INDEX_VERSION"
fi

if [[ ! -f "$1/$INDEX_META_FILE" ]]
then
  fail "$1 has no $INDEX_META_FILE, so it is not a finished geokode index"
fi

readonly INDEX_DIRECTORY="$(cd -- "$1" && pwd)"

cd -- "$INFRASTRUCTURE_DIRECTORY"
if ! INDEX_URL="$(terraform output -json geokode_index_url | jq -er 'strings | select(startswith("s3://"))')"
then
  fail "terraform output geokode_index_url has no S3 prefix, apply with enable_s3_tiles = true first"
fi
readonly VERSION_URL="$INDEX_URL/$INDEX_VERSION"

# geokode serve refuses an index without meta.json
aws s3 sync "$INDEX_DIRECTORY/" "$VERSION_URL/" --exclude "$INDEX_META_FILE" --delete --only-show-errors
aws s3 cp "$INDEX_DIRECTORY/$INDEX_META_FILE" "$VERSION_URL/$INDEX_META_FILE" --only-show-errors

printf '%s\n' "published $INDEX_DIRECTORY to $VERSION_URL/"
