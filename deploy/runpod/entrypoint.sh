#!/bin/sh
set -eu

runtime_root=/workspace/openclaw
state_dir=${OPENCLAW_STATE_DIR:-$runtime_root/state}
config_home=${XDG_CONFIG_HOME:-$runtime_root/config}
openclaw_home=${OPENCLAW_HOME:-$runtime_root/home}
workspace_dir=${OPENCLAW_WORKSPACE_DIR:-$state_dir/workspace}
codex_home=${CODEX_HOME:-$runtime_root/codex}
claude_home=${CLAUDE_CONFIG_DIR:-$runtime_root/claude}
acpx_state_dir=$runtime_root/acpx
code_workspace=${OPENCLAW_CODE_WORKSPACE:-/workspace/code}

codex_plugin_version=${OPENCLAW_RUNPOD_CODEX_PLUGIN_VERSION:-2026.8.2}
acpx_plugin_version=${OPENCLAW_RUNPOD_ACPX_PLUGIN_VERSION:-2026.8.2}
deepseek_plugin_version=${OPENCLAW_RUNPOD_DEEPSEEK_PLUGIN_VERSION:-2026.8.2}

# ACP harness sessions have no TTY, so a harness permission prompt cannot be
# answered. approve-all lets the relay and coding paths actually write files and
# run commands inside this Pod; see deploy/runpod/README.md for the boundary.
acpx_permission_mode=${OPENCLAW_ACPX_PERMISSION_MODE:-approve-all}
acpx_non_interactive_permissions=${OPENCLAW_ACPX_NONINTERACTIVE_PERMISSIONS:-fail}

if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  echo "OPENCLAW_GATEWAY_TOKEN is required. Add it as a RunPod Secret before starting the Pod." >&2
  exit 64
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "TELEGRAM_BOT_TOKEN is required. Add the BotFather token as a RunPod Secret." >&2
  exit 64
fi

# Naming the owner up front replaces the pairing handshake, which otherwise needs
# a Pod terminal to approve the one-time code. Get the numeric id from
# @userinfobot on Telegram.
telegram_owner_id=${TELEGRAM_OWNER_ID:-}
case "$telegram_owner_id" in
  "") ;;
  *[!0-9]*)
    echo "TELEGRAM_OWNER_ID must be the numeric Telegram user id, digits only." >&2
    exit 64
    ;;
esac

case "$acpx_permission_mode" in
  approve-all | approve-reads | deny-all) ;;
  *)
    echo "OPENCLAW_ACPX_PERMISSION_MODE must be approve-all, approve-reads, or deny-all." >&2
    exit 64
    ;;
esac

case "$acpx_non_interactive_permissions" in
  fail | deny) ;;
  *)
    echo "OPENCLAW_ACPX_NONINTERACTIVE_PERMISSIONS must be fail or deny." >&2
    exit 64
    ;;
esac

if [ -n "${OPENCLAW_CONTROL_UI_ORIGIN:-}" ]; then
  control_ui_origin=$OPENCLAW_CONTROL_UI_ORIGIN
elif [ -n "${RUNPOD_POD_ID:-}" ]; then
  control_ui_origin="https://${RUNPOD_POD_ID}-18789.proxy.runpod.net"
else
  echo "Set OPENCLAW_CONTROL_UI_ORIGIN when RUNPOD_POD_ID is unavailable." >&2
  exit 64
fi

case "$control_ui_origin" in
  https://*) ;;
  *)
    echo "OPENCLAW_CONTROL_UI_ORIGIN must be an https:// origin." >&2
    exit 64
    ;;
esac

install -d -m 0700 -o node -g node \
  "$runtime_root" \
  "$openclaw_home" \
  "$config_home" \
  "$config_home/openclaw" \
  "$state_dir" \
  "$workspace_dir" \
  "$codex_home" \
  "$claude_home" \
  "$acpx_state_dir" \
  "$code_workspace"

# `install -d` fixes directory ownership but never the files already inside. A
# single privileged command run through a platform shell - `openclaw config set`
# or `openclaw agent` as root - leaves root-owned files scattered through this
# tree, and the unprivileged Gateway then dies with EACCES on whichever one it
# reaches first: openclaw.json, the state database, or an agent's models.json.
# Recovery is nearly impossible once it starts, because the container no longer
# stays up long enough to open a shell in.
#
# Repair the whole tree rather than named files, so one pass fixes every such
# file instead of surfacing them one crash at a time. This is metadata-only work
# and stays cheap even on a large volume.
chown -R node:node "$runtime_root" 2>/dev/null || true
chown -R node:node "$code_workspace" 2>/dev/null || true

# Claude Code authenticates from the harness process environment. Without one of
# these the `claude` ACP harness fails at spawn time; the Codex harness and every
# OpenAI path stay unaffected, so this is a warning rather than a boot failure.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "warning: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; the claude ACP harness will fail until one is provided. Codex paths are unaffected." >&2
fi

