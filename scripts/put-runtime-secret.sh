#!/usr/bin/env bash

set -euo pipefail

allowed_keys=(
  platform_jwt
  geolang_executor
  llm_api_key
  jupyter_token
)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

for command in jq aws terraform mktemp
do
  command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

[ "$#" -eq 1 ] || fail "usage: $0 RUNTIME_SECRET_KEY"
secret_key="$1"

key_is_allowed=false
for allowed_key in "${allowed_keys[@]}"
do
  if [ "$secret_key" = "$allowed_key" ]
  then
    key_is_allowed=true
    break
  fi
done
[ "$key_is_allowed" = true ] || fail "unknown runtime secret key: $secret_key"

secret_file=
cleanup() {
  if [ -n "$secret_file" ]
  then
    rm -f "$secret_file"
  fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

umask 077
secret_file=$(mktemp)
chmod 600 "$secret_file"

if [ -t 0 ]
then
  IFS= read -r -s -p "Secret value: " secret_value
  printf '\n' >&2
  printf '%s' "$secret_value" > "$secret_file"
  unset secret_value
else
  cat > "$secret_file"
fi

[ -s "$secret_file" ] || fail "secret value must not be empty"

runtime_secret_arns=$(terraform output -json runtime_secret_arns)
secret_arn=$(printf '%s' "$runtime_secret_arns" | jq -er --arg key "$secret_key" '.[$key] // empty')

aws secretsmanager put-secret-value \
  --secret-id "$secret_arn" \
  --secret-string "file://$secret_file" \
  >/dev/null
