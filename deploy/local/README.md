# Run OpenClaw locally on Windows with a ChatGPT subscription

This helper keeps Node, OpenClaw, configuration, the OAuth profile, and the
workspace below the repository's ignored `.local/openclaw` directory. It does
not use an OpenAI API key or modify the system Node installation.

Open PowerShell in the repository root and run:

```powershell
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 install
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 use-codex-login
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 smoke
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 start
```

`use-codex-login` verifies that the plugin-managed Codex binary can see the
existing ChatGPT sign-in, then tells the OpenClaw runtime to share that
user-scoped login.
The helper sets `CODEX_HOME` explicitly because the managed Codex binary does
not reliably infer the Codex Desktop home on Windows. It does not copy
`~/.codex/auth.json` or use an API key.

`smoke` runs the auth preflight and makes a real one-shot request. Success must
show `OK`, provider `openai`, model `gpt-5.6-sol`, harness `codex`, and
`fallbackUsed: false`. The `costUsd` field is an estimate in run metadata; this
path is authenticated by the ChatGPT subscription, not an API key.

The `install` action restricts the versioned state directory ACL to the current
Windows account and SYSTEM. If you restore the directory from a backup or move
it from another disk, run the `harden` action before starting the gateway.

To keep a separate, agent-scoped OpenClaw OAuth profile instead, use `login`.
It opens the official OpenAI browser flow. On a headless host, use the
device-code action instead:

```powershell
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 login-device
```

With an agent-scoped OpenClaw login, verify the stored profile with:

```powershell
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 auth
```

Keep the `start` terminal open. In a second terminal, open the authenticated
Control UI and run the security audit:

```powershell
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 dashboard
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 audit
```

Use the `audit-deep` action when Docker is healthy and you want the slower
container-aware checks as well.

The helper pins OpenClaw and the Codex plugin to matching
`2026.7.2-beta.7` builds and pins Node `24.18.1`; the Node archive is accepted
only when its SHA-256 checksum matches the value published by Node.js. This
beta pairing is deliberate: the published stable plugin `2026.7.1-1` failed
the OpenAI auth preflight before it could delegate authentication to Codex.
The beta uses its own `.local/openclaw/state-2026.7.2-beta.7` directory and does
not upgrade the earlier `.local/openclaw/state` database. Do not downgrade the
runtime against the beta state; wait for a newer stable pair, back up
`.local/openclaw`, then upgrade both packages together.

The initial model is `openai/gpt-5.6-sol`, pinned to the Codex runtime so it
fails closed instead of falling back to API-key billing. Model availability
depends on the signed-in ChatGPT account, so use the `models` action and select
and pin `openai/gpt-5.5` if GPT-5.6 is not advertised.

## Test the relay path locally

`install` also installs `@openclaw/acpx` at the matching `2026.7.2-beta.7` and
enables the ACP relay, so you can prove the wiring before paying for a Pod. The
relay is the path where OpenClaw forwards your message to Codex CLI or Claude
Code and sends the harness's own reply back, spending nothing on OpenClaw's own
model. See `deploy/README.md` for how it relates to the other two paths.

```powershell
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 relay-status
```

Then, with the gateway running, open the Control UI chat and bind it:

```text
/acp doctor
/acp spawn codex --bind here
```

Plain messages now go straight to the Codex CLI; `/acp close` gives the chat back
to OpenClaw's own agent.

Locally the harness starts **read-only**: `permissionMode=approve-reads` with
`nonInteractivePermissions=deny`, so writes and shell commands are declined
rather than performed on your machine. That is enough to prove a round trip. An
ACP session has no TTY, so the only way to let a harness actually edit code is to
auto-approve everything:

```powershell
powershell -ExecutionPolicy Bypass -File deploy/local/openclaw-local.ps1 relay-write-on
```

OpenClaw does not sandbox ACP harness execution, so after `relay-write-on` the
coding CLI writes files and runs commands with your Windows account's rights, not
just inside `.local/openclaw/code`. Use `relay-write-off` to return to read-only.
Restart the gateway after either switch.

Claude Code needs its own credential in the terminal that runs `start`. Use
`claude setup-token` for a subscription-backed token:

```powershell
$env:CLAUDE_CODE_OAUTH_TOKEN = '<token from claude setup-token>'
```

`relay-status` reports whether that variable or `ANTHROPIC_API_KEY` is visible.
Relaying to `codex` needs neither.
