# AI Harness

## Goal

Build the slow-path AI harness that connects the agent to LLMs/VLMs, manages memory, routes model calls, validates structured planner output, and keeps model choices updateable without touching the low-latency reflex loop.

The harness is the agent's reasoning and memory layer. It supports planning, recovery, trace explanation, model-assisted perception setup, and long-running improvement. It does not drive frame-by-frame gameplay.

## Core Rule

The AI harness must never block the reflex loop.

Remote LLM/VLM calls can help the agent think, remember, and recover, but the fast controller must keep running from local world state and the latest valid planner hints.

```text
Capture / Perception / Controller / Action
  -> local, bounded, latest-frame-wins

AI Harness
  -> async, slow-path, memory-backed, validated output
```

If the harness is slow, offline, rate-limited, or wrong, the controller continues with local policy, stale hint expiry, and safe fallback behavior.

## Responsibilities

- connect to model providers
- choose the right model for each slow-path job
- build compact model inputs from world state, traces, screenshots, DOM summaries, and user goals
- retrieve useful memory before a planner call
- validate structured model outputs
- write approved memory updates
- produce planner hints for the fast controller
- summarize failure traces
- review screenshots or traces for evaluation
- track model latency, cost, output quality, and schema validity
- provide a safe model update process

## Non-Responsibilities

- per-frame action decisions
- direct OS input
- direct mutation of controller state without validation
- raw screenshot logging without redaction rules
- choosing local fast-vision models without trace benchmarks
- silently switching production model behavior

## Architecture

```text
World State History
Trace Buffer
User Goal
Target Adapter
Screenshots / DOM Summary
  -> Snapshot Builder
  -> Memory Retriever
  -> Model Router
  -> Provider Adapter
  -> Structured Output Validator
  -> Planner Hint Bus
  -> Memory Writer
  -> Trace / Metrics Sink
```

The harness should be a sidecar service or worker owned by the agent runtime. It reads snapshots and emits typed outputs. It should not own capture, input, or the controller tick.

## Memory Layers

Use several small memory types instead of one vague long-term memory store.

### Short-Term Run Memory

Lives in process for the current run.

Contains:

- current goal
- active plan
- latest planner hints
- recent world-state summaries
- recent failures
- recent user instructions
- active safety stops

This memory should be cheap, small, and cleared when the run ends.

### Trace Memory

Lives with recorded runs.

Contains:

- frame ids
- world-state snapshots
- action decisions
- planner hint ids
- failures and recoveries
- model calls and output validation status

Trace memory is the evidence layer. Any durable lesson should point back to a trace id.

### Target Memory

Lives per game/app target.

Contains:

- target-specific strategies
- useful regions of interest
- common screens and menus
- calibration notes
- safe recovery policies
- known bad planner suggestions
- successful policy sequences

Target memory should be versioned with the target adapter.

### Semantic Memory

Lives in a searchable store.

Contains:

- summarized lessons from traces
- user preferences
- task instructions that should carry across sessions
- target notes
- prompt/eval learnings

Use embeddings only for text summaries and metadata. Do not embed raw screenshots unless there is a deliberate image-retrieval plan.

### Model Registry Memory

Lives as configuration, not generated memory.

Contains:

- provider ids
- model ids
- role assignments
- feature support
- context limits
- reasoning settings
- prompt versions
- eval scores
- rollout status
- rollback model id
- last verified date
- source docs URL

The model registry is the control plane for "which model should this job use?"

## Memory Record Shape

Every durable memory item should be inspectable and deleteable.

```text
memory_id
memory_type
target_id
scope
content
metadata
source_trace_id
source_frame_id
source_model_call_id
confidence
created_at
expires_at
embedding_model
embedding_version
schema_version
```

## Memory Write Rules

- The model may propose memory writes, but deterministic code approves them.
- Every write needs a source: user instruction, trace id, evaluation result, or explicit operator note.
- Memory must have scope: run, target, global, or user.
- Memory must have a TTL unless it is a deliberate durable target fact.
- Do not store secrets, account data, payment screens, login screens, personal messages, or unrelated desktop content.
- Prefer summaries over raw logs.
- Prefer "observed in trace X" over unsupported claims.
- Conflicting memories should be kept with confidence and source, not silently merged.

## Retrieval Rules

Before each planner call, build a small context package:

- current user goal
- latest summarized world state
- recent failures
- current valid planner hints
- target adapter facts
- top matching target memories
- top matching semantic memories
- screenshot or DOM summary only when needed

