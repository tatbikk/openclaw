#!/bin/sh
# Authenticate the ACP relay harnesses (path 3).
#
# The relay harnesses do NOT inherit OpenClaw's own OAuth profile:
#
#   * Codex ACP runs in an isolated CODEX_HOME that acpx generates. OpenClaw
#     copies model/provider/trust config into it and deliberately leaves auth
#     out, so that home needs its own one-time Codex login.
#   * Claude Code ACP gets a plain copy of the Gateway process environment, so
#     it authenticates from CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, or a
#     credential already stored under CLAUDE_CONFIG_DIR.
#
# Usage:
#   openclaw-relay-auth status
#   openclaw-relay-auth codex [extra codex login flags]
set -eu

state_dir=${OPENCLAW_STATE_DIR:-/workspace/openclaw/state}
claude_home=${CLAUDE_CONFIG_DIR:-/workspace/openclaw/claude}

find_codex_home() {
  find "$state_dir" -type d -path "*/acpx/codex-home" -print -quit 2>/dev/null || true
}

find_codex_binary() {
  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return
  fi
  find "$state_dir/npm/projects" -type f -name codex -path "*@openai/codex-linux-*" -print -quit 2>/dev/null || true
}

report_status() {
  codex_home=$(find_codex_home)
  if [ -z "$codex_home" ]; then
    echo "codex ACP home: not generated yet - start the Gateway once, then rerun this."
  elif [ -f "$codex_home/auth.json" ]; then
    echo "codex ACP home: $codex_home (auth.json present)"
  else
    echo "codex ACP home: $codex_home (NO auth.json - run: openclaw-relay-auth codex)"
  fi

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "claude auth: CLAUDE_CODE_OAUTH_TOKEN is set (subscription-backed)"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "claude auth: ANTHROPIC_API_KEY is set (API billing, not subscription)"
  elif [ -f "$claude_home/.credentials.json" ]; then
    echo "claude auth: credential file present under $claude_home"
  else
    echo "claude auth: none found - set CLAUDE_CODE_OAUTH_TOKEN from 'claude setup-token'"
  fi
}

login_codex() {
  codex_home=$(find_codex_home)
  if [ -z "$codex_home" ]; then
    echo "The isolated Codex ACP home does not exist yet." >&2
    echo "Start the Gateway once so the acpx plugin generates it, then rerun this." >&2
    exit 69
  fi
  codex_binary=$(find_codex_binary)
  if [ -z "$codex_binary" ]; then
    echo "No Codex binary found under $state_dir. Confirm the acpx plugin is installed." >&2
    exit 69
  fi
  echo "Signing in to the isolated Codex ACP home: $codex_home"
  echo "This login is separate from OpenClaw's own OpenAI OAuth profile."
  CODEX_HOME="$codex_home" exec "$codex_binary" login "$@"
}

action=${1:-status}
if [ "$#" -gt 0 ]; then
  shift
fi

case "$action" in
  status) report_status ;;
  codex) login_codex "$@" ;;
  *)
    echo "Usage: openclaw-relay-auth [status|codex]" >&2
    exit 64
    ;;
esac
