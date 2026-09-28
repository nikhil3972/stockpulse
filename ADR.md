# StockPulse: architecture decision record

Format: Context → Options → Decision → Tradeoffs. Only what is actually built is claimed here.

## ADR-1: Where commerce logic lives, and a modular monolith

**Context.** One developer, one domain, one five-hour build. The design must still show clean seams.
**Options.** (a) Microservices: pricing, inventory and advisor services plus a broker. (b) One Spring Boot app with strict layering.
**Decision.** Modular monolith. Controllers handle HTTP only. `SuggestionService` coordinates. Strategies make the decisions. Repositories persist. Entities hold simple state rules (`recordSale`, `recomputeStatus`, `accept`/`reject`). Packages (`strategy`, `ai`, `event`) are the future split points.
**Tradeoffs.** More classes than a script. The AI part cannot be scaled on its own yet. There is no network hop, broker or distributed transaction, and the README runs in one command.

## ADR-2: Separate PricingStrategy and ReorderStrategy (two LLM calls)

**Context.** Price and quantity are different decisions. A competitor-aware strategy would only affect pricing.
**Options.** (a) One combined "advise" call that returns both. (b) Two interfaces, two calls.
**Decision.** Two interfaces: `PricingStrategy.suggest(PricingContext)` and `ReorderStrategy.suggest(ReorderContext)`. Contexts and results are plain records with no JPA, so every strategy is unit-tested without a database. Each type has its own fallback, and engines can be mixed (for example AI pricing with rule-based reorder, the default).
**Tradeoffs.** Two calls use more quota and latency. A combined call is a later optimisation.

## ADR-3: Runtime strategy switching

**Context.** The demo and operations need to flip AI ↔ rules without a redeploy.
**Options.** (a) `@RefreshScope` / Spring Cloud Config. (b) A bean map plus an atomic "active" name.
**Decision.** Spring injects `Map<String, PricingStrategy>` and `Map<String, ReorderStrategy>` (bean names `pricingAi`, `pricingRuleBased`, …, exposed as `ai` / `ruleBased`). `StrategyRegistry` holds an `AtomicReference<String>` per type. `PUT /admin/strategy` switches it, and an unknown name returns 400. HTTP handlers and async listeners use the same path. A new strategy is one new `@Component`.
**Tradeoffs.** The choice resets to the configured default on restart. `@RefreshScope` was rejected as too heavy for one flag.

## ADR-4: LLM provider and failure handling

**Context.** LLM calls can time out, hit 429, return prose instead of JSON, or propose absurd values. The brief's suggested models (Gemini 1.5 Flash, Llama 3.1 on Groq) are retired.
**Decision.**
- **Provider:** Google Gemini `gemini-3.5-flash-lite` through the native `generateContent` API, called with Spring `RestClient`. `responseMimeType: application/json` is set. The key is sent in the `x-goog-api-key` header, read only from `GEMINI_API_KEY`, and never logged. An `OpenAiCompatibleGateway` sits behind the same `LLMGateway` interface for Groq or others (`llm.provider=openai-compatible`).
- **Timeouts:** connect 3 s, read 15 s. There is **no retry loop** on 429.
- **Defensive parsing:** strip ``` fences, take the outermost `{…}`, parse with Jackson ignoring unknown fields, and accept enums in any case.
- **Bounds validation:** price > 0 and within ±50 % of current; confidence in 0–1; direction must match the sign of the delta; quantity 1..10 × threshold. The prompt also states these bounds.
- **Fallback:** any failure is logged and the rule-based result is returned with `source = RULE_FALLBACK` and the reason in `reasoning`. LLM exceptions never reach the HTTP client.
- The LLM call runs **outside** any DB transaction. Only the short save runs in a transaction (`SuggestionWriter`).
**Tradeoffs.** The ±50 % limit would block a genuine large repricing. With no retry, a transient 429 yields a rules answer rather than a slower AI one.

## ADR-5: The agentic loop

**Context.** Suggestions must be triggered by real signals, must not block the sale request, and must not duplicate.
**Options.** (a) A scheduler that scans products every N seconds. (b) Domain events.
**Decision.** `POST /products/{id}/orders` (in a transaction) does stock −1 and velocity +1 per unit. It publishes `InventoryLowEvent` if stock < threshold, and `DemandSpikeEvent` if velocity > `spike.multiplier` × the category average excluding the product itself. It returns immediately. Two thin listeners (`@Async("advisorExecutor") @TransactionalEventListener(AFTER_COMMIT)`, on a pool with prefix `advisor-`, core 4, max 8, queue 100) call one shared `SuggestionService.generate`. Events carry IDs only. Listener bodies are wrapped in try/catch and logged.
Dedupe works per product + trigger + type. An `existsBy…PENDING` check is the normal guard. A unique, nullable `dedupe_key` (for example `PRD-003:INVENTORY_LOW:PRICING`) is the safety lock when two orders race, and a `DataIntegrityViolationException` is treated as "skip". Accept or reject sets the key to NULL, so the next signal can create a new suggestion. A scheduler was rejected because it reacts late and is not signal-driven.
**Tradeoffs.** In-memory events are lost on a crash. That is acceptable for advisory suggestions; a transactional outbox is the upgrade path. `@Version` on `Product` can make a sale that races with an advisor write return 409. The advisor write retries up to 3 times.

## ADR-6: Extensibility and exclusions

**Decision.** Nullable `cost_price` and `supplier_id` columns exist for sprint 2 (margin floor, supplier catalog). A margin-floor check would go in `SuggestionValidator`. A new trigger means an event, a listener and a prompt template. A new strategy is one `@Component`.
**Excluded on purpose:** auth, competitor data, auto-apply of prices, the outbox, Spring AI (2.0 targets Boot 4) and a multi-model "council" (double the cost and latency, and the human checkpoint already acts as the second opinion).
**Tradeoffs.** The unused placeholder columns add minor noise.

## Other decisions and known limitations

- **Human checkpoint.** Prices and stock change only through `PATCH …/{id}` with `ACCEPTED`. The status change and the value change happen in one transaction. A product returns to ACTIVE only when no pending pricing suggestion remains and stock > 0. Pricing and reorder suggestions are independent.
- **PostgreSQL instead of H2.** Postgres runs in Docker Compose on host port 5433, the schema is managed by Flyway, and Hibernate runs `ddl-auto=validate`. This is closer to production (a real unique index on a nullable column, `NUMERIC` money, `TIMESTAMPTZ`) at the cost of needing Docker.
- **React 18 + Vite, plain `fetch`, no UI library.** This was the fastest path to a working console. The Vite dev proxy (`/api` → `:8080`) avoids CORS in dev, and CORS is also configured for `http://localhost:5173`. The console polls every 3 s.
- **Velocity counter.** "Orders in the last 24 h" is a counter on `Product` that never decays. The upgrade is an `orders` table with timestamps and `countByProductIdAndCreatedAtAfter(id, now − 24h)`.
- **Rule-based reorder.** The quantity is `max(1, max(threshold × 3, velocity × leadTimeDays) − stock)`. When velocity is low this reduces to the spec's `threshold × 3 − stock` (15 × 3 − 8 = 37). It was extended because a demand spike on a well-stocked product would otherwise suggest reordering 1 unit.
- **Stale suggestions.** If a reorder fixes stock while a price increase is still pending, the price suggestion is left for the human. Auto-expiry is a future improvement.