The retrieval budget should be explicit:

```text
working_state_tokens
target_memory_tokens
semantic_memory_tokens
trace_summary_tokens
visual_input_budget
max_total_input_tokens
```

If retrieval returns too much, summarize or drop lower-confidence memory. Do not send the full trace or full DOM tree by default.

## Provider Connection Layer

Expose a small provider-neutral interface.

```text
list_models(provider)
generate_text(request)
generate_structured(request, schema)
analyze_image(request, schema)
embed_text(request)
stream_events(request)
cancel(request_id)
```

The first provider should be OpenAI through the Responses API. Keep the adapter narrow so Anthropic, Google, Ollama, local models, or a custom inference server can be added later without changing planner/controller contracts.

## OpenAI Connection Plan

Use the Responses API for new slow-path model calls because it supports multimodal inputs, tool use, structured outputs, stateful workflows, and built-in agentic primitives.

Default connection rules:

- read `OPENAI_API_KEY` from the environment
- use `store: false` by default for privacy-sensitive screen-agent calls
- allow opt-in stateful conversation only when the user/product explicitly wants server-side state
- use structured outputs for planner hints and memory write proposals
- place static instructions and schemas before variable state to benefit from prompt caching
- set timeouts per job type
- stream when useful for operator visibility, but publish only validated final hints to the controller
- log request metadata, not secrets or raw sensitive content

## Ollama And Local LLM Plan

Ollama can be useful for local slow-path AI work:

- reasoning
- planning
- dialogue
- UI understanding
- trace summarization
- offline prompt and memory experiments

It is probably not the right tool for the ultra-low-latency gameplay control loop. Even when local, a chat LLM still pays transformer inference costs: tokenization, attention, matrix multiplication, KV-cache management, and next-token sampling. Those costs can be fine for a planner that runs every few seconds, but they are a bad fit for a controller that needs fresh actions in under 100ms and often much faster.

Treat Ollama as a local harness provider, not a reflex controller.

```text
Ollama
  -> local planner / dialogue / UI interpretation
  -> async hint generation
  -> local privacy-friendly experimentation

Not Ollama
  -> per-frame dodging
  -> aiming
  -> tap/swipe timing
  -> obstacle reaction
```

For the hot path, prefer:

- smaller specialized models
- ONNX Runtime
- TensorRT, Core ML, DirectML, or OpenVINO where they reduce p95 latency
- direct GPU inference with preallocated buffers
- vision models optimized for less than 50ms p95 latency
- off-the-shelf detectors, segmenters, OCR, and direct GPU inference
- classical CV, templates, and finite-state policies when they beat heavier models

Ollama is still useful as inspiration for the local runtime direction. It runs local models through an inference server and can use GPU acceleration depending on platform and hardware. Its local stack is shaped around the same low-level work any transformer runtime must do: model loading, quantized weights, KV cache, CPU/GPU scheduling, and sampling. The lesson for this project is to keep local inference close to the data, warmed up, measured, and specialized.

Useful Ollama checks:

- `ollama ps` to see whether a model is loaded on GPU, CPU, or split CPU/GPU
- `OLLAMA_CONTEXT_LENGTH` to control context size
- `OLLAMA_NUM_PARALLEL` and `OLLAMA_MAX_QUEUE` to avoid hidden request queues
- local-only mode when remote/cloud features are not desired

If an Ollama-backed planner is added, give it strict timeouts, queue size 1, latest-request-wins cancellation, schema validation, and the same hint expiry rules as remote providers.

## Local Reasoning Model Candidates

Local reasoning models are candidates for the AI harness, not the reflex policy.

| Candidate | Best Use | Notes |
| --- | --- | --- |
| Qwen3 8B | local reasoning, coding-adjacent planning, tool-style workflows | strong open model candidate; benchmark thinking vs non-thinking modes separately |
| Phi-family small models | fast lightweight planning, tool calling, tactical summaries | use the smallest model that passes schema/eval gates |
| Gemma 3 | local text+image reasoning, UI understanding, broad language support | useful when a small multimodal model is enough |
| PaliGemma | fine-tuned visual question answering, OCR-like UI tasks, detection/segmentation experiments | better as a fine-tuned VLM tool than a reflex controller |

These models can support objectives, coaching, memory, strategy adaptation, and trace review. They should never emit direct input. Their outputs must still become validated planner hints.

## Model Roles

Do not hardcode one model everywhere. Assign models by role.

