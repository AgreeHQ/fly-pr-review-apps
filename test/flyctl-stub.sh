#!/bin/sh
# Stand-in for flyctl used by test/no-secret-output.sh.
# It records its arguments (and the stdin of `secrets import`) under /stub-state
# and never writes them to stdout or stderr. Where the real flyctl prints input
# values, this stub does the same, so the test can check that the action hides them.

state=/stub-state

{
  echo "=== call"
  for a in "$@"; do printf 'arg:%s\n' "$a"; done
} >>"$state/calls"

case "$1" in
status)
  case " $* " in
  *" --json "*)
    echo '{"Hostname":"pr-test.fly.dev","ID":"pr-test"}'
    exit 0
    ;;
  esac
  if [ -f "$state/app-exists" ]; then
    echo "stub: app is running"
    exit 0
  fi
  echo "stub: app not found" >&2
  exit 1
  ;;
launch)
  touch "$state/app-exists"
  echo "stub: launched"
  ;;
secrets)
  [ "$2" = "import" ] || exit 1
  stdin=$(cat)
  printf '%s\n' "$stdin" >>"$state/secrets-import.stdin"
  # Like the real parser, reject a non-empty, non-comment line without '=' and
  # quote the line back in the error.
  bad=$(printf '%s\n' "$stdin" | grep -v -e '^$' -e '^#' | grep -v '=' | head -n 1)
  if [ -n "$bad" ]; then
    echo "Error: Secrets must be provided as NAME=VALUE pairs ($bad is invalid)" >&2
    exit 1
  fi
  echo "stub: secrets staged"
  ;;
postgres | mpg)
  [ "$2" = "attach" ] || exit 1
  # The real attach prints the new connection string. Print it every time, and
  # fail like a redeploy does once DATABASE_URL is already set.
  echo "The following secret was added to the app:"
  echo "  DATABASE_URL=postgres://u:CANARY_DB@host:5432/db"
  if [ -f "$state/db-attached" ]; then
    echo "Error: app already contains a secret named DATABASE_URL" >&2
    exit 1
  fi
  touch "$state/db-attached"
  ;;
deploy)
  # Like the real flag parser, quote a malformed --build-secret back in the error.
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--build-secret" ]; then
      case "$a" in
      *=*) ;;
      *)
        echo "Error: '$a': must be in the format NAME=VALUE" >&2
        exit 1
        ;;
      esac
    fi
    prev="$a"
  done
  echo "stub: deployed"
  ;;
apps)
  [ "$2" = "destroy" ] || exit 1
  echo "stub: destroyed"
  ;;
*)
  echo "stub: unexpected flyctl command" >&2
  exit 1
  ;;
esac