plugin_installed() {
  found=$(find "$state_dir/npm/projects" -path "*/node_modules/@openclaw/$1/package.json" -print -quit 2>/dev/null || true)
  [ -n "$found" ]
}

volume_has_state() {
  [ -e "$state_dir/openclaw.sqlite" ] || [ -d "$state_dir/npm/projects" ]
}

# A fresh volume gets the whole pre-installed plugin state. An existing volume is
# never overwritten: report the exact one-time install instead of clobbering a
# database and OAuth profile that are already in use.
if ! plugin_installed codex || ! plugin_installed acpx || ! plugin_installed deepseek-provider; then
  if volume_has_state; then
    echo "OpenClaw state exists on this volume but a required plugin is missing." >&2
    echo "Run these once in the Pod terminal, then restart the Pod:" >&2
    if ! plugin_installed codex; then
      echo "  runuser -u node -- openclaw plugins install npm:@openclaw/codex@${codex_plugin_version}" >&2
    fi
    if ! plugin_installed acpx; then
      echo "  runuser -u node -- openclaw plugins install npm:@openclaw/acpx@${acpx_plugin_version}" >&2
    fi
    if ! plugin_installed deepseek-provider; then
      echo "  runuser -u node -- openclaw plugins install npm:@openclaw/deepseek-provider@${deepseek_plugin_version}" >&2
    fi
    echo "Alternatively start from a fresh Network Volume to use the image's pre-installed plugins." >&2
    exit 66
  fi
  cp -a /opt/openclaw-plugin-seed/. "$state_dir/"
  chown -R node:node "$state_dir"
fi

run_openclaw() {
  runuser -u node -- node /app/openclaw.mjs "$@"
}

# The public RunPod proxy needs explicit Gateway auth and an exact browser origin.
# Reapply only this deployment-owned boundary on boot so a replacement Pod ID works.
run_openclaw config set --batch-json "$(
  CONTROL_UI_ORIGIN="$control_ui_origin" \
  ACPX_CWD="$code_workspace" \
  ACPX_STATE_DIR="$acpx_state_dir" \
  ACPX_PERMISSION_MODE="$acpx_permission_mode" \
  ACPX_NON_INTERACTIVE_PERMISSIONS="$acpx_non_interactive_permissions" \
  TELEGRAM_OWNER_ID="$telegram_owner_id" \
  node -e '
    const origin = process.env.CONTROL_UI_ORIGIN;
    const ownerId = (process.env.TELEGRAM_OWNER_ID || "").trim();
    process.stdout.write(JSON.stringify([
      { path: "gateway.mode", value: "local" },
      { path: "gateway.auth.mode", value: "token" },
      {
        path: "gateway.auth.rateLimit",
        value: { maxAttempts: 10, windowMs: 60000, lockoutMs: 300000, exemptLoopback: true },
      },
      { path: "gateway.controlUi.allowedOrigins", value: [origin] },
      { path: "channels.telegram.enabled", value: true },
      // A named owner talks to the bot immediately. Without one, the first
      // message only returns a pairing code that must be approved on the Pod.
      ...(ownerId
        ? [
            { path: "channels.telegram.dmPolicy", value: "allowlist" },
            { path: "channels.telegram.allowFrom", value: [ownerId] },
            // allowFrom lets the owner talk to the bot; ownerAllowFrom is the
            // separate gate for owner-only commands like /acp spawn, /config,
            // and exec approvals. Without this, the owner sees "not authorized"
            // on every owner-gated command even though DM auth passes.
            { path: "commands.ownerAllowFrom", value: [`telegram:${ownerId}`] },
          ]
        : [{ path: "channels.telegram.dmPolicy", value: "pairing" }]),
      { path: "channels.telegram.groupPolicy", value: "disabled" },
      { path: "channels.telegram.configWrites", value: false },
      { path: "channels.telegram.streaming.mode", value: "off" },
      { path: "channels.telegram.errorPolicy", value: "always" },
      { path: "channels.telegram.execApprovals.enabled", value: "auto" },
      { path: "channels.telegram.execApprovals.target", value: "dm" },
      { path: "channels.telegram.capabilities.inlineButtons", value: "dm" },
      // Relay path: a bound conversation sends plain messages straight to the ACP
      // harness and delivers the harness reply back, with no OpenClaw model turn.
      { path: "acp.enabled", value: true },
      { path: "acp.dispatch.enabled", value: true },
      { path: "acp.backend", value: "acpx" },
      { path: "acp.defaultAgent", value: "codex" },
      { path: "acp.allowedAgents", value: ["codex", "claude"] },
      { path: "acp.stream.deliveryMode", value: "live" },
      // DM binds need no child thread; topic binds do.
      { path: "session.threadBindings.enabled", value: true },
      { path: "session.threadBindings.spawnSessions", value: true },
      { path: "plugins.entries.acpx.config.cwd", value: process.env.ACPX_CWD },
      { path: "plugins.entries.acpx.config.stateDir", value: process.env.ACPX_STATE_DIR },
      { path: "plugins.entries.acpx.config.probeAgent", value: "codex" },
      { path: "plugins.entries.acpx.config.permissionMode", value: process.env.ACPX_PERMISSION_MODE },
      {
        path: "plugins.entries.acpx.config.nonInteractivePermissions",
        value: process.env.ACPX_NON_INTERACTIVE_PERMISSIONS,
      },
    ]));
  '
)" >/dev/null