| Role | Default Candidate | Use |
| --- | --- | --- |
| `planner_default` | `gpt-5.4-mini` | routine slow planning, recovery hints, target reasoning |
| `planner_strong` | `gpt-5.5` | hard recovery, unfamiliar screens, complex strategy, plan generation |
| `planner_deep_eval` | `gpt-5.5-pro` | offline trace critique or high-value evaluation only |
| `planner_cheap` | `gpt-5.4-nano` | simple classification, short summaries, routing decisions |
| `planner_local` | Qwen3 8B, Phi-family, or Gemma 3 through Ollama/vLLM/llama.cpp | local reasoning/dialogue/UI understanding outside the reflex loop |
| `vision_local_slow` | Gemma 3 or PaliGemma candidate | local multimodal UI understanding outside the reflex loop |
| `vision_snapshot` | `gpt-5.4-mini` or `gpt-5.5` | occasional screenshot understanding outside the reflex loop |
| `memory_embed_default` | `text-embedding-3-small` | default semantic memory retrieval |
| `memory_embed_high_quality` | `text-embedding-3-large` | offline reindexing or higher-quality retrieval experiments |
| `local_fast_vision` | target-specific local model | hot-path perception, selected only from target traces |

Current OpenAI docs list GPT-5.5 as the flagship model for complex coding/professional work and GPT-5.4 mini/nano as lower-latency/lower-cost options. Re-check the model docs before implementation because model names, pricing, rate limits, and feature support change.

## Model Routing

Route by job type, risk, latency tolerance, and failure history.

```text
if job is hot_path:
  reject remote model call
  reject general chat LLM call unless a measured specialized local model meets the budget

if job is simple classification or summarization:
  use planner_cheap

if job requires local-only privacy and can tolerate slower output:
  use planner_local

if job is normal goal planning:
  use planner_default

if confidence is low or recovery has failed repeatedly:
  escalate to planner_strong

if job is offline benchmark, critique, or prompt migration:
  optionally use planner_deep_eval
```

The router should return:

```text
model_role
provider
model_id
reasoning_effort
timeout_ms
max_output_tokens
fallback_role
schema_id
prompt_version
```

## Structured Planner Output

The harness should emit controller hints, not prose.

```text
hint_id
target_id
goal
policy
priorities
regions_of_interest
avoid_actions
recovery_action
confidence
expires_at
source_model_call_id
source_memory_ids
memory_write_proposals
```

Validation rules:

- schema must validate
- unknown actions are rejected
- unsafe actions are rejected
- stale world-state references are rejected
- low-confidence hints do not replace high-confidence active hints unless the controller asks for recovery
- every hint expires

## Prompt Shape

Keep planner prompts compact and stable.

```text
System:
  role, safety rules, output schema, controller contract

Static target context:
  adapter facts, action space, known safe/unsafe behavior

Dynamic state:
  current goal, latest world-state summary, recent failures

Retrieved memory:
  top relevant target/semantic memories with ids

Visual input:
  only the current crop/screenshot when needed

Output:
  strict JSON planner hint plus memory write proposals
```

Prompt versions should be stored beside model registry entries. Any prompt change should be evaluated on recorded traces before becoming default.

## Model Update Flow

Model updates are a release process, not a string replacement.

1. Check provider availability with the provider model-list endpoint.
2. Read current official provider docs for model capabilities, pricing, rate limits, deprecations, and migration notes.
3. Add or update a candidate in the model registry with `status: candidate`.
4. Run the replay/eval suite on representative traces.
5. Compare schema validity, hint quality, memory write quality, latency, cost, and recovery success.
6. Run a canary target with the candidate model behind a feature flag.
7. Promote the model role only if it beats or matches the current default on the target metrics.
8. Keep the previous model as rollback.
9. Record the docs URLs and verification date.

## Model Registry Shape

```text
role
provider
model_id
snapshot_id
endpoint
supports_text
supports_image_input
supports_structured_output
supports_tools
supports_streaming
reasoning_effort_default
context_window
max_output_tokens
timeout_ms
fallback_role
prompt_version
eval_suite_id
last_eval_score
last_verified_at
docs_url
status
rollback_model_id
```

Prefer role references in code:

```text
planner_default
planner_strong
memory_embed_default
```

Avoid scattering literal model ids through prompts, adapters, and tests.

## Where To Look

For OpenAI model/API work, use official docs first:

