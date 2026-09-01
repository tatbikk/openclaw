"""Measure one cold candidate followed by nine sequential warm candidates."""

from __future__ import annotations

import argparse
import os
import time
from uuid import uuid4

from client import invoke


def milliseconds(value: object) -> str:
    return "-" if value is None else f"{float(value):.1f}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint-id", default=os.environ.get("RUNPOD_ENDPOINT_ID"))
    parser.add_argument("--api-key", default=os.environ.get("RUNPOD_API_KEY"))
    parser.add_argument("--model", default="openai/gpt-5.6-sol")
    parser.add_argument("--thinking", default="low")
    parser.add_argument("--gap", type=float, default=5.0, help="Seconds between completed calls")
    parser.add_argument("--count", type=int, default=10)
    args = parser.parse_args()
    if not args.endpoint_id or not args.api_key:
        parser.error("set RUNPOD_ENDPOINT_ID and RUNPOD_API_KEY")
    if args.count < 1 or args.gap < 0:
        parser.error("--count must be positive and --gap cannot be negative")

    print("n  end_to_end_ms  runpod_delay_ms  runpod_execution_ms  handler_ms  request_id")
    durations: list[float] = []
    for index in range(1, args.count + 1):
        request_id = str(uuid4())
        started = time.monotonic()
        result = invoke(
            endpoint_id=args.endpoint_id,
            api_key=args.api_key,
            prompt=f"Reply with only the integer {index}.",
            model=args.model,
            thinking=args.thinking,
            request_id=request_id,
        )
        duration_ms = (time.monotonic() - started) * 1000
        durations.append(duration_ms)
        envelope = result["runpod"]
        output = result["output"]
        print(
            f"{index:<2} {duration_ms:>14.1f}  "
            f"{milliseconds(envelope.get('delayTime')):>15}  "
            f"{milliseconds(envelope.get('executionTime')):>20}  "
            f"{milliseconds(output.get('latency_ms')):>10}  {request_id}"
        )
        if index < args.count:
            time.sleep(args.gap)

    warm = durations[1:]
    print(f"first_end_to_end_ms={durations[0]:.1f}")
    if warm:
        print(f"warm_min_ms={min(warm):.1f} warm_avg_ms={sum(warm) / len(warm):.1f} warm_max_ms={max(warm):.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
