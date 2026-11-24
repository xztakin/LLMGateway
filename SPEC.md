# LLMGateway: requirements

A small service that serves Qwen3-14B on your own hardware for several apps, and falls back to a pay-per-token host
when local serving is down, too slow, or full.

Status: draft spec, 2026-11-23. Nothing is built yet. The open questions are at the end.

## 1. Purpose and scope

**Clients**

| Client | What it sends | Latency need | Volume (estimate) | Data sensitivity |
|---|---|---|---|---|
| TradeFlow Sentinel | Classifying news headlines: hack / delisting / regulatory, live vs aftermath, severity | Interactive: a sweep every 10 min, plus pre-entry checks that block a trade until answered. p95 < 15 s | About 2,200 requests a day today (~2.5k tokens in, ~200 out). About 200–300 short ones a day after the planned classify-each-article-once change | Public news only |
| LeadScout | Not yet specified (see open questions) | Probably batch or background | Unknown | **May include personal data about leads**, which affects whether the fallback may be used (§5) |

**Goals**
- One local Qwen3-14B instance shared by every client, behind one stable API.
- Trading traffic never waits behind other clients' work.
- Automatic fallback to a hosted Qwen3-14B (pay per token) when local serving can't answer in time, within each client's policy and budget.
- Cheap to run: about $0 when local works, cents to a few dollars a month of fallback.

**Non-goals**
- Fine-tuning or training.
- Serving several different models at once (one model; the config allows swapping it).
- Being reachable from the public internet.
- Embeddings and vision (can be added later).

## 2. Architecture

```
TradeFlow Sentinel ─┐                       ┌─> local backend (Ollama or llama.cpp server, Qwen3-14B)
LeadScout ──────────┼─> LLMGateway (HTTP) ──┤
other apps ─────────┘   auth, priority,     └─> fallback: pay-per-token host (OpenAI-style API, Qwen3-14B)
                        queue, fallback,
                        budget, metrics
```

- **Inference backend:** Ollama (already installed here) or the llama.cpp server. On Apple Silicon both use Metal. Pin the model tag and quantization (§6). The backend listens on localhost only.
- **Gateway:** a small HTTP service in front of the backend. It is the only thing clients talk to. Language: Rust (axum), Go, or Python (FastAPI). Rust matches TradeFlow's tooling.
  - **Build or adopt:** LiteLLM's proxy already provides an OpenAI-style API, per-key budgets, fallbacks and routing. Evaluate it first (§10). Build a custom gateway only if its priority queue and per-client fallback rules (§4, §5) don't fit.
- **Clients** call the gateway's OpenAI-style endpoint. TradeFlow's Sentinel gets an OpenAI-style client alongside its existing Ollama client.

## 3. API

**Endpoint:** OpenAI-compatible `POST /v1/chat/completions`, so the client code is the same whether a request is served locally or by the fallback.

**Request headers and fields**
- `Authorization: Bearer <client key>`, a separate key for each client app (§7).
- `X-Priority: interactive | background | batch`. Optional; each client key has a default and a maximum it may ask for.
- `X-Deadline-Ms`: how long the caller will wait. The gateway uses it to decide when to fall back (§5).
- Standard fields: `messages`, `max_tokens`, `temperature`, and `response_format` with a JSON schema for structured output, which is required for the Sentinel's verdicts.
- Qwen3 "thinking" is **off by default**. A request opts in with `thinking: true`, a gateway extension that maps to Qwen's `/no_think` / `/think`. Classification doesn't need thinking, and thinking multiplies the output tokens.

**Response**
- Standard OpenAI shape, plus these headers:
  - `X-Served-By: local | fallback`;
  - `X-Queue-Ms` and `X-Model`;
  - `X-Fallback-Reason` (`local_down`, `queue_full`, `deadline`, `error`) when the fallback served it.
- Token usage is in `usage`.

**Errors**
- `429` when a client is over its rate limit or budget.
- `503` with `Retry-After` when neither local nor the fallback (if allowed) can serve.
- `422` for an invalid schema or request.
- Callers decide what a failure means; the Sentinel already fails closed.