# plugins.allow is a restrictive inventory: a provider missing from it contributes
# no models and is blocked outright, with no error explaining why. Pinning a fixed
# list here meant every provider key added later - Google, Mistral, anything - was
# silently ignored until this file changed. OpenClaw's own default is to load every
# bundled plugin, so keep that behaviour and clear any list a previous boot wrote.
#
# Set OPENCLAW_PLUGINS_ALLOW to a comma-separated list only when you deliberately
# want a locked-down inventory; it must then name every plugin this image needs,
# including codex, telegram, and acpx.
if [ -n "${OPENCLAW_PLUGINS_ALLOW:-}" ]; then
  run_openclaw config set plugins.allow "$(
    OPENCLAW_PLUGINS_ALLOW="$OPENCLAW_PLUGINS_ALLOW" node -e '
      const entries = String(process.env.OPENCLAW_PLUGINS_ALLOW)
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean);
      if (entries.length === 0) {
        throw new Error("OPENCLAW_PLUGINS_ALLOW must name at least one plugin");
      }
      process.stdout.write(JSON.stringify(entries));
    '
  )" --strict-json >/dev/null
else
  run_openclaw config unset plugins.allow >/dev/null 2>&1 || true
fi
# A single-model policy allowlist blocks every other model the same silent way.
run_openclaw config unset agents.defaults.modelPolicy.allow >/dev/null 2>&1 || true
if ! run_openclaw config get plugins.entries.codex.enabled >/dev/null 2>&1; then
  run_openclaw config set plugins.entries.codex.enabled true --strict-json >/dev/null
fi
run_openclaw config set plugins.entries.telegram.enabled true --strict-json >/dev/null
run_openclaw config set plugins.entries.acpx.enabled true --strict-json >/dev/null
# Allowing and installing a provider is not enough: a disabled provider plugin
# contributes no models, so the DeepSeek bootstrap model below would still be
# rejected as unknown.
run_openclaw config set plugins.entries.deepseek.enabled true --strict-json >/dev/null
if ! run_openclaw config get plugins.entries.codex.config.appServer.homeScope >/dev/null 2>&1; then
  # RunPod owns an OpenClaw OAuth profile on the volume; never depend on a
  # developer machine's ~/.codex/auth.json or a secret copied into the image.
  run_openclaw config set plugins.entries.codex.config.appServer.homeScope agent >/dev/null
fi

# A plain API key needs no browser, so a Pod with DEEPSEEK_API_KEY has a working
# brain on its very first boot. That agent can then drive the interactive
# ChatGPT and Codex logins over Telegram instead of requiring a Pod terminal.
# Without the key, fall back to the subscription model, which needs a login first.
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  bootstrap_model=deepseek/deepseek-v4-pro
else
  bootstrap_model=openai/gpt-5.6-sol
fi

# Choose defaults only when the operator has not already made an explicit
# choice. Config itself remains authoritative after redeploys.
# A default model is a convenience, not a boot requirement: the Gateway, the
# Telegram transport, and the relay path all work without one. Never let an
# unusable bootstrap model crash-loop the container — warn and carry on so the
# operator can fix the model over chat instead of from the logs alone.
if ! run_openclaw config get agents.defaults.model.primary >/dev/null 2>&1; then
  if ! run_openclaw config set agents.defaults.model.primary "$bootstrap_model" >/dev/null 2>&1; then
    echo "warning: could not set default model $bootstrap_model. The Gateway and Telegram still start; set agents.defaults.model.primary to a model this build knows." >&2
  fi
fi
if ! run_openclaw config get 'agents.defaults.models["openai/gpt-5.6-sol"].agentRuntime.id' >/dev/null 2>&1; then
  run_openclaw config set 'agents.defaults.models["openai/gpt-5.6-sol"].agentRuntime.id' codex >/dev/null
fi

# The Gateway resolves every bind mode to an IPv4 address, so a platform whose
# private network is IPv6-only cannot reach it and would need a public ingress
# just to serve a sibling service. Naming a port here puts an IPv6 socket in
# front of the loopback Gateway instead. Unset means unchanged behaviour.
if [ -n "${OPENCLAW_IPV6_PROXY_PORT:-}" ]; then
  runuser -u node -- node /usr/local/lib/openclaw-ipv6-proxy.js &
fi

exec runuser -u node -- "$@"
