# Three OpenClaw paths on RunPod

This directory holds three deployments. They exist because the three ways you
want to reach a coding model have genuinely different cost, latency, and state
requirements. Do not try to collapse them into one endpoint.

| Path                   | Where it runs                 | Who thinks                        | Entry point                         | OpenClaw model spend |
| ---------------------- | ----------------------------- | --------------------------------- | ----------------------------------- | -------------------- |
| 1. Direct / fast       | `runpod-serverless/`          | one model call, nothing else      | HTTP `POST /runsync`                | one inference        |
| 2. Agentic coding      | `runpod/` (Telegram DM)       | OpenClaw's own agent              | Telegram message                    | yes, every turn      |
| 3. Relay / passthrough | `runpod/` (bound Telegram DM) | Codex CLI or Claude Code directly | Telegram message after `/acp spawn` | none                 |

`local/` is the Windows helper for running and testing the same stack on your
own machine before paying RunPod for it.

## Publishing the images

Two routes. Prefer GitHub Actions unless you specifically want a local image.

### On GitHub (no local Docker needed)

The **RunPod Deploy Images** workflow builds both images for `linux/amd64` and
pushes them to your own GHCR namespace. It needs no secret: Actions supplies the
token. Run it from the repository's **Actions** tab, choose `both`, `pod`, or
`serverless`, and set the tag.

Two things to know the first time:

- On a fork, GitHub disables Actions until you enable them once on the Actions
  tab. The workflow only ever runs when you press the button.
- A newly published GHCR package is **private**, and RunPod cannot pull a private
  image anonymously. Either make it public under **Packages > Package settings >
  Change visibility**, or add registry credentials in RunPod.

The run summary prints the exact image reference to paste into RunPod.

### Locally

`publish.ps1` does the same on your machine. Log in to your registry first, in
your own terminal, so no credential is ever passed as a script argument or stored
here:

```powershell
docker login ghcr.io
powershell -ExecutionPolicy Bypass -File deploy/publish.ps1 -Registry ghcr.io/<you>
```

Add `-Target pod` or `-Target serverless` to publish one image, and `-SkipPush`
to build without publishing. This route needs a working Docker daemon, which on
Windows means CPU virtualization enabled in firmware plus the WSL2 backend.

## Path 1 — direct, one call, back fast

An external program posts a prompt and gets text back. No agent turn, no tools,
no conversation state, no session. Scale-to-zero Serverless worker.

```text
your app -> RunPod /runsync -> openclaw infer model run -> OpenAI -> text
```

Use it when the other program owns the conversation and only needs an answer.
See `runpod-serverless/README.md`. Reference client: `runpod-serverless/client.py`.

## Path 2 — agentic coding through Telegram

You send an instruction in Telegram. OpenClaw's agent reads it, decides what to
do, runs tools, edits files, runs tests, spawns Codex or Claude Code as harness
sessions when useful, and reports back in its own voice. This is the path where
OpenClaw is the orchestrator, so **every turn consumes the model credits that
drive OpenClaw itself**.

Use it when you want judgment, multi-step planning, and tool use between your
message and the result.

## Path 3 — relay, no OpenClaw thinking

You bind the Telegram conversation to a coding harness once:

```text
/acp spawn claude --bind here
```

After that, OpenClaw is a wire. Your message goes straight to Claude Code (or
Codex). When the harness finishes and posts its summary — or asks a question, or
asks you to pick an option — that message comes back to Telegram verbatim. Your
answer goes straight back into the same harness session. OpenClaw runs no model
inference of its own on this path, so it costs nothing from the budget that
powers OpenClaw.

```text
Telegram -> OpenClaw (transport only) -> Claude Code / Codex -> Telegram
```

Use it when you already know what you want done and only need a phone-shaped
front end for a real coding CLI.

Paths 2 and 3 live on the same always-on Pod and use the same Telegram bot. The
only difference is whether the conversation is bound. `/acp close` unbinds and
returns that chat to path 2. Full runbook: `runpod/README.md`.

They do **not** share one credential. Path 2 runs on OpenClaw's own OpenAI OAuth
profile. Path 3 launches separate harness processes: Codex ACP authenticates from
an isolated `CODEX_HOME` that OpenClaw deliberately leaves without auth, and
Claude Code ACP authenticates from the Gateway process environment. Each needs
its own one-time setup — see "Authenticate the relay harnesses" in
`runpod/README.md`, or run `openclaw-relay-auth status` on the Pod.

## Where a Claude subscription fits

A Claude plan can drive all three paths, but through two different mechanisms,
and only path 3 is enabled out of the box.

| Path | Claude route                                 | Shipped state             | Credential                                              |
| ---- | -------------------------------------------- | ------------------------- | ------------------------------------------------------- |
| 1    | `anthropic/*` model on the one-shot endpoint | permitted, off by default | `claude setup-token` stored as an OpenClaw auth profile |
| 2    | OpenClaw's own turns answer as Claude        | permitted, off by default | same setup-token profile, or the `claude-cli` runtime   |
| 3    | Claude Code itself runs as the harness       | **enabled**               | `CLAUDE_CODE_OAUTH_TOKEN` in the Gateway environment    |

Paths 1 and 2 use Claude as a _model_: OpenClaw sends the prompt and spends its
own credit. Path 3 uses Claude Code as a _program_: OpenClaw sends nothing to a
model at all. That is why path 3 is the only one where a Claude plan removes
OpenClaw's own model cost rather than relocating it.

Enabling paths 1 and 2 is a config change, not a rebuild — both provider plugins
are already in the allowlist. The per-path steps are in each deployment's README.

Anthropic bills programmatic Claude usage against the signed-in plan's limits
and can change those rules without an OpenClaw release. For shared production
volume, an API key is the predictable route.

## Why not one deployment

- Telegram long polling keeps a worker permanently busy, which defeats
  Serverless scale-to-zero. Path 1 must be a separate endpoint.
- Paths 2 and 3 need durable state: OAuth profiles that refresh, a session
  database, bindings, and a repository checkout. Path 1 must have none of that
  to stay fast and stateless.