**Other endpoints**
- `GET /healthz`: liveness.
- `GET /readyz`: whether the model is loaded and the backend answers a warm-up prompt.
- `GET /metrics`: Prometheus format.
- `GET /v1/models`.

**Optional later**
- `POST /v1/batches`, for LeadScout bulk jobs. Accepts a JSONL file, runs it at batch priority, and returns results by ID.

## 4. Scheduling, priority and isolation (the most important requirement)

- **Queues:** three priority classes, `interactive` > `background` > `batch`. Strict priority: a waiting interactive request always goes next.
- **Reserved capacity:** the backend runs N parallel slots (Ollama `OLLAMA_NUM_PARALLEL`, llama.cpp `--parallel`, sized to fit in memory; start with 2). Slot 1 is reserved for `interactive`.
- **Preemption:** when an interactive request arrives and every slot is busy with batch work, the gateway may cancel the longest-running batch request, which goes back on its queue, or send the interactive one straight to the fallback if the client's policy allows. Which is configurable; default: fallback.
- **Per-client limits:** requests per minute, concurrent requests, queue depth, and maximum tokens per request. LeadScout must not be able to fill the queue in a way that delays the Sentinel beyond its deadline.
- **Fairness within a class:** round-robin between clients.
- **Cache:** responses keyed by a hash of (model, messages, schema, parameters) with a TTL, default 24 h, on by default for `temperature = 0`. The Sentinel re-sends identical headline sets often, so this alone removes most repeat requests.

## 5. Fallback (pay-per-token host)

**Fall back when, for that request:**
- local isn't ready (`/readyz` failing, or the backend unreachable);
- the request would wait beyond its deadline (estimated from queue depth × recent service time);
- the local call errors or times out.

Local is retried once only if the deadline leaves room.

**Per-client policy (config), because the data differs:**

| Client | Fallback allowed | Notes |
|---|---|---|
| TradeFlow Sentinel | **Yes** | Public headlines only. |
| LeadScout | **No by default** | It may send personal data about leads, so fallback needs an explicit opt-in, and possibly redaction rules. Without fallback it gets queueing and 503s. |

**Budget**
- A monthly spend cap per client and an overall cap on fallback.
- At 80% of a cap, an alert. At 100%, that client's fallback stops and it gets local service or 503s.
- Spend is computed from `usage` tokens × configured prices.

**Provider**
- Any OpenAI-compatible host serving Qwen3-14B. Configured by base URL, model name, API key and prices.
- Keep a second provider configurable.
- Use the same model and quantization family where possible, so answers stay consistent.

**Recovery**
- When local becomes ready again, traffic returns to it automatically.
- Hysteresis: local must answer successfully for N consecutive checks first.

## 6. Model and hardware

