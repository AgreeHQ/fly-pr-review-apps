#!/bin/sh -l

# No command tracing (-x): commands here carry secret values.
set -e

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY#$GITHUB_REPOSITORY_OWNER/}
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME}"
# Change underscores to hyphens.
app="${app//_/-}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"
build_args=""
build_secrets=""

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  exit 0
fi

if [ -n "$INPUT_BUILD_ARGS" ]; then
  for ARG in $(echo "$INPUT_BUILD_ARGS" | tr " " "\n"); do
    build_args="$build_args --build-arg ${ARG}"
  done
fi

if [ -n "$INPUT_BUILD_SECRETS" ]; then
  for ARG in $(echo "$INPUT_BUILD_SECRETS" | tr " " "\n"); do
    # flyctl quotes a malformed entry back in its error, so reject it here.
    case "$ARG" in
    *=*) ;;
    *)
      echo "build_secrets: each entry must be NAME=VALUE, with no spaces in the value."
      exit 1
      ;;
    esac
    build_secrets="$build_secrets --build-secret ${ARG}"
  done
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org" ${build_args} ${build_secrets} $INPUT_LAUNCH_OPTIONS
  # Restore the original config file
  cp "$config.bak" "$config"
fi

if [ -n "$INPUT_SECRETS" ]; then
  # flyctl quotes a malformed line back in its error, so its output is not shown.
  if echo -e "$INPUT_SECRETS" | flyctl secrets import --app "$app" --stage >/dev/null 2>&1; then
    echo "Staged secrets for $app."
  else
    echo "flyctl secrets import failed for $app (output hidden: it can contain secret values)."
    exit 1
  fi
fi

# Attach postgres cluster to the app if specified. flyctl prints the new
# connection string, so its output is not shown. Attaching fails when the app
# already has the secret (every redeploy); that does not fail the action.
if [ -n "$INPUT_POSTGRES" ]; then
  if [ "$INPUT_MPG" = "true" ]; then
    pg_command="mpg"
  else
    pg_command="postgres"
  fi
  if flyctl "$pg_command" attach "$INPUT_POSTGRES" --app "$app" >/dev/null 2>&1; then
    echo "Attached Postgres cluster $INPUT_POSTGRES to $app."
  else
    echo "Did not attach Postgres cluster $INPUT_POSTGRES to $app; expected if it is already attached (output hidden)."
  fi
fi

# Execute any pre-deploy steps if provided
if [ -n "$INPUT_PREDEPLOY_SCRIPT" ]; then
  echo -e "$INPUT_PREDEPLOY_SCRIPT" | /bin/sh -l
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
if [ -n "$INPUT_VM" ]; then
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA ${build_args} ${build_secrets} --vm-size "$INPUT_VMSIZE" $INPUT_DEPLOY_OPTIONS
else
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA ${build_args} ${build_secrets} --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY" $INPUT_DEPLOY_OPTIONS
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT

# Execute any post-deploy steps if provided
if [ -n "$INPUT_POSTDEPLOY_SCRIPT" ]; then
  echo -e "$INPUT_POSTDEPLOY_SCRIPT" | /bin/sh -l
fi
