#!/bin/sh
set -eu

runtime_root=/workspace/openclaw
state_dir=${OPENCLAW_STATE_DIR:-$runtime_root/state}
config_path=${OPENCLAW_CONFIG_PATH:-$state_dir/openclaw.json}
config_home=${XDG_CONFIG_HOME:-$runtime_root/config}
openclaw_home=${OPENCLAW_HOME:-$runtime_root/home}
workspace_dir=${OPENCLAW_WORKSPACE_DIR:-$state_dir/workspace}
codex_home=${CODEX_HOME:-$runtime_root/codex}
claude_home=${CLAUDE_CONFIG_DIR:-$runtime_root/claude}
acpx_state_dir=$runtime_root/acpx
code_workspace=${OPENCLAW_CODE_WORKSPACE:-/workspace/code}

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

# Presence is not enough. A plugin left on the volume by an older image is
# compiled against the Plugin SDK of its own release, so against this runtime it
# fails to load on a missing export - and a provider that cannot load contributes
# no models at all, silently. Match the pinned version, not just the file.
plugin_at_version() {
  found=$(find "$state_dir/npm/projects" -path "*/node_modules/@openclaw/$1/package.json" -print -quit 2>/dev/null || true)
  [ -n "$found" ] || return 1
  node -e 'const fs = require("node:fs");
    const [manifest, wanted] = process.argv.slice(1);
    process.exit(JSON.parse(fs.readFileSync(manifest, "utf8")).version === wanted ? 0 : 1);
  ' "$found" "$2"
}

volume_has_state() {
  [ -e "$state_dir/openclaw.sqlite" ] || [ -d "$state_dir/npm/projects" ]
}

run_openclaw() {
  runuser -u node -- node /app/openclaw.mjs "$@"
}

# A fresh volume gets the whole pre-installed plugin state in one copy. An
# existing volume is never overwritten that way - the copy would land on a
# database and OAuth profile already in use - so install just the plugins that
# are actually missing.
#
# Codex is not in this set: the runtime image bundles it. A managed npm copy of
# a bundled plugin is stripped by the Gateway on every boot, which changes the
# plugin inventory mid-startup and costs readiness - so reinstalling it here
# each boot would loop forever rather than converge.
#
# Printing the command for an operator to run instead was a dead end: this
# platform offers no shell into a container that exits, so a single missing
# plugin left the deployment crash-looping with no way to act on the advice. A
# targeted install touches nothing else on the volume, so do it here.
# --force is what makes this a repair rather than a request: a plain install
# refuses outright when a copy of the package is already on the volume, which is
# precisely the state being repaired. A failure only warns, because a plugin the
# Gateway can start without must never cost the whole boot - there is no shell
# here to recover a container that keeps exiting.
install_plugin() {
  plugin_at_version "$1" "$3" && return 0
  echo "plugin $1 is absent or not at $3 on this volume; installing $2@$3" >&2
  run_openclaw plugins install --accept-capabilities --force "npm:$2@$3" ||
    echo "warning: could not install $2@$3; starting without it" >&2
}

if volume_has_state; then
  install_plugin acpx @openclaw/acpx "$acpx_plugin_version"
  install_plugin deepseek-provider @openclaw/deepseek-provider "$deepseek_plugin_version"
else
  cp -a /opt/openclaw-plugin-seed/. "$state_dir/"
  chown -R node:node "$state_dir"
fi

