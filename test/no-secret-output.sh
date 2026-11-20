#!/usr/bin/env bash
# Runs entrypoint.sh in the action's image with a stub flyctl and fails if any
# secret value shows up in the combined stdout/stderr. It also checks that flyctl
# still receives every build secret and every runtime secret.
#
# Usage: test/no-secret-output.sh
#   ENTRYPOINT=path/to/entrypoint.sh  test a different copy of the script
#   IMAGE=name                        image tag to build and run

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
entrypoint=$(cd "$(dirname "${ENTRYPOINT:-$repo/entrypoint.sh}")" && pwd)/$(basename "${ENTRYPOINT:-entrypoint.sh}")
stub="$repo/test/flyctl-stub.sh"
image="${IMAGE:-fly-pr-review-apps-test}"

docker build -q -t "$image" "$repo" >/dev/null

# Every secret value contains CANARY, so any output line with CANARY is a leak.
# Secret names never contain it.
RUNTIME_SECRETS='RT_PLAIN=CANARY_rt_plain_4f1a
RT_SPACES=CANARY_rt value with spaces_9c2e
RT_QUOTES="CANARY_rt_quoted_'"'"'single'"'"'_7b3d"
RT_URL=postgres://app:CANARY_rt_pw_e81c@db.internal:5432/app'

BUILD_SECRETS='BS_PLAIN=CANARY_bs_plain_2a6f
BS_QUOTES=CANARY_bs_"double"_'"'"'single'"'"'_5e0b
BS_TOKEN=CANARY_bs_token_c47d'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() {
  echo "  FAIL: $*"
  failures=$((failures + 1))
}

# Prints "<command> <subcommand>" for each recorded flyctl call.
calls() {
  awk '/^=== call/ { if (c) print c; c = ""; n = 0; next }
       { n++; if (n <= 2) c = c (n == 1 ? "" : " ") substr($0, 5) }
       END { if (c) print c }' "$1/state/calls"
}

# Prints each value that followed --build-secret in calls whose command is $2.
build_secrets_for() {
  awk -v want="$2" '/^=== call/ { cmd = ""; prev = ""; next }
       { a = substr($0, 5); if (cmd == "") cmd = a;
         else if (cmd == want && prev == "--build-secret") print a;
         prev = a }' "$1/state/calls"
}

# run_case NAME EVENT_ACTION APP_EXISTS [VAR=VALUE ...]
# Runs the entrypoint once. Leaves output in $dir/output and exit code in $dir/status.
run_case() {
  local name=$1 action=$2 exists=$3
  shift 3
  dir="$work/$name"
  mkdir -p "$dir/workspace" "$dir/state" "$dir/event"
  printf '{"number": 123, "action": "%s"}\n' "$action" >"$dir/event/event.json"
  printf 'app = "placeholder"\n' >"$dir/workspace/fly.toml"
  : >"$dir/state/calls"
  : >"$dir/workspace/github_output"
  if [ "$exists" = yes ]; then
    touch "$dir/state/app-exists" "$dir/state/db-attached"
  fi

  # The stub replaces the image's real flyctl at /usr/local/bin/flyctl. Putting
  # it on PATH is not enough: `sh -l` sources Alpine's /etc/profile, which resets
  # PATH. --network none keeps anything else from reaching Fly.
  set +e
  env \
    INPUT_SECRETS="$RUNTIME_SECRETS" \
    INPUT_BUILD_SECRETS="$BUILD_SECRETS" \
    INPUT_POSTGRES=test-pg \
    INPUT_MPG=false \
    "$@" \
    docker run --rm --network none \
    -v "$entrypoint:/entrypoint.sh:ro" \
    -v "$stub:/usr/local/bin/flyctl:ro" \
    -v "$dir/event:/github/workflow:ro" \
    -v "$dir/workspace:/github/workspace" \
    -v "$dir/state:/stub-state" \
    -w /github/workspace \
    -e GITHUB_OUTPUT=/github/workspace/github_output \
    -e GITHUB_REPOSITORY=acme/widgets \
    -e GITHUB_REPOSITORY_OWNER=acme \
    -e INPUT_SECRETS -e INPUT_BUILD_SECRETS \
    -e INPUT_POSTGRES -e INPUT_MPG \
    -e INPUT_PREDEPLOY_SCRIPT -e INPUT_POSTDEPLOY_SCRIPT \
    -e INPUT_CPU=1 -e INPUT_CPUKIND=shared -e INPUT_MEMORY=256 -e INPUT_HA=false \
    "$image" >"$dir/output" 2>&1
  echo $? >"$dir/status"
  set -e
}