- [Latest model guide](https://developers.openai.com/api/docs/guides/latest-model)
- [Models catalog](https://developers.openai.com/api/docs/models)
- [All models](https://developers.openai.com/api/docs/models/all)
- [Compare models](https://developers.openai.com/api/docs/models/compare)
- [Responses API guide](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Model list API](https://developers.openai.com/api/reference/resources/models/methods/list)
- [Embeddings guide](https://developers.openai.com/api/docs/guides/embeddings)
- [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
- [Compaction](https://developers.openai.com/api/docs/guides/compaction)
- [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [Pricing](https://developers.openai.com/api/docs/pricing)
- [Rate limits](https://developers.openai.com/api/docs/guides/rate-limits)
- [Deprecations](https://developers.openai.com/api/docs/deprecations)
- [Changelog](https://developers.openai.com/api/docs/changelog)

For Ollama and local LLM provider work, use official docs first:

- [Ollama docs](https://docs.ollama.com/)
- [Ollama FAQ](https://docs.ollama.com/faq)
- [Ollama API reference](https://docs.ollama.com/api)
- [Ollama GPU docs](https://docs.ollama.com/gpu)
- [llama.cpp repository](https://github.com/ggml-org/llama.cpp)
- [Qwen3 8B model card](https://huggingface.co/Qwen/Qwen3-8B)
- [Microsoft Phi models](https://azure.microsoft.com/en-us/products/phi/)
- [Microsoft Phi-4-mini model card](https://huggingface.co/microsoft/Phi-4-mini-instruct)
- [Google Gemma docs](https://ai.google.dev/gemma/docs)
- [Gemma 3 model card](https://ai.google.dev/gemma/docs/core/model_card_3)
- [PaliGemma model card](https://huggingface.co/google/paligemma-3b-pt-224)

For local fast models, trust local evidence first:

- recorded target traces
- latency reports
- false-positive/false-negative reports
- missed-action and wrong-action counts
- replay comparison results
- hardware-specific baselines

General benchmark numbers are useful only for choosing candidates. Target traces decide what ships.

## Observability

Every model call should emit:

```text
model_call_id
provider
model_id
model_role
prompt_version
schema_id
input_token_estimate
output_token_count
latency_ms
timeout_ms
retry_count
cache_hit_status
validation_status
memory_read_count
memory_write_proposal_count
accepted_memory_write_count
source_trace_id
source_state_id
```

Add aggregate reports:

- model latency p50/p95/p99 by role
- schema validation failure rate
- planner hint acceptance rate
- memory write acceptance rate
- fallback/escalation count
- cost by target/run
- recovery success after planner intervention

## Failure Handling

The harness should degrade quietly and visibly.

- timeout returns no new hint
- invalid output is rejected and traced
- rate limit triggers backoff and fallback model if safe
- repeated invalid output disables the model role for the run
- failed memory retrieval uses target defaults only
- failed memory write drops the write, not the run
- provider outage leaves controller running with local policy

## Privacy And Safety

- Remote model calls are opt-in per product mode.
- Default to `store: false` for screen-agent calls.
- Redact or block sensitive screens before remote upload.
- Never send payment, login, account, private message, or unrelated desktop content to a remote model.
- Log model metadata separately from prompt contents.
- Keep screenshot retention short unless the user records a trace intentionally.
- Memory deletion must be possible by target, run, and user scope.
- The harness can recommend actions only through validated planner hints.

## First Milestones

1. Define model registry schema and role names.
2. Build the OpenAI Responses provider adapter.
3. Add one structured planner hint schema.
4. Build short-term run memory and target memory as JSONL files.
5. Add text embedding support for semantic memory.
6. Add snapshot builder with screenshot/DOM redaction hooks.
7. Add model router with default, cheap, strong, and fallback roles.
8. Add optional Ollama provider support for local slow-path planning.
9. Add memory write proposals with deterministic approval.
10. Add trace events for model calls and memory operations.
11. Add a replay/eval command for model and prompt changes.
12. Add a model update checklist that writes `last_verified_at` and docs URLs.

## Acceptance Criteria

- No remote model call appears in the reflex-loop trace.
- The controller can continue for a full run with the harness disabled.
- Planner hints are schema-validated and expire automatically.
- Memory writes are source-linked, scoped, and deleteable.
- The model registry is the only place default model ids are assigned.
- Model upgrades require replay/eval results before promotion.
- A failed model call cannot produce direct input.
- A trace can explain which memories and model outputs influenced a planner hint.