# A roster that grew past one agent is refused from 2026.8.x on unless it says
# who owns it, and that refusal lands on the very first `config set` below: the
# Gateway never starts, and the volume cannot be repaired from a shell the crash
# loop leaves no time to open.
#
# Stamping ownership alone is not the repair. An explicit fleet has no implicit
# default, so a channel with no matching binding fails closed and the bot goes
# quiet instead of crashing - the worse outcome of the two. Stamp the marker and
# the channel binding together, and leave a roster that already declares an
# owner in either shape untouched.
#
# The roster is read from both shapes it can be on disk in: the current
# `entries` map, and the older `list` array a volume written before the rename
# still carries. Report what was found either way - a silent skip here reads
# exactly like a boot that never ran this at all.
if [ -f "$config_path" ]; then
  runuser -u node -- node -e '
    const fs = require("node:fs");
    const configPath = process.argv[1];
    const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
    const agents = (cfg.agents ??= {});
    const entries = agents.entries ?? {};
    const ids = Object.keys(entries);
    const marked = ids.filter((id) => entries[id]?.default === true);
    const bindings = Array.isArray(cfg.bindings) ? cfg.bindings : [];
    const telegramBinding = bindings.find((binding) => binding?.match?.channel === "telegram");
    // One marker is the legacy way to name the owner; several name none of
    // them, which is how this volume got stuck - the roster looked declared to
    // a lenient reader and undeclared to the one that matters. Take the sole
    // marker as the owner when there is exactly one, and drop every marker
    // afterwards so the current shape is the only one left to read.
    let owner = telegramBinding?.agentId ?? (ids.includes("main") ? "main" : ids[0]);
    let changed = false;
    if (ids.length >= 2 && !agents.ownership) {
      if (marked.length === 1) {
        owner = marked[0];
      }
      for (const id of marked) {
        delete entries[id].default;
      }
      agents.ownership = "explicit";
      changed = true;
    }
    if (agents.ownership && !telegramBinding && owner) {
      bindings.push({ agentId: owner, match: { channel: "telegram", accountId: "*" } });
      cfg.bindings = bindings;
      changed = true;
    }
    // Default the owner to an ACP harness session. Codex then drives the turn
    // over the operator subscription and picks its own model, so OpenClaw never
    // names one - which is the whole failure this avoids: a model id written
    // here has to exist in that account catalog, and a mismatch both kills the
    // reply and cools down the credential that was never at fault.
    if (entries[owner] && !entries[owner].runtime) {
      entries[owner].runtime = {
        type: "acp",
        acp: { agent: "codex", backend: "acpx", mode: "persistent" },
      };
      changed = true;
    }
    console.error(
      "roster check: entries=" + ids.length +
        " marked=" + marked.length +
        " ownership=" + agents.ownership +
        " owner=" + owner +
        " runtime=" + (entries[owner]?.runtime?.type ?? "embedded") +
        " changed=" + changed,
    );
    if (changed) {
      fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2) + "\n");
    }
  ' "$config_path"
else
  echo "roster check: no config at $config_path" >&2
fi

# Doctor is the only owner of state repairs that must happen while the Gateway
# is stopped - a session row in an older canonical shape, a legacy store left by
# an upgrade. The Gateway itself can only report those and carry on degraded,
# and its advice to "stop the Gateway and run openclaw doctor --fix" assumes a
# shell this platform does not offer. Boot is the one moment that shell exists,
# so spend it here. Repeat runs are no-ops; a failure is reported and never
# blocks the boot, since a degraded Gateway still beats no Gateway.
run_openclaw doctor --fix || echo "warning: doctor --fix did not complete; continuing to start the Gateway" >&2

# Clear any auth-profile cooldown/disabled state written during prior quota
# exhaustion. The cooldown is stored in the agent SQLite database and persists
# across container restarts, blocking every turn indefinitely even after quota
# is restored. Resetting it here gives the Gateway a clean start. Failures
# only warn; a lingering cooldown degrades turns but never prevents boot.
auth_profile_db="$state_dir/agents/main/agent/openclaw-agent.sqlite"
if [ -f "$auth_profile_db" ]; then
  runuser -u node -- node -e '
    const { DatabaseSync } = require("node:sqlite");
    const dbPath = process.argv[1];
    try {
      const db = new DatabaseSync(dbPath);
      const row = db.prepare("SELECT state_json FROM auth_profile_state WHERE state_key = ?").get("primary");
      if (row && row.state_json) {
        const state = JSON.parse(row.state_json);
        const usageStats = state.usageStats;
        let changed = false;
        if (usageStats && typeof usageStats === "object") {
          for (const usage of Object.values(usageStats)) {
            for (const field of ["cooldownUntil", "cooldownReason", "cooldownModel", "disabledUntil", "disabledReason"]) {
              if (field in usage) {
                delete usage[field];
                changed = true;
              }
            }
          }
        }
        if (changed) {
          db.prepare("UPDATE auth_profile_state SET state_json = ?, updated_at = ? WHERE state_key = ?")
            .run(JSON.stringify(state), Date.now(), "primary");
          process.stderr.write("[startup] cleared persisted auth profile cooldown state\n");
        } else {
          process.stderr.write("[startup] auth profile state: no persisted cooldown found\n");
        }
      }
      db.close();
    } catch (e) {
      process.stderr.write("[startup] warning: could not clear auth profile cooldown: " + e.message + "\n");
    }
  ' "$auth_profile_db" || echo "warning: auth profile cooldown script exited non-zero; continuing" >&2
