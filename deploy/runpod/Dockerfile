ARG OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:2026.8.2"
ARG CODEX_PLUGIN_VERSION="2026.8.2"
ARG ACPX_PLUGIN_VERSION="2026.8.2"
ARG DEEPSEEK_PLUGIN_VERSION="2026.8.2"

# Codex and ACPX are official external plugins, so the public OpenClaw runtime
# image does not bundle them. Install the exact compatible releases during the
# image build; the final container never reaches npm during startup.
#
# codex    -> native app-server runtime for OpenClaw's own agent turns (path 2).
# acpx     -> ACP harness runtime that launches real Codex CLI and Claude Code
#             processes, used by the relay path (path 3) and by agent-driven
#             harness spawns. Its pinned dependencies already contain both ACP
#             adapters, so no on-demand npx fetch happens at run time.
# deepseek -> provider for the DEEPSEEK_API_KEY bootstrap model. The startup
#             wrapper allows `deepseek` in plugins.allow, and an allowed provider
#             that is not installed contributes no models, so the bootstrap model
#             is rejected as unknown and the boot dies under `set -e`.
FROM ${OPENCLAW_IMAGE} AS plugin-seed
ARG CODEX_PLUGIN_VERSION
ARG ACPX_PLUGIN_VERSION
ARG DEEPSEEK_PLUGIN_VERSION
USER root
RUN install -d -m 0700 -o node -g node /workspace/openclaw/state /opt/openclaw-plugin-seed
USER node
ENV OPENCLAW_STATE_DIR=/workspace/openclaw/state \
    OPENCLAW_CONFIG_PATH=/workspace/openclaw/state/openclaw.json
RUN node /app/openclaw.mjs plugins install "npm:@openclaw/codex@${CODEX_PLUGIN_VERSION}" \
    && node /app/openclaw.mjs plugins install "npm:@openclaw/acpx@${ACPX_PLUGIN_VERSION}" \
    && node /app/openclaw.mjs plugins install "npm:@openclaw/deepseek-provider@${DEEPSEEK_PLUGIN_VERSION}" \
    && cp -a /workspace/openclaw/state/. /opt/openclaw-plugin-seed/

FROM ${OPENCLAW_IMAGE}

ARG CODEX_PLUGIN_VERSION
ARG ACPX_PLUGIN_VERSION
ARG DEEPSEEK_PLUGIN_VERSION

USER root

# RunPod mounts persistent storage after the image is built. The small wrapper
# creates private state directories there, then drops privileges before OpenClaw starts.
# git is required because the coding paths operate on real repository checkouts.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends util-linux git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=plugin-seed --chown=node:node /opt/openclaw-plugin-seed /opt/openclaw-plugin-seed

COPY --chmod=755 deploy/runpod/entrypoint.sh /usr/local/bin/openclaw-runpod
COPY --chmod=755 deploy/runpod/relay-auth.sh /usr/local/bin/openclaw-relay-auth
COPY --chmod=755 deploy/runpod/ipv6-proxy.js /usr/local/lib/openclaw-ipv6-proxy.js

ENV OPENCLAW_HOME=/workspace/openclaw/home \
    XDG_CONFIG_HOME=/workspace/openclaw/config \
    OPENCLAW_STATE_DIR=/workspace/openclaw/state \
    OPENCLAW_CONFIG_PATH=/workspace/openclaw/state/openclaw.json \
    OPENCLAW_CONFIG_DIR=/workspace/openclaw/state \
    OPENCLAW_WORKSPACE_DIR=/workspace/openclaw/state/workspace \
    CODEX_HOME=/workspace/openclaw/codex \
    CLAUDE_CONFIG_DIR=/workspace/openclaw/claude \
    OPENCLAW_CODE_WORKSPACE=/workspace/code \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENCLAW_NO_RESPAWN=1 \
    NODE_ENV=production

# The pinned plugin versions the startup wrapper expects on the mounted volume.
ENV OPENCLAW_RUNPOD_CODEX_PLUGIN_VERSION=${CODEX_PLUGIN_VERSION} \
    OPENCLAW_RUNPOD_ACPX_PLUGIN_VERSION=${ACPX_PLUGIN_VERSION} \
    OPENCLAW_RUNPOD_DEEPSEEK_PLUGIN_VERSION=${DEEPSEEK_PLUGIN_VERSION}

# The ACPX startup probe spawns a real harness before the Gateway reports ready.
# A freshly created Pod has no Codex or Claude login yet, so probing at boot
# would only slow down or fail the very first start. Use `/acp doctor` (or
# `openclaw acp doctor` semantics through chat) for an explicit on-demand check
# after logging in, and set this to 1 if you want boot-time probing back.
ENV OPENCLAW_ACPX_RUNTIME_STARTUP_PROBE=0

EXPOSE 18789

# Keep the base image's tini ENTRYPOINT. RunPod should leave its Docker
# Entrypoint and Container Start Command fields empty so this command is used.
CMD ["/usr/local/bin/openclaw-runpod", "node", "/app/openclaw.mjs", "gateway", "--bind", "lan", "--port", "18789"]
