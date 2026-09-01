#!/bin/sh
set -eu

state_dir=${OPENCLAW_SERVERLESS_STATE_DIR:-/runpod-volume/openclaw-serverless/state}
config_home=${OPENCLAW_SERVERLESS_CONFIG_HOME:-/runpod-volume/openclaw-serverless/config}
bootstrap_root=/tmp/openclaw-serverless-auth

install -d -m 0700 "$state_dir" "$config_home" "$config_home/openclaw" "$bootstrap_root"

export HOME=$bootstrap_root/home
export OPENCLAW_HOME=$HOME
export OPENCLAW_STATE_DIR=$state_dir
export OPENCLAW_CONFIG_PATH=$bootstrap_root/openclaw.json
export OPENCLAW_WORKSPACE_DIR=$bootstrap_root/workspace
export XDG_CONFIG_HOME=$config_home
export CODEX_HOME=$bootstrap_root/codex
install -d -m 0700 "$HOME" "$OPENCLAW_WORKSPACE_DIR" "$CODEX_HOME"

if [ "${OPENCLAW_SERVERLESS_AUTH_FLOW:-device}" = browser ]; then
  node /app/openclaw.mjs models auth login --provider openai
else
  node /app/openclaw.mjs models auth login --provider openai --device-code
fi

node /app/openclaw.mjs models auth list --provider openai
node /app/openclaw.mjs models list --provider openai