fi

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

# The operator's stated choice on this deployment is openai/gpt-5.6-sol via the
# Codex/ChatGPT subscription. Seed sol when the default is unset OR when it is
# openai/gpt-5.6-luna - which is the value my earlier meddling wrote to the
# volume before this revert. Without the luna case the seed would preserve my
# wrong write forever ("only when unset" would treat luna as an operator
# choice); with it, one boot restores the operator's stated choice, and every
# later boot leaves any operator-chosen value alone. Sol vs luna vs terra
# afterwards is a decision the operator makes from chat with /model.
current_default=$(run_openclaw config get agents.defaults.model.primary 2>/dev/null || true)
case "$current_default" in
  ""|"openai/gpt-5.6-luna")
    if ! run_openclaw config set agents.defaults.model.primary openai/gpt-5.6-sol >/dev/null 2>&1; then
      echo "warning: could not seed the default model openai/gpt-5.6-sol. The Gateway and Telegram still start; set agents.defaults.model.primary from chat with /model." >&2
    fi
    ;;
esac

# Report the roster's runtime + model per agent so a silent turn is diagnosable
# from boot log alone - which agent is which, on which model, is the fact every
# later "no reply" investigation needs first. This is diagnostics only; no
# selection is judged or rewritten here. Sol vs luna vs terra is an operator
# choice made from chat with /model, not from this boot script.
if [ -f "$config_path" ]; then
  runuser -u node -- node -e '
    const fs = require("node:fs");
    const configPath = process.argv[1];
    const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
    const entries = cfg.agents?.entries ?? {};
    for (const [id, entry] of Object.entries(entries)) {
      console.error(
        "agent " + id +
          ": runtime=" + (entry?.runtime?.type ?? "embedded") +
          " model=" + (entry?.model?.primary ?? entry?.model ?? "<inherited>"),
      );
    }
    console.error(
      "agent <defaults>: model=" +
        (cfg.agents?.defaults?.model?.primary ?? cfg.agents?.defaults?.model ?? "<unset>"),
    );
  ' "$config_path"
fi

# The Gateway resolves every bind mode to an IPv4 address, so a platform whose
# private network is IPv6-only cannot reach it and would need a public ingress
# just to serve a sibling service. Naming a port here puts an IPv6 socket in
# front of the loopback Gateway instead. Unset means unchanged behaviour.
if [ -n "${OPENCLAW_IPV6_PROXY_PORT:-}" ]; then
  runuser -u node -- node /usr/local/lib/openclaw-ipv6-proxy.js &
fi

# A restart request drains the Gateway, closes the server, and expects the
# process to come back. Railway only revives a container that FAILED, so an exit
# code 0 here ends the deployment for good - and there is no shell beside a
# stopped container to bring it back, which is this deployment's whole premise.
# Own that gap: a clean exit means "start me again", while a crash still leaves
# through the platform's restart policy, so a bad config keeps surfacing as a
# failed deploy instead of spinning here forever.
stopping=0
gateway_pid=""

# Supervising costs the exec: SIGTERM now lands on this shell instead of the
# Gateway. Forward it, or a container stop would skip the graceful shutdown that
# flushes sessions and would look like a restart request on the way back up.
forward_stop() {
  stopping=1
  if [ -n "$gateway_pid" ]; then
    kill -TERM "$gateway_pid" 2>/dev/null || true
  fi
}
trap forward_stop TERM INT

while true; do
  runuser -u node -- "$@" &
  gateway_pid=$!
  status=0
  # A trapped signal makes `wait` return before the child does. Keep waiting so
  # the decision below reads the Gateway's own exit status, not the signal's.
  while true; do
    wait "$gateway_pid" || status=$?
    [ "$status" -gt 128 ] || break
    status=0
  done
  gateway_pid=""
  [ "$stopping" -eq 0 ] || exit 0
  [ "$status" -eq 0 ] || exit "$status"
  echo "gateway exited cleanly; restarting it" >&2
  # Bound the loop: an immediate repeat is a restart storm, not a restart.
  sleep 1
done
