"""Small RunPod /runsync client with bounded retry and request IDs."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4


RETRYABLE_HTTP_STATUS = {408, 429, 500, 502, 503, 504}


def invoke(
    *,
    endpoint_id: str,
    api_key: str,
    prompt: str,
    model: str,
    thinking: str = "low",
    request_id: str | None = None,
    attempts: int = 3,
    timeout_seconds: float = 180,
) -> dict[str, Any]:
    request_id = request_id or str(uuid4())
    url = f"https://api.runpod.ai/v2/{endpoint_id}/runsync"
    payload = json.dumps(
        {
            "input": {
                "request_id": request_id,
                "prompt": prompt,
                "model": model,
                "thinking": thinking,
            }
        }
    ).encode("utf-8")

    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        request = Request(
            url,
            data=payload,
            method="POST",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urlopen(request, timeout=timeout_seconds) as response:
                envelope = json.load(response)
            if envelope.get("status") != "COMPLETED":
                raise RuntimeError(
                    f"RunPod job did not complete: status={envelope.get('status')} "
                    f"error={envelope.get('error')}"
                )
            output = envelope.get("output")
            if not isinstance(output, dict):
                raise RuntimeError("RunPod returned a completed job without an object output")
            if output.get("request_id") != request_id:
                raise RuntimeError("RunPod response request_id does not match the request")
            return {"runpod": envelope, "output": output}
        except HTTPError as error:
            if error.code not in RETRYABLE_HTTP_STATUS:
                raise
            last_error = error
        except (TimeoutError, URLError) as error:
            last_error = error

        if attempt < attempts:
            time.sleep(2 ** (attempt - 1))

    raise RuntimeError(f"RunPod request failed after {attempts} attempts: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt")
    parser.add_argument("--model", default="openai/gpt-5.6-sol")
    parser.add_argument("--thinking", default="low")
    parser.add_argument("--endpoint-id", default=os.environ.get("RUNPOD_ENDPOINT_ID"))
    parser.add_argument("--api-key", default=os.environ.get("RUNPOD_API_KEY"))
    args = parser.parse_args()
    if not args.endpoint_id or not args.api_key:
        parser.error("set RUNPOD_ENDPOINT_ID and RUNPOD_API_KEY (or pass both flags)")

    result = invoke(
        endpoint_id=args.endpoint_id,
        api_key=args.api_key,
        prompt=args.prompt,
        model=args.model,
        thinking=args.thinking,
    )
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