check_no_canary() {
  if grep -q CANARY "$dir/output"; then
    fail "secret values printed ($(grep -c CANARY "$dir/output") lines):"
    grep CANARY "$dir/output" | cut -c1-160 | sed 's/^/    | /'
  fi
}

check_status() {
  local want=$1 got
  got=$(cat "$dir/status")
  if [ "$want" = 0 ] && [ "$got" != 0 ]; then
    fail "exit status $got, want 0"
    tail -n 5 "$dir/output" | sed 's/^/    | /'
  elif [ "$want" != 0 ] && [ "$got" = 0 ]; then
    fail "exit status 0, want non-zero"
  fi
}

check_called() {
  calls "$dir" | grep -qx "$1" || fail "flyctl $1 was not called"
}

check_not_called() {
  if calls "$dir" | grep -q "^$1"; then fail "flyctl $1 was called"; fi
}

check_build_secrets() {
  local cmd=$1 got line
  got=$(build_secrets_for "$dir" "$cmd")
  while IFS= read -r line; do
    printf '%s\n' "$got" | grep -qxF -- "$line" ||
      fail "flyctl $cmd did not receive build secret ${line%%=*}"
  done <<<"$BUILD_SECRETS"
}

check_runtime_secrets() {
  local line
  while IFS= read -r line; do
    grep -qxF -- "$line" "$dir/state/secrets-import.stdin" 2>/dev/null ||
      fail "secrets import did not receive ${line%%=*} on stdin"
  done <<<"$RUNTIME_SECRETS"
}

check_outputs() {
  local key
  for key in hostname url id name; do
    grep -q "^$key=" "$dir/workspace/github_output" || fail "output $key not set"
  done
}

echo "case: new app (status fails, launch, postgres attach succeeds)"
run_case new-app synchronize no \
  INPUT_PREDEPLOY_SCRIPT='echo predeploy-ran' INPUT_POSTDEPLOY_SCRIPT='echo postdeploy-ran'
check_status 0
check_no_canary
check_called "launch --no-deploy"
check_called "postgres attach"
check_build_secrets launch
check_build_secrets deploy
check_runtime_secrets
check_outputs
grep -q predeploy-ran "$dir/output" || fail "predeploy script did not run"
grep -q postdeploy-ran "$dir/output" || fail "postdeploy script did not run"

echo "case: new app with MPG cluster"
run_case new-app-mpg synchronize no INPUT_MPG=true
check_status 0
check_no_canary
check_called "mpg attach"
check_build_secrets deploy
check_runtime_secrets
check_outputs

echo "case: existing app (attach fails, DATABASE_URL already set)"
run_case existing-app synchronize yes
check_status 0
check_no_canary
check_not_called launch
check_called "postgres attach"
check_build_secrets deploy
check_runtime_secrets
check_outputs

echo "case: closed event"
run_case closed closed yes
check_status 0
check_no_canary
check_called "apps destroy"
check_not_called deploy

echo "case: runtime secret line that flyctl rejects"
RUNTIME_SECRETS="$RUNTIME_SECRETS
CANARY_rt_line_without_equals_0d9f" run_case bad-runtime-secret synchronize yes
check_status 1
check_no_canary
check_not_called deploy

echo "case: build secret value with whitespace"
BUILD_SECRETS="$BUILD_SECRETS
BS_SPACES=CANARY_bs_w1 CANARY_bs_w2 CANARY_bs_w3" run_case bad-build-secret synchronize yes
check_status 1
check_no_canary
check_not_called deploy

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "PASSED"
