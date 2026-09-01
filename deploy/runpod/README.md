# Run OpenClaw continuously on RunPod

This deployment runs the official OpenClaw image on a regular RunPod Pod and
uses a ChatGPT/Codex subscription through OAuth. It does not require an OpenAI
API key. For continuous service, keep the Pod in the Running state. The image
restarts OpenClaw whenever RunPod starts or restarts the container, but RunPod's
documented Pod lifecycle does not promise automatic resume after a Pod is
manually stopped or exits; an external monitor using the RunPod API would need
a separate RunPod API key.

This Pod is the always-on Telegram/control plane. The external application's
stateless, one-inference, scale-to-zero path is a separate deployment described
in `deploy/runpod-serverless/README.md`; separating them prevents Telegram long
polling from defeating Serverless scale-to-zero.

This one Pod serves both Telegram paths — see `deploy/README.md` for how all
three fit together:

- **Agentic coding (path 2).** An unbound Telegram DM. OpenClaw's own agent
  reads your instruction, plans, runs tools, and answers in its own voice. Every
  turn spends the model credits that drive OpenClaw.
- **Relay (path 3).** A Telegram DM bound with `/acp spawn claude --bind here`
  or `/acp spawn codex --bind here`. OpenClaw becomes pure transport: your text
  goes straight into Claude Code or the Codex CLI, and that harness's own final
  message — summary, question, or choice — comes back to you unchanged. OpenClaw
  performs no model inference of its own on this path.

Both use the same bot and the same repository checkout. `/acp close` unbinds and
returns the chat to path 2.

## Before you begin

- Use a Secure Cloud On-Demand or Reserved Pod, not Spot/Interruptible.
- Attach a Network Volume at `/workspace`. The OpenClaw state, OAuth profile,
  OAuth encryption key, Codex home, sessions, and workspace all live below
  `/workspace/openclaw`.
- Network Volumes are persistent but are not encrypted by RunPod. Treat the
  volume as sensitive, restrict account access, and keep an encrypted backup
  outside RunPod.
- Create a strong RunPod Secret named `openclaw_gateway_token`. Generate at
  least 32 random bytes; do not put the value in this repository or the image.
  For example, run `openssl rand -hex 32` locally and paste only its output into
  the RunPod Secret value.