- **Model:** `qwen3:14b`, with the tag and quantization pinned in config; Q4_K_M by default, about 9–10 GB. Record the model's checksum, and reject a backend that reports a different model.
- **Context window:** 8k tokens by default (enough for the Sentinel's batched prompts). More context costs more memory.
- **Warm:** keep the model loaded (`keep_alive` = forever), and run a warm-up prompt at start and after a reload.
- **Hardware today:** MacBook Pro, Apple M4 Pro, 48 GB. That's plenty of memory, but:
  - A laptop sleeps, travels and changes networks. For "on by default", use an always-on machine (a Mac mini with 24–32 GB, or a PC with a 16 GB+ GPU), or keep the laptop plugged in with sleep disabled (`pmset`/`caffeinate` while the service runs).
  - The serving machine must not be the TradeFlow engine's machine once the engine is remote. Locally, the engine and the model already compete for CPU (Ollama measured at about 88% CPU and 15 GB).
- **Optional smaller model:** keep `qwen3:8b` configurable. Choose it only if it matches 14B on a recorded set of headlines (§9).

## 7. Security and network

- **No public port.** Bind to localhost and a private network only. Recommended: Tailscale, so the remote TradeFlow host and LeadScout reach the gateway by its tailnet name. If you use Tailscale, also restrict access with its access rules.
- **Keys:**
  - One API key per client app, stored hashed. Keys can be rotated and revoked.
  - The client name is derived from the key, not taken from a header.
- **Secrets:**
  - The fallback provider's key is held only by the gateway, read from the environment or macOS Keychain.
  - Never logged, never committed. `.env*` is in `.gitignore` from the first commit.
- **Logging and privacy:**
  - Prompts and responses are **not** logged by default. Only metadata is: client, tokens, latency, served-by, cache hit, error.
  - A per-client debug flag may log bodies to a local file with rotation, never for LeadScout by default.

## 8. Operations

- **Process management:**
  - launchd plists (`local.llmgateway.gateway`, plus Ollama's own) on macOS; systemd units on Linux.
  - Restart on crash.
  - The gateway starts after the backend and stays not-ready until the warm-up succeeds.
- **Config:** one file (`config.toml`): clients, keys (hashed), priorities, limits, fallback providers, prices, budgets, model pin, slots, cache TTL. Reloadable without a restart.
- **Observability:**
  - Prometheus metrics per client: requests, tokens in and out, queue time, service time, p50/p95, cache hits, fallback count and reason, spend.
  - A one-page status at `/` for humans.
- **Alerts** (Discord webhook or bot channel, same pattern as TradeFlow):
  - local not ready for more than 5 min;
  - fallback rate above X% for 15 min;
  - budget at 80% and 100%;
  - p95 queue time above a client's deadline.
- **Upgrades:** the model is swapped by changing the pin, warming up, then cutting over. Roll back by changing the pin back.

## 9. Testing and acceptance

**Unit tests**
- Priority ordering and the reserved interactive slot.
- Preemption and the fallback decision under each reason.
- Per-client fallback policy, including LeadScout denied by default.
- Budget caps.
- Cache keys.
- The API key maps to the client.
- Thinking is off by default.

**Load test** (tests run against a fake backend with tunable latency):
- 50 LeadScout batch requests in flight and a Sentinel interactive request arriving. The interactive one is served within its deadline, locally or by fallback; with fallback disabled, by preemption.

**Failure tests**
- Backend down, backend slow, fallback down, both down (503), budget exhausted, and recovery hysteresis.

**Quality check**
- A recorded set of TradeFlow headlines with expected labels, including the 2026-11-23 BTC false positives: Binance hack recovery, laundering through mixers, Chainflip's BTC theft.
- Run against local and the fallback provider. Both must agree on at least 95% of labels before go-live.

**Acceptance criteria**
1. The Sentinel runs through the gateway for 7 days.
2. p95 interactive latency under 15 s.
3. Zero entries blocked because of the gateway itself, apart from outages that were alerted.
4. Fallback spend within budget.
5. LeadScout traffic never pushes Sentinel requests past their deadline.

## 10. Milestones

1. **Evaluate LiteLLM proxy (half a day).** Check whether it can do the strict priority classes, the reserved slot and the per-client fallback rules. If yes, configure it instead of building §2's gateway, and keep §4's queue as a thin addition only if needed.
2. **Minimal gateway:**
   - the OpenAI-style endpoint;
   - per-client keys;
   - the local backend with the model pinned and kept warm;
   - health and metrics.

   Point TradeFlow's Sentinel at it, still in paper.
3. **Fallback:** the provider, deadline-based fallback, budget caps and alerts.
4. **Priority and isolation:** queues, the reserved slot, preemption, the load test.
5. **LeadScout onboarding** once its workload and data rules are defined.
6. **Optional:** a batch endpoint and response caching tuned per client.

## 11. Open questions

1. **Serving hardware:** keep the MacBook Pro (M4 Pro, 48 GB), or buy or repurpose an always-on box? This decides the uptime goals.
2. **LeadScout:**
   - requests a day, prompt and response sizes, and latency needs;
   - whether its prompts contain personal data, and if so whether the fallback may ever see it.
3. **Fallback provider:** which host, and the monthly caps for TradeFlow and for LeadScout.
4. **Gateway:** build in Rust or adopt LiteLLM (decided after milestone 1).
5. **Network:** Tailscale, or another private network?
6. **TradeFlow:** should the Sentinel also do classify-each-article-once (TradeFlow-side change)? It cuts the gateway's load about 50×.
