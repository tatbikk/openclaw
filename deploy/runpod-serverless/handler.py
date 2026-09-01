"""Stateless, single-inference OpenClaw worker for RunPod Serverless."""

from __future__ import annotations

import atexit
import json
import logging
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

import runpod


OPENCLAW_CLI = "/app/openclaw.mjs"
GATEWAY_PORT = 18789
MAX_PROMPT_CHARS = 200_000
MAX_REQUEST_ID_CHARS = 128
THINKING_LEVELS = {"off", "minimal", "low", "medium", "high", "adaptive", "xhigh", "max"}

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
LOGGER = logging.getLogger("openclaw_serverless")


# Both providers are subscription-backed here: openai/* through the Codex
# runtime, anthropic/* through an OpenClaw auth profile created from a Claude
# `setup-token`. Neither route uses a pay-per-token API key.
SUPPORTED_PROVIDERS = ("openai", "anthropic")


def _csv_env(name: str, default: str) -> tuple[str, ...]:
    values = tuple(part.strip() for part in os.environ.get(name, default).split(",") if part.strip())
    if not values:
        raise RuntimeError(f"{name} must contain at least one model")
    prefixes = tuple(f"{provider}/" for provider in SUPPORTED_PROVIDERS)
    if any(not value.startswith(prefixes) for value in values):
        raise RuntimeError(
            f"{name} may contain only canonical <provider>/<model> references for: "
            + ", ".join(SUPPORTED_PROVIDERS)
        )
    return values


ALLOWED_MODELS = _csv_env(
    "OPENCLAW_SERVERLESS_ALLOWED_MODELS",
    "openai/gpt-5.6-sol,openai/gpt-5.6-terra,openai/gpt-5.6-luna,openai/gpt-5.5",
)
DEFAULT_MODEL = os.environ.get("OPENCLAW_SERVERLESS_DEFAULT_MODEL", "openai/gpt-5.6-sol").strip()
if DEFAULT_MODEL not in ALLOWED_MODELS:
    raise RuntimeError("OPENCLAW_SERVERLESS_DEFAULT_MODEL must be in OPENCLAW_SERVERLESS_ALLOWED_MODELS")


def _write_worker_config() -> tuple[dict[str, str], Path]:
    runtime_root = Path("/tmp/openclaw-serverless")
    config_path = runtime_root / "openclaw.json"
    workspace = runtime_root / "workspace"
    codex_home = runtime_root / "codex"
    home = runtime_root / "home"
    for directory in (runtime_root, workspace, codex_home, home):
        directory.mkdir(parents=True, exist_ok=True)

    # openai/* models are pinned to the subscription-backed Codex runtime so they
    # fail closed instead of falling back to API-key billing. anthropic/* models
    # carry no runtime pin: they resolve through the stored Anthropic auth
    # profile. No fallback model is configured, so an unavailable model fails.
    providers_in_use = {model.split("/", 1)[0] for model in ALLOWED_MODELS}
    plugin_allow = ["codex"] + sorted(providers_in_use)
    config = {
        "gateway": {"mode": "local", "auth": {"mode": "token"}},
        "plugins": {
            "allow": plugin_allow,
            "entries": {
                "codex": {
                    "enabled": True,
                    "config": {"appServer": {"homeScope": "agent"}},
                }
            },
        },
        "agents": {
            "defaults": {
                "model": {"primary": DEFAULT_MODEL},
                "models": {
                    model: {"agentRuntime": {"id": "codex"}}
                    for model in ALLOWED_MODELS
                    if model.startswith("openai/")
                },
            }
        },
    }
    config_path.write_text(json.dumps(config, separators=(",", ":")), encoding="utf-8")

    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(home),
            "OPENCLAW_HOME": str(home),
            "OPENCLAW_CONFIG_PATH": str(config_path),
            "OPENCLAW_STATE_DIR": os.environ.get(
                "OPENCLAW_SERVERLESS_STATE_DIR", "/runpod-volume/openclaw-serverless/state"
            ),
            "OPENCLAW_WORKSPACE_DIR": str(workspace),
            "XDG_CONFIG_HOME": os.environ.get(
                "OPENCLAW_SERVERLESS_CONFIG_HOME", "/runpod-volume/openclaw-serverless/config"
            ),
            "CODEX_HOME": str(codex_home),
            # The Gateway is loopback-only. A per-worker random token protects
            # its internal backend lane without adding a deploy-time secret.
            "OPENCLAW_GATEWAY_TOKEN": secrets.token_hex(32),
        }
    )
    return environment, config_path


WORKER_ENV, WORKER_CONFIG_PATH = _write_worker_config()


