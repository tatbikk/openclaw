ARG PYTHON_BUILD_IMAGE="docker.io/library/python:3.11-slim-bookworm"
ARG OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:2026.7.2-beta.7@sha256:d41807ff1e5c925ff75e71ed2b755cdea59da1431d1f4fde5051a16a3337e9ce"

# Build Python dependencies once. No package manager or network access runs when
# a Serverless worker starts, so cold starts contain only process initialization.
FROM ${PYTHON_BUILD_IMAGE} AS python-deps
COPY deploy/runpod-serverless/requirements.txt /tmp/requirements.txt
RUN python -m pip install \
      --disable-pip-version-check \
      --no-cache-dir \
      --no-compile \
      --target /opt/runpod-python \
      -r /tmp/requirements.txt \
    && find /opt/runpod-python -type d \( -name __pycache__ -o -name tests \) -prune -exec rm -rf '{}' +

# Build an official, integrity-recorded Codex plugin seed. It is copied to an
# empty persistent state directory on first boot without any runtime download.
FROM ${OPENCLAW_IMAGE} AS codex-seed
USER root
RUN install -d -m 0700 -o node -g node \
      /runpod-volume/openclaw-serverless/state \
      /opt/openclaw-codex-seed
USER node
ENV OPENCLAW_STATE_DIR=/runpod-volume/openclaw-serverless/state \
    OPENCLAW_CONFIG_PATH=/runpod-volume/openclaw-serverless/state/openclaw.json
RUN node /app/openclaw.mjs plugins install npm:@openclaw/codex@2026.7.2-beta.7 \
    && cp -a /runpod-volume/openclaw-serverless/state/. /opt/openclaw-codex-seed/

# The published OpenClaw runtime is already produced by its upstream
# multi-stage build: build tools and development dependencies are absent here.
# Reusing that pinned runtime is both smaller and faster than compiling the
# repository again in every Serverless image build.
FROM ${OPENCLAW_IMAGE}

USER root

# `runuser` lets the tiny entrypoint prepare a root-owned Network Volume and
# then run the public handler as the image's unprivileged node user.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=python-deps /opt/runpod-python /opt/runpod-python
COPY --from=codex-seed --chown=node:node /opt/openclaw-codex-seed /opt/openclaw-codex-seed
COPY --chown=node:node deploy/runpod-serverless/handler.py /opt/openclaw-serverless/handler.py
COPY --chmod=755 deploy/runpod-serverless/entrypoint.sh /usr/local/bin/openclaw-serverless-entrypoint
COPY --chmod=755 deploy/runpod-serverless/authenticate.sh /usr/local/bin/openclaw-serverless-authenticate

ENV PYTHONPATH=/opt/runpod-python \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OPENCLAW_SERVERLESS_STATE_DIR=/runpod-volume/openclaw-serverless/state \
    OPENCLAW_SERVERLESS_CONFIG_HOME=/runpod-volume/openclaw-serverless/config \
    OPENCLAW_SERVERLESS_DEFAULT_MODEL=openai/gpt-5.6-sol \
    OPENCLAW_SERVERLESS_ALLOWED_MODELS=openai/gpt-5.6-sol,openai/gpt-5.6-terra,openai/gpt-5.6-luna,openai/gpt-5.5 \
    OPENCLAW_SERVERLESS_INFER_TIMEOUT_SECONDS=120 \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENCLAW_NO_RESPAWN=1 \
    NODE_ENV=production

# The RunPod SDK polls for jobs; no public container port or embedded HTTP
# server is needed for a queue-based /run or /runsync endpoint.
ENTRYPOINT ["tini", "-s", "--", "/usr/local/bin/openclaw-serverless-entrypoint"]
CMD ["python3", "/opt/openclaw-serverless/handler.py"]
