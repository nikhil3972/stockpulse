# StockPulse

AI inventory and dynamic-pricing **advisor** with a human in the loop.
When stock drops below its threshold or demand spikes, StockPulse notices on its own. It asks an AI (Google Gemini) or deterministic rules for a **price** suggestion and a **reorder** suggestion, then queues both as PENDING. Nothing changes until a merchandiser clicks Accept.

```
Observe (sale -> stock / velocity signal) -> Reason (AI or rules) -> Act (queue PENDING) -> Checkpoint (human accepts or rejects)
```

**Stack:** Spring Boot 3.5 (Java 21), PostgreSQL 16 (Docker, Flyway migrations), React 18 + Vite, Gemini `gemini-3.5-flash-lite`.

## Quick start (one command, needs only Docker)

```bash
./start.sh
```

Open http://localhost:3000. The first run builds the images (about 2–3 minutes). Later runs take seconds.

- **AI mode:** put your Gemini key in `.env` as `GEMINI_API_KEY=...`, then run `./start.sh` again. Get a free key at https://aistudio.google.com/apikey. `start.sh` creates `.env` from `.env.example` on the first run, and `.env` is git-ignored.
- **Without a key:** everything still works, and suggestions come from the rules (shown as *Rule fallback*).
- **Stop:** `./stop.sh`. Use `./stop.sh --reset` to also wipe the database, which is re-seeded on the next start.
- **Windows (no bash):** `docker compose up --build -d`, then open http://localhost:3000.
- Ports used: 3000 (console), 8080 (API), 5433 (Postgres).

## Developer setup (hot reload)

Prerequisites: Docker, JDK 21, Node 20+.
On macOS: `brew install openjdk@21 node@20`, then put `/opt/homebrew/opt/openjdk@21/bin` and `/opt/homebrew/opt/node@20/bin` on your `PATH`.

```bash
# 1. Database only (host port 5433, so an existing local Postgres on 5432 is left alone)
docker compose up -d postgres

# 2. Backend on :8080. The key is read from the environment only; never commit it.
export GEMINI_API_KEY=your-key            # optional: without it every AI call falls back to rules
cd backend && ./mvnw spring-boot:run

# 3. Console on :5173 with hot reload (in another terminal)
cd frontend && npm install && npm run dev
```

Flyway creates the schema and seeds 9 products on first start.
To reset the demo data: `docker compose down -v`, then start again.

Configuration (`backend/src/main/resources/application.yml`, overridable with environment variables):

| Setting | Default | Env var |
|---|---|---|
| `llm.model` | `gemini-3.5-flash-lite` | `LLM_MODEL` |
| `llm.api-key` | *(empty → rule fallback)* | `GEMINI_API_KEY` |
| `llm.provider` | `gemini` (`openai-compatible` also available) | `LLM_PROVIDER` |
| `stockpulse.strategy.pricing` / `.reorder` | `ai` / `ruleBased` | switch at runtime via `PUT /admin/strategy` |
| `stockpulse.spike.multiplier` | `2.0` | |
| datasource | `jdbc:postgresql://localhost:5433/stockpulse` | `DB_URL`, `DB_USER`, `DB_PASSWORD` |

Tests: `cd backend && ./mvnw test` runs 32 tests. They include a Testcontainers Postgres integration test of the whole loop, so Docker must be running.

## API

| Method + path | Purpose |
|---|---|
| `POST /products` | Create product |
| `GET /products?status=&category=` | Filterable list |
| `GET /products/{id}` | One product |
| `PATCH /products/{id}/stock` `{"stockLevel":n}` | Set stock; may fire INVENTORY_LOW |
| `POST /products/{id}/orders` `{"quantity":n}` (body optional, default 1) | Simulate a sale; may fire INVENTORY_LOW / DEMAND_SPIKE |
| `POST /products/{id}/suggest-pricing` | Manual pricing suggestion (synchronous) |
| `POST /products/{id}/suggest-reorder` | Manual reorder suggestion (synchronous) |
| `GET /pricing-suggestions?status=PENDING` | For the console |
| `GET /reorder-suggestions?status=PENDING` | For the console |
| `PATCH /pricing-suggestions/{id}` `{"status":"ACCEPTED"\|"REJECTED"}` | Accept updates the price |
| `PATCH /reorder-suggestions/{id}` `{"status":...}` | Accept adds stock (simulated shipment) |
| `GET / PUT /admin/strategy` `{"pricing":"ai"\|"ruleBased","reorder":...}` | View or switch the active strategy |

Error codes: 404 not found, 409 invalid state change / out of stock / duplicate, 400 validation or unknown strategy. LLM errors never reach the client; they trigger the rule fallback.

## Demo script (5 minutes)

1. **Problem and architecture** (30 s): one Spring Boot modular monolith. Strategy + registry for decisions, events for the agentic loop, and a human checkpoint.
2. **Low stock:** click **Sale** on *Classic Cotton T-Shirt* (PRD-003, stock 8 / threshold 15). The backend log shows an `advisor-` thread. *Inventory low* pricing (AI) and reorder cards appear. Accept the pricing card and reject the seeded *Initial review* card. The price updates and the status returns to Active.
3. **Demand spike:** click **Sell 5** on *Fleece Hoodie* (PRD-008). *Demand spike* cards appear. Click Sell 5 again: no duplicate card.
4. **Runtime switching and resilience:** toggle Pricing between AI and Rules in the header. Restart the backend without `GEMINI_API_KEY` (or with a bad one) and trigger again. A *Rule fallback* card still appears.
5. **ADR:** scroll through [ADR.md](ADR.md) and explain one tradeoff.

## Layout

```
backend/src/main/java/com/stockpulse
├── controller   HTTP only
├── service      ProductService, SuggestionService (coordination), SuggestionWriter (short write transactions)
├── strategy     Pricing/ReorderStrategy, rule-based implementations, StrategyRegistry
├── ai           LLMGateway (Gemini, OpenAI-compatible), PromptBuilder, LlmResponseParser, SuggestionValidator, AI strategies
├── event        InventoryLow/DemandSpike events and @Async listeners
├── domain       Product, PricingSuggestion, ReorderSuggestion, enums
├── repository   Spring Data JPA
├── dto          request/response records
├── exception    GlobalExceptionHandler
└── config       Async, CORS, RestClient, properties
backend/src/main/resources/prompts   six prompt templates (pricing/reorder × low-stock/spike/manual)
backend/src/main/resources/db/migration   Flyway schema + seed
frontend/src     React console (polls every 3 s)
```
