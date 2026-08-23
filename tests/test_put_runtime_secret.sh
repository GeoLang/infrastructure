#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script_path="$script_dir/../scripts/put-runtime-secret.sh"
test_dir=$(mktemp -d)
fake_bin="$test_dir/bin"
mkdir "$fake_bin"
trap 'rm -rf "$test_dir"' EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cat > "$fake_bin/terraform" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"platform_jwt":"arn:aws:secretsmanager:us-east-1:123456789012:secret:platform"}'
EOF

cat > "$fake_bin/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AWS_ARGS_FILE"
for argument in "$@"
do
  if [[ "$argument" == file://* ]]
  then
    secret_file=${argument#file://}
    [ -f "$secret_file" ] || exit 1
    stat -c '%a' "$secret_file" > "$AWS_MODE_FILE"
    printf '%s\n' "$secret_file" > "$AWS_SECRET_FILE"
  fi
done
EOF

chmod +x "$fake_bin/terraform" "$fake_bin/aws"

export PATH="$fake_bin:$PATH"
export TMPDIR="$test_dir"
export AWS_ARGS_FILE="$test_dir/aws-args"
export AWS_MODE_FILE="$test_dir/aws-mode"
export AWS_SECRET_FILE="$test_dir/aws-secret-file"

printf 'secret value' | "$script_path" platform_jwt

grep -Fx -- '--secret-string' "$AWS_ARGS_FILE" >/dev/null || fail "aws did not receive --secret-string"
grep -F -- 'file://' "$AWS_ARGS_FILE" >/dev/null || fail "aws did not receive a file URL"
if grep -F -- 'secret value' "$AWS_ARGS_FILE" >/dev/null
then
  fail "secret value appeared in aws arguments"
fi
[ "$(cat "$AWS_MODE_FILE")" = "600" ] || fail "secret file mode was not 600"
secret_file=$(cat "$AWS_SECRET_FILE")
[ ! -e "$secret_file" ] || fail "secret file was not removed"

rm -f "$AWS_ARGS_FILE"
if printf 'secret value' | "$script_path" unknown_key >/dev/null 2>&1
then
  fail "unknown key succeeded"
fi
[ ! -e "$AWS_ARGS_FILE" ] || fail "unknown key invoked aws"

if printf 'postgres://manual-value' | "$script_path" ptolemy_database_url >/dev/null 2>&1
then
  fail "database URL key succeeded"
fi
[ ! -e "$AWS_ARGS_FILE" ] || fail "database URL key invoked aws"

if printf '' | "$script_path" platform_jwt >/dev/null 2>&1
then
  fail "empty value succeeded"
fi
[ ! -e "$AWS_ARGS_FILE" ] || fail "empty value invoked aws"
