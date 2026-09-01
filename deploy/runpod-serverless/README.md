# Stateless one-call OpenClaw on RunPod Serverless

This worker is the fast path for an external application. One RunPod job makes
exactly one subscription-backed model inference through:

```text
external backend -> RunPod /runsync -> OpenClaw infer model run -> OpenAI -> result
```

It does not start a chat-agent turn, load tools, read agent instructions or
memory, or reuse conversation state. OpenClaw's one-shot `modelRun=true` path
also suppresses durable session mutation. The local Gateway exists only as a
warm OAuth/model transport inside one worker.

This deployment is separate from `deploy/runpod/`, which stays online to poll
Telegram and provides the full stateful OpenClaw agent/tool experience. Do not
put Telegram long polling in a scale-to-zero Serverless worker.

## Request contract

Call RunPod's synchronous endpoint with this body:

```json
{
  "input": {
    "request_id": "c311f870-808f-4a68-b385-e8486792f6dc",
    "prompt": "The complete context and current request go here.",
    "model": "openai/gpt-5.6-sol",
    "thinking": "low"
  }
}
```

- `request_id` is required and must be reused by the caller across retries.
- `prompt` is required and contains the complete context. The worker adds no
  conversation history.
- `model` defaults to `OPENCLAW_SERVERLESS_DEFAULT_MODEL` and must be in the
  exact `OPENCLAW_SERVERLESS_ALLOWED_MODELS` allowlist.
- `thinking` defaults to `low`. Use a stronger level only when the request
  benefits from it.

The completed RunPod envelope contains an output object like:

```json
{
  "request_id": "c311f870-808f-4a68-b385-e8486792f6dc",
  "output_text": "...",
  "provider": "openai",
  "model": "openai/gpt-5.6-sol",
  "transport": "gateway",
  "thinking": "low",
  "latency_ms": 1840.5
}
```

There is no hidden router or small-model call. The model selected by the
external application produces the answer directly. An unavailable or rejected
model fails instead of silently falling back. If a future workflow truly needs
semantic classification, make it an explicit opt-in stage and use an allowed
economical model such as `openai/gpt-5.6-luna`; do not insert it into this path.

The ChatGPT subscription login may use the Codex app-server as its transport.
That process is not a second model or agent call: it carries the one inference
to OpenAI. No `OPENAI_API_KEY` is used.

## Using a Claude subscription instead

The allowlist accepts `anthropic/*` alongside `openai/*`, so this endpoint can
serve Claude models on a Claude plan. It is off by default: the shipped
allowlist is OpenAI-only, and adding Anthropic is an explicit choice.

Authenticate once on the same Network Volume used for the OpenAI login, using a
token from `claude setup-token`:

```bash
openclaw models auth login --provider anthropic --method setup-token
```

Then widen the allowlist on the endpoint:

```text
OPENCLAW_SERVERLESS_ALLOWED_MODELS=openai/gpt-5.6-sol,anthropic/claude-opus-5
```

The worker pins only `openai/*` models to the Codex runtime, because that pin is
what stops an OpenAI request from silently falling back to API-key billing.
`anthropic/*` models carry no runtime pin and resolve through the stored auth
profile. The plugin allowlist is derived from the models actually configured, so
enabling Anthropic never happens implicitly.

Requests keep the same shape; only `model` changes. The response `provider`
field reports `anthropic`, and the same strict check still rejects any answer
that came from a model other than the one requested.

Subscription usage rules for Anthropic are the provider's, not this worker's:
programmatic Claude usage draws from the signed-in plan's limits. Verify current
terms before pointing production traffic at a subscription rather than an API
key.

## Build and publish

Build from the repository root for RunPod's `linux/amd64` platform:

```bash
docker build --platform linux/amd64 \
  -f deploy/runpod-serverless/Dockerfile \
  -t <registry>/openclaw-serverless:2026.7.2-beta.7 .
docker push <registry>/openclaw-serverless:2026.7.2-beta.7
```

The Dockerfile installs the pinned RunPod SDK and exact official Codex plugin
in disposable build stages, then copies only their runtime artifacts into the
already-pruned official OpenClaw image. It performs no `pip install`,
`npm install`, model download, or package update when a worker starts. These
OpenAI models are remote, so there are no model weights to bake or mount and
this endpoint does not benefit from a GPU.

## Persist the subscription login

OAuth credentials must survive scale-to-zero, so create a small dedicated
Network Volume in the endpoint's datacenter. This means the accurate cost goal
is **zero idle compute**, not literally zero total cost: RunPod continues to
charge for Network Volume storage. There is no safe subscription-only design
that both discards every worker and discards its refreshable OAuth credential.

Perform login once using a temporary Secure Cloud Pod:

1. Create the Network Volume.
2. Deploy a temporary Pod from the Serverless image.
3. Mount that volume at `/runpod-volume`.
4. Override the Container Start Command with:

   ```text
   /usr/local/bin/openclaw-serverless-authenticate
   ```

5. Read the one-time device URL/code from the Pod logs and complete ChatGPT
   sign-in locally. The script then lists the available `openai/*` models.
6. If device login is disabled for the account, add the environment variable
   `OPENCLAW_SERVERLESS_AUTH_FLOW=browser`, restart the temporary Pod, and use
   the manual browser/redirect flow.
7. Stop and terminate the temporary Pod. Attach the same volume to the
   Serverless endpoint.

Credentials live below `/runpod-volume/openclaw-serverless`; they are not in
the image, repository, application payload, or RunPod logs. Do not reuse the
Telegram Pod's state database. If one Network Volume is deliberately shared,
keep the two deployments in separate directories as configured here.

## Create the Serverless endpoint

Create a queue-based endpoint from the published image with these settings:

| Setting                  | Value                                                     |
| ------------------------ | --------------------------------------------------------- |
| Compute                  | CPU; start with enough RAM for OpenClaw/Codex and measure |
| Minimum workers          | `0`                                                       |
| Maximum workers          | `1`                                                       |
| Idle timeout             | `90` seconds                                              |
| Scaler                   | `REQUEST_COUNT`                                           |
| Scaler value             | `1`                                                       |
| FlashBoot                | enabled                                                   |
| Execution timeout        | at least `180000` ms                                      |
| Network Volume           | the authenticated volume above                            |
| Entrypoint/start command | leave empty                                               |

`Maximum workers = 1` matches the stated sequential workload and prevents two
workers from updating the same OAuth store concurrently. There is no worker
affinity, `job_id` routing, in-worker queue, session manager, or checkpoint.

The 90-second idle timeout is a starting measurement value. A warm worker may
serve any subsequent call; it need not be the same conceptual job. After
production measurement, set the timeout slightly above the observed maximum
gap between completed calls.

The five-second cold-start target is a service-level target to verify, not a
property Docker can guarantee. RunPod delay includes image availability and
worker provisioning. FlashBoot, a small runtime-only image, no runtime install,
and module-scope Gateway initialization remove the controllable delays. Region
capacity and image cache remain external variables.

## Connect the external application

The other program needs only server-side HTTP configuration:

- URL: `https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync`
- Header: `Authorization: Bearer <RUNPOD_API_KEY>`
- Header: `Content-Type: application/json`
- Body: the request contract above

Keep the RunPod API key in the application's backend or secret manager. Never
embed it in browser JavaScript or a distributable mobile/desktop client. If the
program supports a generic REST action/webhook, configure those three values.
If it only accepts an OpenAI-compatible base URL, add a tiny backend adapter;
RunPod's `/runsync` envelope is not the OpenAI Chat Completions schema.

Use the supplied reference client:

```bash
export RUNPOD_ENDPOINT_ID=<endpoint-id>
export RUNPOD_API_KEY=<server-side-api-key>
python deploy/runpod-serverless/client.py \
  --model openai/gpt-5.6-sol \
  'Return one concise answer.'
```

`client.py` makes three attempts with exponential delays of one and two
seconds for network errors, timeouts, rate limiting, and transient 5xx errors.
It sends the same `request_id` on every attempt.

This worker has no external side effects beyond the model request. A retry can
still consume subscription quota twice and can produce different text if the
first response was lost. Because the external application owns all state, it
must cache committed results/effects by `request_id` when exactly-once behavior
matters. The worker intentionally does not add a database or deduplication
session that would contradict the stateless design.

## Measure cold and warm behavior

Let the endpoint remain idle longer than its timeout before measuring the first
call, then run:

```bash
python deploy/runpod-serverless/benchmark.py \
  --model openai/gpt-5.6-sol \
  --gap 5 \
  --count 10
```

Record three different values:

- `runpod_delay_ms`: queue plus worker cold start. This is the value targeted
  by the five-second cold-start goal.
- `runpod_execution_ms` / `handler_ms`: OpenClaw plus the remote model call.
- `end_to_end_ms`: the application's actual observed latency.

Warm calls should largely remove `runpod_delay_ms`; their total latency cannot
be expected to be a fraction of a second because it still includes generation
by the selected strong remote model. Tune `idle timeout` from the longest real
inter-call gap, not from model response time.

Useful upstream references:

- https://docs.openclaw.ai/cli/infer
- https://docs.openclaw.ai/providers/openai
- https://docs.runpod.io/serverless/workers/handler-functions
- https://docs.runpod.io/serverless/endpoints/send-requests
- https://docs.runpod.io/serverless/development/optimization
- https://docs.runpod.io/storage/network-volumes