- Create a Telegram bot with [BotFather](https://t.me/BotFather), then store its
  token in a second RunPod Secret named `telegram_bot_token`. The bot uses
  outbound long polling, so no Telegram webhook, domain, or inbound port is
  required.
- The HTTP proxy has a 100-second connection limit. The Control UI and normal
  chat work through it, but very long single HTTP/WebSocket operations may be
  interrupted by the proxy.
- For the relay path with Claude Code, get a subscription-backed token on your
  own machine with `claude setup-token` and store the result in a third RunPod
  Secret named `claude_code_oauth_token`. Anthropic bills that token against the
  signed-in Claude plan rather than per-token API credit. If you would rather pay
  API rates, set `ANTHROPIC_API_KEY` instead. Relaying to `codex` needs neither.

## Build and publish the image

Run from the repository root. Replace the registry path with a private image
repository you control:

```bash
docker build \
  -f deploy/runpod/Dockerfile \
  -t <registry>/openclaw-runpod:2026.7.2-beta.7 .
docker push <registry>/openclaw-runpod:2026.7.2-beta.7
```

The default base is OpenClaw `2026.7.2-beta.7`, pinned to its published GHCR
manifest digest. This matching build passed a live subscription-backed Codex
request; the published stable external plugin failed the OpenAI auth preflight.
Keep the pinned beta until a newer stable image passes the same smoke test, then
back up the volume and upgrade forward. Do not attach a database opened by this
beta to an older image. To test another published release, pass
`--build-arg OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:<version>@sha256:<digest>`.

The build installs two official external plugins at exactly the base version and
copies their state into the image:

| Plugin            | Build arg              | Role                                                    |
| ----------------- | ---------------------- | ------------------------------------------------------- |
| `@openclaw/codex` | `CODEX_PLUGIN_VERSION` | native app-server runtime for OpenClaw's own turns      |
| `@openclaw/acpx`  | `ACPX_PLUGIN_VERSION`  | ACP harness runtime that launches Codex and Claude Code |

`@openclaw/acpx@2026.7.2-beta.7` declares `compat.pluginApi >=2026.7.2-beta.7`,
so it pairs with this base exactly. Its pinned dependencies already contain the
Codex ACP and Claude Code ACP adapters, so a worker never fetches an adapter with
`npx` at run time. If you move the base image, move all three versions together.

## Create the RunPod template

Configure the template with:

| Setting                   | Value                                                                      |
| ------------------------- | -------------------------------------------------------------------------- |
| Container image           | `<registry>/openclaw-runpod:2026.7.2-beta.7`                               |
| Expose HTTP ports         | `18789`                                                                    |
| Volume mount path         | `/workspace`                                                               |
| Docker Entrypoint         | Leave empty                                                                |
| Container Start Command   | Leave empty                                                                |
| `OPENCLAW_GATEWAY_TOKEN`  | `{{ RUNPOD_SECRET_openclaw_gateway_token }}`                               |
| `TELEGRAM_BOT_TOKEN`      | `{{ RUNPOD_SECRET_telegram_bot_token }}`                                   |
| `DEEPSEEK_API_KEY`        | `{{ RUNPOD_SECRET_deepseek_api_key }}` — recommended, see below            |
| `TELEGRAM_OWNER_ID`       | Your numeric Telegram user id — skips the pairing handshake                |
| `CLAUDE_CODE_OAUTH_TOKEN` | `{{ RUNPOD_SECRET_claude_code_oauth_token }}` — only for Claude Code relay |
| `TZ`                      | An IANA zone such as `Europe/Paris`                                        |

Optional environment overrides:

| Variable                                   | Default           | Effect                                                |
| ------------------------------------------ | ----------------- | ----------------------------------------------------- |
| `OPENCLAW_CODE_WORKSPACE`                  | `/workspace/code` | Repository root the harnesses run in                  |
| `OPENCLAW_ACPX_PERMISSION_MODE`            | `approve-all`     | `approve-all`, `approve-reads`, or `deny-all`         |
| `OPENCLAW_ACPX_NONINTERACTIVE_PERMISSIONS` | `fail`            | `fail` aborts on a blocked prompt, `deny` degrades    |
| `OPENCLAW_ACPX_RUNTIME_STARTUP_PROBE`      | `0`               | `1` probes a harness before the Gateway reports ready |

Deploy the template as a Secure Cloud On-Demand/Reserved Pod with the Network
Volume attached. RunPod supplies `RUNPOD_POD_ID`; the startup wrapper uses it to
allow the exact Control UI origin:

```text
https://<POD_ID>-18789.proxy.runpod.net
```

If you put a stable HTTPS reverse proxy in front later, set
`OPENCLAW_CONTROL_UI_ORIGIN` to that exact origin and restart the Pod.

## First contact on Telegram

The bot reaches Telegram by outbound long polling: the Pod repeatedly asks
Telegram's servers whether anything arrived. Nothing connects inward, so there is
no webhook, no domain, and no port to open. The bot is reachable the moment the
Pod finishes starting.

Who is allowed to talk to it depends on one optional variable.

### With `TELEGRAM_OWNER_ID` set (recommended)

Get your numeric id from [@userinfobot](https://t.me/userinfobot) and put it in
the template. The wrapper then admits exactly that one account and nobody else.
Send the bot a message and it answers straight away — no pairing code, no Pod
terminal, nothing to approve.

### Without it

The channel starts in pairing mode. Your first message returns a one-time code
that has to be approved before the bot will talk, which needs a Pod terminal:

```bash
runuser -u node -- openclaw pairing list telegram
runuser -u node -- openclaw pairing approve telegram <PAIRING_CODE>
```

The first approved account becomes the owner. You can name the owner later at any
time by setting the variable and restarting the Pod.

Either way the template accepts direct messages only, disables groups and
Telegram-initiated config writes, and routes execution approvals to private
inline buttons.

Telegram is the full OpenClaw control plane: messages may create agent turns,
use tools, and request execution approval. It is deliberately separate from
the stateless one-inference endpoint in `deploy/runpod-serverless/`.

## Recommended: let the agent set itself up

Every other credential here needs a browser, which a Pod does not have. A plain
API key does not. Set `DEEPSEEK_API_KEY` and the Pod boots with a working agent
on its very first start, before any login exists.

The startup wrapper detects the key and selects `deepseek/deepseek-v4-pro` as the
bootstrap model. Without the key it selects the OpenAI subscription model, which
cannot answer until someone completes a login first.

That changes the setup from a terminal session into a conversation:

1. Pair Telegram with the bot.
2. Ask the agent to sign in to ChatGPT. It runs the device-code login, requests
   your approval through the inline buttons, and sends you the URL and code.
3. Open the link on your phone or laptop and sign in.
4. Ask it to run `openclaw-relay-auth status`, then have it sign the Codex ACP
   harness in the same way.

No Pod terminal, no copied files. DeepSeek is a pay-per-token key and this agent
only spends it while orchestrating; the coding work itself runs on the
subscriptions. You can switch the brain to a subscription model afterwards:

```bash
openclaw config set agents.defaults.model.primary openai/gpt-5.6-sol
```

If you send the agent a secret over Telegram, remember the value then exists in
that chat history. Prefer flows where the agent shows you a link to approve
rather than ones where you paste a credential to it.

## How your real accounts reach the Pod

The Pod is a separate host. **Nothing carries over from the machine you develop
on**, and no credential file should be copied there. Each account is connected on
the Pod itself, through a flow you complete in your own browser.

| What                                      | Where you run it | How your account connects                                                     |
| ----------------------------------------- | ---------------- | ----------------------------------------------------------------------------- |
| OpenClaw's OpenAI login (path 2)          | Pod terminal     | Device code: the Pod prints a URL and short code, you open it in your browser |
| Codex ACP harness (path 3)                | Pod terminal     | `openclaw-relay-auth codex` signs in to the isolated Codex home               |
| Claude Code (path 3)                      | **your machine** | `claude setup-token` exports a portable token from your existing login        |
| Anthropic for OpenClaw's turns (optional) | Pod terminal     | The same setup-token, stored as an OpenClaw auth profile                      |

Claude Code is the one credential that originates on your machine, because it has
no device-code flow for a remote host and its credential reuse assumes the same
host. That export is deliberate and produces a token, not a copied file.

Do not copy `~/.codex/auth.json` or `~/.claude/.credentials.json` to the Pod. A
dropped-in Codex credential file is not a runtime auth store and will not be
used; importing one requires an explicit `openclaw migrate` run. Device login
avoids the problem entirely.

Two consequences worth planning around:

- Signing in on the Pod does not sign you out on your laptop. The OAuth sessions
  are independent.
- Usage limits are per account, not per host. Whatever the Pod consumes comes out
  of the same subscription quota you use locally.

Order matters: start the Pod before signing anything in. The isolated Codex home
for the relay path is generated on first Gateway boot and does not exist before
that.

## Sign in with the ChatGPT subscription

Open the Pod terminal and run this once:

```bash
runuser -u node -- \
  openclaw models auth login --provider openai --device-code
```

Open the displayed URL on your own computer, enter the one-time code, and
complete ChatGPT sign-in. If device-code login is unavailable for the account,
use the browser flow and paste the returned redirect URL:

```bash
runuser -u node -- \
  openclaw models auth login --provider openai
```

Do not copy `~/.codex/auth.json` into the image. OpenClaw owns and refreshes its
OAuth profile in the persistent state directory.

Check the account and available subscription models:

```bash
runuser -u node -- \
  openclaw models auth list --provider openai
runuser -u node -- \
  openclaw models list --provider openai
```

Restart the Pod once after the first login, then prove the complete route with
a real request:

```bash
runuser -u node -- \
  openclaw agent --local --agent main \
  --message 'Reply exactly: OK' --json --timeout 120
```

The result must contain `OK`, provider `openai`, `agentHarnessId: codex`, and
`fallbackUsed: false`. A `No API key found for provider "openai"` error means
the OAuth profile was not stored in the mounted volume; repeat device login as
the `node` user and confirm `/workspace/openclaw` is the active volume.

The initial model is `openai/gpt-5.6-sol`, pinned to the Codex runtime so it
fails closed instead of falling back to API-key billing. Availability depends
on the signed-in ChatGPT plan/workspace. If it is absent, select an advertised
model and pin that model to Codex too, for example:

```bash
runuser -u node -- \
  openclaw config set agents.defaults.model.primary openai/gpt-5.5
runuser -u node -- \
  openclaw config set 'agents.defaults.models["openai/gpt-5.5"].agentRuntime.id' codex
```

## Optional: run OpenClaw's own agent on the Claude subscription

Path 2 ships on the OpenAI subscription. The `anthropic` plugin is also in the
allowlist, so you can move OpenClaw's own turns to a Claude plan without
rebuilding the image. This is separate from the Claude Code relay in path 3:
here Claude answers _as OpenClaw_, and every turn still spends model credit.

Run `claude setup-token` on a machine with Claude Code installed. It prints a
long-lived token starting with `sk-ant-oat01-`. Store it as an OpenClaw auth
profile on the volume:

```bash
runuser -u node -- \
  openclaw models auth login --provider anthropic --method setup-token
```

Then point the default agent at a Claude model:

```bash
runuser -u node -- \
  openclaw config set agents.defaults.model.primary anthropic/claude-opus-5
```

Billing note from the upstream provider docs: subscription-plan Agent SDK,
`claude -p`, and third-party app usage all draw from the signed-in
subscription's usage limits, and Anthropic's separate Agent SDK credit plan is
paused. Anthropic can change this without an OpenClaw release, so re-check
before depending on it for volume work. An Anthropic API key remains the
predictable path for shared production automation.

## Prepare the code workspace

Both coding paths operate on a real checkout, not on OpenClaw's own session
workspace. The startup wrapper creates `/workspace/code` on the volume and points
the ACP harnesses at it. Clone what you want worked on:

```bash
runuser -u node -- git clone <repo-url> /workspace/code/<name>
```

A harness started with no explicit directory runs in `/workspace/code`. Send
`/acp cwd /workspace/code/<name>` in the bound chat to narrow it to one repo, or
pass `--cwd` at spawn time.

## Authenticate the relay harnesses

The ACP harnesses do **not** inherit the OpenAI login you just completed. That
login belongs to OpenClaw's own OAuth profile and drives path 2. The relay
harnesses are separate processes with separate credentials, and each needs one
setup step. This is a deliberate upstream boundary, not a gap in this template.

| Harness      | How acpx launches it                                    | Credential it uses                                                     |
| ------------ | ------------------------------------------------------- | ---------------------------------------------------------------------- |
| `codex` ACP  | isolated `CODEX_HOME` generated by the acpx auth bridge | its own `auth.json` inside that isolated home                          |
| `claude` ACP | plain copy of the Gateway process environment           | `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, or `CLAUDE_CONFIG_DIR` |

OpenClaw copies model, provider, and project-trust settings from the host Codex
config into the isolated home and deliberately leaves auth behind, so the Codex
ACP harness starts unauthenticated even when path 2 works perfectly.

Start the Gateway once so the acpx plugin generates its home, then check both:

```bash
runuser -u node -- openclaw-relay-auth status
```

Sign the Codex ACP harness in against its isolated home. The helper locates that
home and the managed Codex binary for you, and passes any extra flags straight
through to `codex login`:

```bash
runuser -u node -- openclaw-relay-auth codex
```

The credential lands on the Network Volume, so it survives Pod restarts. Run
`openclaw-relay-auth codex --help` to see which login flows your Codex build
supports.

Claude Code needs no login inside the Pod: set `CLAUDE_CODE_OAUTH_TOKEN` from
`claude setup-token` as described in "Before you begin", restart the Pod, and
`openclaw-relay-auth status` will confirm it. Nothing refreshes that token for
you, so re-issue it when it expires.

## The relay path

This is the path where OpenClaw spends nothing on inference. Bind the DM once:

```text
/acp spawn claude --bind here
```

Use `codex` in place of `claude` for the Codex CLI. Add a directory if you want
one repo rather than the whole workspace:

```text
/acp spawn claude --bind here --cwd /workspace/code/<name>
```

From then on:

- Plain messages you send go straight into that harness session as the prompt.
  OpenClaw does not read them, plan around them, or answer them itself.
- What the harness posts when it finishes — its own summary, a question it wants
  answered, a choice it wants confirmed — is delivered back to the same DM.
- Your reply goes back into the same session, so answering a question is just
  typing the answer.
- The binding is stored, so it survives a Gateway restart and a Pod restart.

Controls stay local and never reach the harness as prompt text:

| Command             | Effect                                                       |
| ------------------- | ------------------------------------------------------------ |
| `/acp status`       | Backend, mode, session ids, effective runtime options        |
| `/acp doctor`       | Backend health and the concrete fix when it is unhealthy     |
| `/acp cwd <path>`   | Move the harness to another checkout                         |
| `/acp model <ref>`  | Model override, when that harness advertises model switching |
| `/acp steer <text>` | Nudge a running turn without replacing its context           |
| `/acp cancel`       | Abort the current turn, keep the session and binding         |
| `/acp close`        | End the session, unbind, and return this DM to path 2        |

Run `/acp doctor` before trusting the path. It must report an enabled, healthy
`acpx` backend. If it reports a missing allowlist entry, `plugins.allow` lost
`acpx`; the startup wrapper rewrites that list on every boot, so restart the Pod.

### Prove the relay end to end

Unit-level checks do not prove this path; only a real round trip does. From the
paired Telegram DM:

1. `openclaw-relay-auth status` in the Pod terminal — expect a credential for the
   harness you are about to test. Then `/acp doctor` in the DM — expect an
   enabled, healthy `acpx` backend.
2. `/acp spawn codex --bind here` — expect a spawn confirmation.
3. Send `Reply with exactly RELAY-OK` as a plain message.
4. Expect `RELAY-OK` back. It came from the Codex CLI, not from an OpenClaw turn.
5. Send `Read README.md and tell me its first heading` — expect a real answer
   from the checkout, which proves the harness has the workspace.
6. `/acp status` — expect the session id and `cwd` you intended.
7. `/acp close`, then send a plain message and confirm OpenClaw's own agent
   answers again. That proves path 2 and path 3 switch cleanly.

Repeat steps 2-6 with `claude` once `CLAUDE_CODE_OAUTH_TOKEN` is set. A vendor
auth error at step 2 means the token is missing or expired in the Pod
environment, not that OpenClaw is misconfigured.

| Symptom                                              | Cause                                                                              | Fix                                                                                                       |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ACP runtime backend is not configured`              | `acpx` missing, disabled, or not in `plugins.allow`                                | Restart the Pod; if it persists, install the plugin as shown above                                        |
| Vendor auth error from `claude`                      | No `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` in the Pod environment         | Add the RunPod Secret and restart                                                                         |
| Vendor auth error from `codex` while path 2 works    | The isolated Codex ACP home has no `auth.json`; path 2 uses a different credential | Run `openclaw-relay-auth codex`                                                                           |
| `PermissionPromptUnavailableError`                   | `permissionMode` is not `approve-all`                                              | Restore `approve-all`, or set `OPENCLAW_ACPX_NONINTERACTIVE_PERMISSIONS=deny` to degrade instead of crash |
| Plain messages answered by OpenClaw, not the harness | Nothing is bound in this DM                                                        | Run `/acp spawn <harness> --bind here` and check `/acp status`                                            |
| Harness works but edits the wrong tree               | Default `cwd` is the whole workspace                                               | `/acp cwd /workspace/code/<name>`                                                                         |

### What the relay cannot forward

An ACP harness session has no TTY, so a harness-level permission prompt — "may I
write this file", "may I run this command" — cannot be turned into a Telegram
button. This deployment therefore sets `permissionMode=approve-all`, which means
**the harness writes files and runs shell commands inside this Pod without asking
you first**. That is what makes headless coding work, and it is a real boundary
worth understanding:

- The harness can read and write anything the `node` user can reach on the Pod,
  including the whole `/workspace` volume, and can reach the network.
- OpenClaw's sandbox does not wrap ACP harness execution. OpenClaw still enforces
  which harnesses are allowed, who owns the binding, and where output is
  delivered.
- Keep credentials that must not be readable by a coding agent off this volume.
- To trade capability for containment, set `OPENCLAW_ACPX_PERMISSION_MODE` to
  `approve-reads` and `OPENCLAW_ACPX_NONINTERACTIVE_PERMISSIONS` to `deny`. The
  harness will then decline writes and exec instead of crashing on them — useful
  for a review-only or read-only relay.

Questions the harness asks in its message text are relayed normally. Only the
tool-permission prompts are auto-answered.

### Persistent bindings instead of a chat command

For a binding that is declared in config rather than created from chat, define an
ACP-runtime agent and bind a Telegram forum topic to it. This shape is validated
against the config schema:

```json5
{
  agents: {
    entries: {
      main: { default: true },
      claude: {
        runtime: {
          type: "acp",
          acp: { agent: "claude", backend: "acpx", mode: "persistent" },
        },
      },
    },
  },
  bindings: [
    {
      type: "acp",
      agentId: "claude",
      match: {
        channel: "telegram",
        accountId: "default",
        peer: { kind: "group", id: "<chatId>:topic:<topicId>" },
      },
      acp: { cwd: "/workspace/code/<name>" },
    },
  ],
}
```

Topic bindings need a forum-enabled group, so they also need
`channels.telegram.groupPolicy` relaxed from this template's `disabled`. The DM
`--bind here` route needs no group and no policy change; prefer it unless you
want several always-on harness lanes side by side.

## Verify and operate

From the Pod terminal:

```bash
curl -fsS http://127.0.0.1:18789/healthz
curl -fsS http://127.0.0.1:18789/readyz
runuser -u node -- openclaw models status
runuser -u node -- openclaw security audit --deep
```

Open the RunPod proxy URL and authenticate with the gateway token. Never expose
port 18789 without that token. Back up `/workspace/openclaw`; a Network Volume
survives Pod replacement, but RunPod does not treat it as a long-term backup.

Current RunPod lifecycle docs allow stopping and starting a Pod while preserving
`/workspace` on the Network Volume; terminating and redeploying against the same
volume also preserves it. Keep sufficient RunPod credit, because an account
unable to pay for storage can eventually lose the volume.

### Existing volumes and the plugin seed

The image ships a pre-installed plugin state and copies it onto a **fresh**
volume only. An existing volume is never overwritten, because that state holds a
live database and refreshable OAuth profiles. If you attach a volume created
before `acpx` was part of this deployment, the Pod stops at boot and prints the
exact one-time command:

```bash
runuser -u node -- openclaw plugins install npm:@openclaw/acpx@2026.7.2-beta.7
```

Run it in the Pod terminal, restart the Pod, and the check passes from then on.
Starting from a fresh Network Volume is the alternative.

## Update OpenClaw

Build a new image from a published stable OpenClaw tag, redeploy it against the
same Network Volume, then verify `/healthz`, `/readyz`, and
`openclaw models status`. If a
startup migration fails, run this from the Pod terminal with the same image and
volume before restarting:

```bash
runuser -u node -- openclaw doctor --fix
```

Relevant upstream guides:

- https://docs.openclaw.ai/providers/openai
- https://docs.openclaw.ai/install/docker
- https://docs.openclaw.ai/tools/acp-agents
- https://docs.openclaw.ai/tools/acp-agents-setup
- https://docs.runpod.io/storage/network-volumes
- https://docs.runpod.io/pods/configuration/expose-ports
