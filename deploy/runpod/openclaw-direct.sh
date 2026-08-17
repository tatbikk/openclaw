#!/usr/bin/env bash
# Direct path for a RunPod deployment: one message in, one JSON result out.
#
# Thin wrapper over `openclaw agent exec --json` so an external program can call
# Codex through OpenClaw over `runpodctl exec` or SSH and parse a stable
# envelope from stdout. It never passes --state-dir, so the run uses ephemeral
# session state and cannot contend with the Gateway that owns the coding and
# relay paths on the same pod.
#
#   openclaw-direct "Summarize the failing test"
#   echo "Summarize the failing test" | openclaw-direct
#
# stdout: the `agent exec --json` envelope, unchanged.
# stderr: diagnostics only.
# exit:   0 ok, 1 model/result error, 2 timeout (passed through from exec).
set -euo pipefail

TOOL="openclaw-direct"
CONFIG_PATH="${OPENCLAW_DIRECT_CONFIG:-${OPENCLAW_CONFIG_PATH:-/workspace/.openclaw/openclaw.json}}"
WORK_DIR="${OPENCLAW_DIRECT_CWD:-/workspace/repo}"
# `openai/*` agent refs resolve to the Codex harness, so the direct path stays
# on Codex even when the Gateway's default agent runs another model.
MODEL="${OPENCLAW_DIRECT_MODEL:-openai/gpt-5.6-sol}"
TIMEOUT_SECONDS="${OPENCLAW_DIRECT_TIMEOUT:-600}"
OPENCLAW_BIN="${OPENCLAW_DIRECT_BIN:-openclaw}"

fail() {
  echo "ERROR: $*" >&2
  echo "[$TOOL] FAILED (exit 1)" >&2
  exit 1
}

if [[ $# -gt 1 ]]; then
  fail "Usage: $TOOL [message]  (omit the argument or pass - to read stdin)"
fi

MESSAGE="${1:--}"
if [[ "$MESSAGE" == "-" ]]; then
  MESSAGE="$(cat)"
fi
[[ -n "${MESSAGE//[[:space:]]/}" ]] || fail "Empty message."

command -v "$OPENCLAW_BIN" >/dev/null 2>&1 ||
  fail "openclaw not found on PATH; set OPENCLAW_DIRECT_BIN."
[[ -f "$CONFIG_PATH" ]] ||
  fail "Config not found at $CONFIG_PATH; set OPENCLAW_DIRECT_CONFIG."
[[ -d "$WORK_DIR" ]] ||
  fail "Working directory not found at $WORK_DIR; set OPENCLAW_DIRECT_CWD."

# --message-file - keeps the prompt off argv, so newlines and shell
# metacharacters survive `runpodctl exec` and SSH command strings intact.
set +e
printf '%s' "$MESSAGE" | "$OPENCLAW_BIN" agent exec \
  --message-file - \
  --json \
  --config "$CONFIG_PATH" \
  --cwd "$WORK_DIR" \
  --model "$MODEL" \
  --timeout "$TIMEOUT_SECONDS"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "[$TOOL] FAILED (exit $status)" >&2
fi
exit "$status"
