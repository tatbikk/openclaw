#!/bin/sh
set -eu

state_dir=${OPENCLAW_SERVERLESS_STATE_DIR:-/runpod-volume/openclaw-serverless/state}
config_home=${OPENCLAW_SERVERLESS_CONFIG_HOME:-/runpod-volume/openclaw-serverless/config}

install -d -m 0700 -o node -g node \
  "$(dirname "$state_dir")" \
  "$state_dir" \
  "$state_dir/agents" \
  "$config_home" \
  "$config_home/openclaw"

codex_package=$(find "$state_dir/npm/projects" -path '*/node_modules/@openclaw/codex/package.json' -print -quit 2>/dev/null || true)
if [ -z "$codex_package" ]; then
  if [ -e "$state_dir/openclaw.sqlite" ] || [ -d "$state_dir/npm/projects" ]; then
    echo "OpenClaw state exists but the official Codex plugin is missing. Use a fresh dedicated volume or seed the exact official plugin before deployment." >&2
    exit 66
  fi
  cp -a /opt/openclaw-codex-seed/. "$state_dir/"
  chown -R node:node "$state_dir"
fi

exec runuser -u node -- "$@"
