---
summary: "Run OpenClaw on a RunPod Pod with a direct scripted path, a Telegram coding path, and a relay path"
title: RunPod
read_when:
  - Deploying OpenClaw on a RunPod Pod with persistent storage
  - Driving Codex or Claude Code from another program, Telegram, or both on one pod
  - Choosing between a scripted one-shot run and a bound coding session
---

**Goal:** one OpenClaw Gateway on a [RunPod](https://www.runpod.io) Pod that serves three
independent entry paths into the same workspace and credentials.

## The three paths

Each path is a different owner of the model loop. Pick per conversation; they coexist on one pod.

| Path       | Who drives it             | Who owns the loop              | Use it for                                                     |
| ---------- | ------------------------- | ------------------------------ | -------------------------------------------------------------- |
| **Direct** | Another program, over SSH | One-shot `openclaw agent exec` | Fast request and response into Codex, returned as JSON         |
| **Coding** | You, over Telegram        | OpenClaw                       | Agent work: OpenClaw plans, calls the harness, runs tests      |
| **Relay**  | You, over Telegram        | Codex or Claude Code           | Passthrough: the harness asks, you answer, OpenClaw carries it |

The difference between **coding** and **relay** is who decides. In the coding path OpenClaw
runs its own agent turn and treats the harness as a tool. In the relay path OpenClaw adds no
model of its own: your message goes straight to the bound harness session, and what comes back
is the harness's own summary, question, or confirmation request, answered by your next message.

Telegram connects outbound, so the coding and relay paths need no exposed pod port. Only the
Control UI and the direct path need inbound access.

## What you need

- A RunPod account with a Pod (CPU is enough; no GPU required) and an SSH key added under account settings.
- A [network volume](https://docs.runpod.io/storage/network-volumes) so state survives pod restarts. Cluster network volumes mount at `/workspace`.
- Model auth: a ChatGPT/Codex subscription login or an OpenAI API key. Add Anthropic auth if you want Claude Code in the relay path.
- A Telegram bot token from [@BotFather](https://t.me/botfather) and your numeric Telegram user id for the coding and relay paths.

## Create the pod

<Steps>
  <Step title="Deploy the image">
    Create a Pod from the official image and attach the network volume at `/workspace`:

    ```
    Container image:  ghcr.io/openclaw/openclaw:latest
    Volume mount path: /workspace
    ```

    The default image already bundles the `codex` plugin, so the Codex harness needs no extra install.

    Set these container environment variables so every path reads the same state, config, and workspace off the volume:

    ```bash
    OPENCLAW_STATE_DIR=/workspace/.openclaw
    OPENCLAW_CONFIG_DIR=/workspace/.openclaw
    OPENCLAW_CONFIG_PATH=/workspace/.openclaw/openclaw.json
    OPENCLAW_WORKSPACE_DIR=/workspace/repo
    OPENCLAW_GATEWAY_TOKEN=<a long random string>
    ```

    Leave the container command at the image default (`node openclaw.mjs gateway`) for now; the
    next step fixes volume ownership before the Gateway should hold state.

  </Step>

  <Step title="Fix volume ownership once">
    The image runs as the non-root `node` user (uid 1000), and a freshly attached RunPod volume is
    root-owned. Open a web terminal or SSH in as root and hand the volume to `node` a single time:

    ```bash
    mkdir -p /workspace/.openclaw /workspace/repo /workspace/bin
    chown -R 1000:1000 /workspace/.openclaw /workspace/repo /workspace/bin
    chmod 700 /workspace/.openclaw
    ```

    Skipping this is the most common first-run failure on RunPod: the Gateway starts, then every
    write into the state directory fails with `EACCES`.

  </Step>

  <Step title="Create the config and sign in">
    Run onboarding as the `node` user to write `/workspace/.openclaw/openclaw.json` and store model auth:

    ```bash
    openclaw onboard
    openclaw models auth login --provider openai
    ```

    Model credentials live under the state directory, so they persist with the volume and are
    shared by all three paths.

  </Step>

  <Step title="Expose the Control UI (optional)">
    Add port `18789` to the pod's exposed HTTP ports and start the Gateway bound to `lan`:

    ```bash
    openclaw gateway --bind lan --port 18789
    ```

    The Control UI is then at `https://<POD_ID>-18789.proxy.runpod.net`. Binding to `lan` publishes
    the Gateway, so `OPENCLAW_GATEWAY_TOKEN` must be set before you expose the port. See
    [Gateway security](/gateway/security) for the full hardening checklist.

    RunPod's HTTP proxy sits behind Cloudflare and cuts requests at roughly 100 seconds, which also
    ends long-lived Control UI WebSocket sessions. For a stable UI connection, expose `18789` as a
    **TCP** port instead and connect to `RUNPOD_PUBLIC_IP` on the mapped `RUNPOD_TCP_PORT_18789`.

  </Step>
</Steps>

## Path 1: direct

Another program sends one message to Codex and reads one JSON object back. Copy
`deploy/runpod/openclaw-direct.sh` from the repo onto the volume:

```bash
install -m 0755 openclaw-direct.sh /workspace/bin/openclaw-direct
```

Call it over SSH, passing the prompt on stdin:

```bash
echo "Summarize the failing test in src/agents" |
  ssh -p "$RUNPOD_TCP_PORT_22" "root@$RUNPOD_PUBLIC_IP" /workspace/bin/openclaw-direct
```

stdout carries only the [`agent exec --json`](/cli/agent#agent-exec) envelope, so the calling
program can parse it directly:

```json
{ "ok": true, "status": "ok", "final": "...", "model": "gpt-5.6-sol", "provider": "openai" }
```

Diagnostics go to stderr, and the exit code is `0` for success, `1` for a model or result error,
and `2` for a timeout. On failure the last stderr line is `[openclaw-direct] FAILED (exit N)`.

Use SSH rather than an HTTP route through the RunPod proxy: agent runs routinely outlast the
proxy's ~100 second ceiling, and a cut-off request loses the result of work that already ran.

The script is a thin wrapper over `openclaw agent exec`, which runs the turn embedded and reads
the pod's config, plugins, and stored credentials. It deliberately passes no `--state-dir`, so the
run uses ephemeral session state and never contends with the Gateway holding the state lock for
the other two paths. Override the defaults with `OPENCLAW_DIRECT_CONFIG`, `OPENCLAW_DIRECT_CWD`,
`OPENCLAW_DIRECT_MODEL`, and `OPENCLAW_DIRECT_TIMEOUT`.

## Path 2: coding over Telegram

OpenClaw owns the turn, and the harness executes it. Add Telegram plus a coding agent to
`/workspace/.openclaw/openclaw.json`:

```json5
{
  channels: {
    telegram: {
      enabled: true,
      botToken: "<bot token>",
      dmPolicy: "pairing",
      allowFrom: ["<your telegram user id>"],
    },
  },
  tools: { profile: "coding" },
  agents: {
    defaults: {
      model: "openai/gpt-5.6-sol",
      workspace: "/workspace/repo",
    },
  },
}
```

`openai/gpt-5.6-sol` resolves to the Codex harness, so OpenClaw's agent turn executes inside Codex
app-server while OpenClaw keeps sessions, approvals, and Telegram delivery. To run the same path
through Claude Code instead, keep the model ref canonical and put the backend in model-scoped
runtime policy:

```json5
{
  agents: {
    defaults: {
      model: "anthropic/claude-opus-5",
      workspace: "/workspace/repo",
      models: {
        "anthropic/claude-opus-5": { agentRuntime: { id: "claude-cli" } },
      },
    },
  },
}
```

Restart the Gateway, DM the bot, and approve the first pairing request with
`openclaw pairing list telegram`. See [Telegram](/channels/telegram) for group and topic policy,
and [Agent runtimes](/concepts/agent-runtimes) for how runtime selection resolves.

## Path 3: relay

OpenClaw carries messages and nothing else. Your Telegram message goes straight into a bound
harness session; the harness's own final message comes back to the chat, and your reply to it is
relayed back in. Approval prompts arrive the same way, as a question you answer in chat.

Install the ACP backend and the harness CLI you want to relay, then restart the Gateway:

```bash
openclaw plugins install @openclaw/acpx
```

Bind one Telegram conversation to a persistent ACP session:

```json5
{
  acp: {
    enabled: true,
    backend: "acpx",
    defaultAgent: "codex",
    allowedAgents: ["claude", "codex"],
  },
  agents: {
    entries: {
      relay: {
        runtime: {
          type: "acp",
          acp: {
            agent: "codex",
            backend: "acpx",
            mode: "persistent",
            cwd: "/workspace/repo",
          },
        },
      },
    },
  },
  bindings: [
    {
      type: "acp",
      agentId: "relay",
      match: {
        channel: "telegram",
        peer: { kind: "group", id: "<chatId>:topic:<topicId>" },
      },
    },
  ],
}
```

Set `acp.agent` to `claude` for Claude Code or `codex` for the Codex CLI; both relay the same way.
A Telegram forum topic is the cleanest binding target because it keeps the relay conversation
separate from the coding path in the same group.

For an ad-hoc relay without config changes, bind from chat instead. With the bundled `codex`
plugin, `/codex bind` attaches the current conversation to a native Codex thread, and
`/codex detach` releases it. `/acp spawn claude --bind here --cwd /workspace/repo` does the same
through ACP for Claude Code. Bound follow-up messages go directly to that session until the
binding is closed. See [ACP agents](/tools/acp-agents) and
[Codex harness](/plugins/codex-harness) for the full command surface.

## Keep the Gateway running

RunPod restarts a container without preserving processes, so let the pod start the Gateway
directly. Set the pod's container start command to:

```bash
node openclaw.mjs gateway --bind lan --port 18789
```

State, config, credentials, and the workspace all live on `/workspace`, so a restarted pod
resumes with the same sessions and Telegram pairings.

## Troubleshooting

- **`EACCES` writing state:** the volume is still root-owned. Rerun the `chown -R 1000:1000` step as root.
- **Control UI disconnects after ~100 seconds:** that is the RunPod HTTP proxy timeout. Expose `18789` as a TCP port and connect over `RUNPOD_PUBLIC_IP`.
- **Direct path fails with a state lock error:** something added `--state-dir` pointing at the Gateway's directory. The direct path must keep ephemeral state while the Gateway runs.
- **Telegram bot silent:** check pairing with `openclaw pairing list telegram`, and confirm `allowFrom` holds your numeric user id.
- **Relay path answers like a normal agent:** the conversation is not bound. Check `/codex binding` or the `bindings[]` entry's `match.peer.id`.
