# sidekik-brain

Sidekik's judgment layer. During capture it decides **when** the expert has paused and **which** question is worth asking. For mapper and tutor it answers typed fuzzy decisions (D1–D12) through Jev. Spec: `docs/DESIGN.md`. System design: `docs/ARCHITECTURE.md`.

Private service, local port **8082**, Node ≥ 22.

## Run

```sh
pnpm install
docker compose -f ../sidekik-platform/dev/docker-compose.yml up -d redis
cp .env.example .env        # fill from the team vault
pnpm dev                    # watch mode
```

**Offline replay** of a capture session, with no teammates' services, no database and no API keys:

```sh
pnpm dev:mock                          # test/fixtures/capture_sabine_mock.jsonl at 20x; offline fakes when no keys are set
pnpm dev:mock path/to/x.jsonl --speed 1
pnpm dev:mock --fake                   # force the offline fakes even with keys
pnpm dev:mock --keep                   # keep serving after the replay
```

It ends with a summary of the `ask` commands brain published. Fixture lines are `{"stream": "sk:…", "ev": <Envelope>}`, and each replay gets fresh ids.

**Real providers:** `pnpm jev:smoke` calls each configured provider (TypeSafe, OpenRouter, Haiku) once with the Appendix A D1 example and prints the answers, latency and cost.

## Test

```sh
pnpm typecheck
pnpm test        # app.test.ts needs Redis (DB 14; override with TEST_REDIS_URL)
```

`test/checkpoint1.test.ts` replays the mock capture session on simulated time and checks the Checkpoint 1 definition of done:
- at least 3 asks, each at a pause;
- at least one `limit` or `stop_and_ask`;
- nothing asked during speech or within 3 s of typing;
- answers stored.

## How it works

```
screen.event ─► D2 (Jev, escalate mid-band to Haiku) ─► judgment/exception ≥0.80?
                                                          └─► planner (Haiku) drafts 1–2 questions ─► D4 checks qtype ─► questions row (candidate)
every 250 ms: pause gate (code: speech idle ≥1.2 s, screen still ≥2 s, no typing 3 s, <5 per 10 min, ≥60 s apart, candidate waiting)
                └─► D1 + D3 in one Jev call ─► pause & unanswered & best value ─► ask command + questions row (asked)
                                                └─► not yet: re-check once after 1 s, then hold until speech/screen changes
first user turn after an ask ─► D5 (escalate) ─► answers row (+ rule text by Haiku when there's a number/date condition)
every user turn ─► regex prefilter ─► D7 ─► ≥0.5 → gateway POST /internal/sessions/:id/off-record
task_done / phase change / ended / another record opened / 90 s ─► candidates expire (mapper reads them as open items)
```

Guardrail quota: after 2 asks without a `limit` or `stop_and_ask`, only those types can be asked.

### Jev layer (`src/jev/`)

- **Providers:** `TypeSafeJev` (`@typesafe-ai/sdk`, `jev-1.13.0`), with fallbacks `OpenRouterJev` (`typesafe/jev-1.13`) and then `LLMDecider` (Claude Haiku 4.5, `{answer, probability}` structured output, temperature 0). Scores are 1-based here (the wire format is 0-based) and are converted in `wire.ts`.
- **Router:** order is cache (60 s), then circuit breaker, then rate limiter, then the provider chain.
  - The breaker opens for 60 s after 2 rate limits, 1 timeout, or 1 call over `JEV_TIMEOUT_MS`.
  - The rate limiter allows 30 req/s and 80k tok/s.
- **Logging:** every call writes one `decisions_log` row per decision. The cost of a batched call is split evenly, and the counterfactual is the same prompt priced on Haiku. Each call also emits `sk:usage` records.
- **Pricing (2026-10-03):** Jev is $0.042 per 1M input tokens and output is free. Haiku 4.5 is $1 / $5 per 1M tokens (in / out).

### Decisions (`src/decide/`)

- `specs.ts` batches several decisions into one Jev request, with question names prefixed by decision (`D1__pause_now`).
- `decider.ts` applies the DESIGN §5 bands:
  - choice/score: act ≥0.80, escalate 0.55–0.80;
  - noul: act ≥0.85 or ≤0.15;
  - D7 is never escalated.
- `thresholds.ts` holds every threshold. Override them with `THRESHOLDS_JSON`.

## Endpoints

| Route | Auth | Notes |
|---|---|---|
| `GET /healthz` | none | `{ok, version, deps:{redis}}`; 503 if a dependency is down |
| `POST /internal/decide` | `X-Internal-Token` | See below |
| `GET /internal/sessions/:id/state` | `X-Internal-Token` | Debug snapshot of a session |

`POST /internal/decide` takes a `DecisionRequest` and returns `{results: DecisionResult[]}`:
- **Batching:** all decisions go to Jev in one call, with no escalation and a 550 ms budget.
- **Multi-question decisions:** each result's `answers` holds every question. `answer` is the first question's (D6 → `specificity`).
- **Errors:** 400 for an invalid request or for D3 (needs brain's candidates); 503 when providers are down or the budget runs out.

## Calibration

```sh
pnpm calibrate export --session <id> > rows.jsonl     # decisions_log → one row per question, label: null
# fill in "label" with the correct answer
pnpm calibrate report rows.jsonl --target 0.9          # accuracy per confidence bucket + a THRESHOLDS_JSON line
```

## Env

Every variable is in `.env.example`.
- **Vendor keys:** optional at boot. Without any, decisions fail fast. `dev:mock` switches to `FAKE_VENDORS=true`.
- **`PERSISTENCE=memory`:** keeps `questions`, `answers` and `decisions_log` in memory and the log, with no Supabase.

## Layout

| Path | Role |
|---|---|
| `src/main.ts`, `src/app.ts` | Entry point; `startBrain(env)` wires logger, bus, store, Jev router, capture parts and HTTP |
| `src/brain.ts` | Assembles the capture loop, answer handling and off-record watcher into bus hooks |
| `src/state.ts` | `SessionStore`: lifecycle, timers in session time, recent events and turns, capture state |
| `src/consumers.ts` | Bus consumers for lifecycle, speech, screen and turns |
| `src/pause.ts` | Pause gates (pure, table-tested) |
| `src/planner.ts`, `src/rules.ts` | Haiku question drafting and rule-text extraction |
| `src/capture/` | Capture loop, answers (D5), off-record (D7), repos, gateway client, per-session queue |
| `src/jev/` | Providers, router, breaker, limiter, cache, pricing, `decisions_log` sinks |
| `src/decide/` | Spec batching, bands and escalation, thresholds, `/internal/decide` |
| `src/calibrate.ts`, `scripts/calibrate.ts` | Confidence-bucket accuracy and threshold suggestions |
| `src/dev/fakes.ts` | Offline Jev, planner and rule extractor for `dev:mock` and tests |

## Deploy

`@sidekik/contracts` comes from a private GitHub repo, so the build needs a read-only GitHub token:

```sh
NPM_GITHUB_TOKEN=... docker build --secret id=NPM_GITHUB_TOKEN,env=NPM_GITHUB_TOKEN -t sidekik-brain .
```

On Railway, set `NPM_GITHUB_TOKEN` as a build variable; the Dockerfile also accepts it as a build arg. Only the install step uses the token, and the runtime image never contains it.

The image is `node:22-slim`. It runs as `node`, listens on `::` at `PORT`, and has a `/healthz` health check. Set every variable from `.env.example` in Railway.