def _start_gateway() -> subprocess.Popen[str]:
    process = subprocess.Popen(
        [
            "node",
            OPENCLAW_CLI,
            "gateway",
            "--bind",
            "loopback",
            "--port",
            str(GATEWAY_PORT),
        ],
        env=WORKER_ENV,
        text=True,
    )
    deadline = time.monotonic() + float(
        os.environ.get("OPENCLAW_SERVERLESS_INIT_TIMEOUT_SECONDS", "30")
    )
    health_url = f"http://127.0.0.1:{GATEWAY_PORT}/startupz"
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"OpenClaw Gateway exited during initialization ({process.returncode})")
        try:
            with urlopen(health_url, timeout=1) as response:
                if 200 <= response.status < 300:
                    return process
        except (OSError, URLError) as error:
            last_error = error
        time.sleep(0.1)
    process.terminate()
    raise RuntimeError(f"OpenClaw Gateway did not become ready: {last_error}")


# Heavy initialization is intentionally module-scoped. RunPod imports this file
# once per worker; subsequent jobs reuse the already-running Gateway.
GATEWAY_PROCESS = _start_gateway()
atexit.register(GATEWAY_PROCESS.terminate)
LOGGER.info(
    "request_id=startup worker initialized models=%s config=%s",
    ",".join(ALLOWED_MODELS),
    WORKER_CONFIG_PATH,
)


def _require_string(data: dict[str, Any], key: str, maximum: int) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"input.{key} must be a non-empty string")
    if len(value) > maximum:
        raise ValueError(f"input.{key} exceeds {maximum} characters")
    return value


def _require_request_id(data: dict[str, Any]) -> str:
    request_id = _require_string(data, "request_id", MAX_REQUEST_ID_CHARS)
    if not re.fullmatch(r"[A-Za-z0-9._:-]+", request_id):
        raise ValueError("input.request_id may contain only letters, digits, dot, underscore, colon, or dash")
    return request_id


def _run_single_inference(prompt: str, model: str, thinking: str) -> dict[str, Any]:
    timeout = float(os.environ.get("OPENCLAW_SERVERLESS_INFER_TIMEOUT_SECONDS", "120"))
    completed = subprocess.run(
        [
            "node",
            OPENCLAW_CLI,
            "infer",
            "model",
            "run",
            "--gateway",
            "--model",
            model,
            "--thinking",
            thinking,
            "--prompt",
            prompt,
            "--json",
        ],
        env=WORKER_ENV,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip()[-2000:] or "OpenClaw inference failed without stderr"
        raise RuntimeError(detail)
    try:
        envelope = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("OpenClaw returned invalid JSON") from error

    actual_provider = envelope.get("provider")
    actual_model_id = envelope.get("model")
    attempts = envelope.get("attempts", [])
    outputs = envelope.get("outputs", [])
    output_text = "".join(
        output.get("text", "") for output in outputs if isinstance(output, dict)
    )
    requested_provider, requested_model_id = model.split("/", 1)
    if actual_provider != requested_provider or actual_model_id != requested_model_id:
        raise RuntimeError(
            f"Requested model {model} but OpenClaw reported {actual_provider}/{actual_model_id}"
        )
    if attempts:
        raise RuntimeError("OpenClaw attempted a fallback even though this worker config disables fallbacks")
    if not output_text:
        raise RuntimeError("OpenClaw returned no text output")
    return {
        "output_text": output_text,
        "provider": actual_provider,
        "model": model,
        "transport": envelope.get("transport"),
    }


def handler(job: dict[str, Any]) -> dict[str, Any]:
    started = time.monotonic()
    job_input = job.get("input")
    if not isinstance(job_input, dict):
        raise ValueError("input must be a JSON object")

    request_id = _require_request_id(job_input)
    try:
        prompt = _require_string(job_input, "prompt", MAX_PROMPT_CHARS)
        model = job_input.get("model", DEFAULT_MODEL)
        thinking = job_input.get("thinking", "low")
        if not isinstance(model, str) or model not in ALLOWED_MODELS:
            raise ValueError(f"input.model must be one of: {', '.join(ALLOWED_MODELS)}")
        if not isinstance(thinking, str) or thinking not in THINKING_LEVELS:
            raise ValueError(f"input.thinking must be one of: {', '.join(sorted(THINKING_LEVELS))}")

        LOGGER.info(
            "request_id=%s inference started model=%s thinking=%s prompt_chars=%d",
            request_id,
            model,
            thinking,
            len(prompt),
        )
        result = _run_single_inference(prompt, model, thinking)
        latency_ms = round((time.monotonic() - started) * 1000, 1)
        LOGGER.info(
            "request_id=%s inference completed model=%s latency_ms=%.1f",
            request_id,
            model,
            latency_ms,
        )
        return {
            "request_id": request_id,
            **result,
            "thinking": thinking,
            "latency_ms": latency_ms,
        }
    except Exception:
        latency_ms = round((time.monotonic() - started) * 1000, 1)
        LOGGER.exception("request_id=%s inference failed latency_ms=%.1f", request_id, latency_ms)
        raise


runpod.serverless.start({"handler": handler})
