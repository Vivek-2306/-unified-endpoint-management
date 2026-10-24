---
name: UEM NestJS Migration
overview: 'A linear guide you implement yourself. Each phase has the commands to run, the code hints to integrate, and an exit check. Every hop between processes uses TLS, and agent and relay bodies are AES-256-GCM on top of that.'
todos:
  - id: phase-0
    content: 'Phase 0 — install Node 22, pnpm 9, Docker, and OpenSSL, then confirm versions'
    status: pending
  - id: phase-1
    content: 'Phase 1 — create the pnpm workspace and empty app packages'
    status: pending
  - id: phase-2
    content: 'Phase 2 — generate a local CA and TLS certificates for every process'
    status: pending
  - id: phase-3
    content: 'Phase 3 — start PostgreSQL, Redis, Kafka, and ClickHouse with TLS only'
    status: pending
  - id: phase-4
    content: 'Phase 4 — implement packages/crypto and packages/contracts and test the round trip'
    status: pending
  - id: phase-5
    content: 'Phase 5 — add SQL migrations, RLS, and the Kysely migrator'
    status: pending
  - id: phase-6
    content: 'Phase 6 — build the HTTPS satellite API, sessions, and the command lease'
    status: pending
  - id: phase-7
    content: 'Phase 7 — build the worker, Kafka TLS producer, and ClickHouse Kafka engine'
    status: pending
  - id: phase-8
    content: 'Phase 8 — build the HTTPS relay buffer and the agent poll loop'
    status: pending
  - id: phase-9
    content: 'Phase 9 — package the Windows and Linux installers, GUI and silent'
    status: pending
  - id: phase-10
    content: 'Phase 10 — build the HTTPS console'
    status: pending
  - id: phase-11
    content: 'Phase 11 — run the exit tests and the full enroll-command-result loop'
    status: pending
isProject: false
---
# UEM platform migration

This repo is empty, so this is a new implementation of the architecture in the guide, not a line-by-line port of the .NET tree. You write the code. Each phase below tells you the commands to enter, the files to add, and the code to integrate. Finish the exit check before starting the next phase.

The first build is one working loop: enroll a site relay and a device, deliver a command through the PostgreSQL lease queue, execute it on the agent, and show the result in the console. Patch rings, MDM, cloud discovery, MeshCentral, and AI normalization stay designed and unbuilt.

## Encryption rule

Every byte that moves between two processes is encrypted in transit. That includes local Docker Compose. Plaintext listeners are not part of this design.

- TLS 1.2 or newer, with certificate verification left on, for the console, the API, the worker health port, the relay, PostgreSQL, Redis, Kafka, and ClickHouse. Clients trust a local dev CA through `NODE_EXTRA_CA_CERTS`. They do not set `NODE_TLS_REJECT_UNAUTHORIZED=0`.
- Agent and relay HTTP bodies are AES-256-GCM on top of TLS. The JSON shape is `{ "encryptedPayload": "<base64>" }`. The wire bytes are `base64(nonce(12) ‖ tag(16) ‖ ciphertext)`. The key is HKDF-SHA256 of the session secret, with a distinct `info` label per purpose (`agent-session`, `client-batch`, `command-body`).
- The API decrypts a relay batch and stores analytics JSON in `event_outbox`. The worker publishes that JSON to Kafka over TLS. ClickHouse has to read fields, so the Kafka value is not a second ciphertext. The hop is still encrypted by TLS.
- The console sends ordinary JSON over HTTPS. The session is an httpOnly cookie. There is no AES layer in the browser.

## Linear build guide

Do these phases in order. Commands assume the repo root.

### Phase 0 — tools

Confirm the toolchain. Install whatever is missing before continuing.

```bash
node -v
corepack enable
corepack prepare pnpm@9.15.0 --activate
pnpm -v
docker --version
docker compose version
openssl version
```

Exit check: `node -v` prints v22.x, `pnpm -v` prints 9.x, and `docker compose version` succeeds.

### Phase 1 — workspace

Create the workspace and one `package.json` per app. Leave the apps empty except for a `src/main.ts` that prints its name.

```bash
pnpm init
mkdir -p apps/satellite-api/src apps/satellite-worker/src apps/satellite-client/src apps/endpoint-agent/src apps/console packages/crypto/src packages/contracts/src packages/db/migrations deploy/certs
```

`pnpm-workspace.yaml`:

```yaml
packages:
  - "apps/*"
  - "packages/*"
```

Root `package.json` scripts to add once the apps exist: `dev`, `test`, `db:migrate`. Each package sets `"engines": { "node": ">=22" }` and `"type": "module"`.

```bash
pnpm install
pnpm -r exec node -e "console.log(process.cwd())"
```

Exit check: the recursive command prints all eight package directories.

### Phase 2 — dev CA and certificates

Generate a local CA and one server certificate per process. Private keys stay gitignored. The script may be re-run; it is the source of the certs.

```bash
openssl genrsa -out deploy/certs/dev-ca.key 4096
openssl req -x509 -new -nodes -key deploy/certs/dev-ca.key -sha256 -days 825 \
  -out deploy/certs/dev-ca.crt -subj "/CN=UEM Dev CA"
```

For each name in `api`, `worker`, `relay`, `console`, `postgres`, `redis`, `kafka`, `clickhouse`, create a key and a CSR, then sign it with the CA. Put `DNS:localhost` and `IP:127.0.0.1` in the SAN, plus the Compose service name (`DNS:postgres`, `DNS:redis`, `DNS:kafka`, `DNS:clickhouse`).

```bash
openssl verify -CAfile deploy/certs/dev-ca.crt deploy/certs/api.crt
```

Add `deploy/certs/*.key` to `.gitignore`. Keep the script under `scripts/dev-ca.sh`.

Exit check: `openssl verify` prints `OK` for every certificate.

### Phase 3 — infrastructure over TLS

Write `compose.yaml`. Publish only TLS ports. Map PostgreSQL `5432` to host `54329`, Redis `6379` to `63799`, Kafka `9093` to `19092`, ClickHouse HTTPS `8443` to `18123`. Do not publish PostgreSQL without SSL, Redis plaintext `6379`, Kafka `PLAINTEXT`, or ClickHouse `8123`.

Hints for the server configs:

- Postgres image `postgres:16-alpine`. Command flags `ssl=on`, `ssl_cert_file`, `ssl_key_file`, `ssl_ca_file`. `pg_hba.conf` uses `hostssl`.
- Redis image `redis:7-alpine`. `redis-server --port 0 --tls-port 6379 --tls-cert-file ... --tls-key-file ... --tls-ca-cert-file ...`.
- Kafka image `apache/kafka:3.9` in KRaft. Listener `SSL://0.0.0.0:9093` with `ssl.keystore` built from the kafka cert. Create topic `uem.telemetry` with 6 partitions, 7-day retention, `compression.type=lz4`. Replication factor 1 locally.
- ClickHouse image `clickhouse/clickhouse-server:24.8`. Config sets `<https_port>8443</https_port>` and the certificate. Leave the Kafka engine table for Phase 7.

```bash
docker compose up -d
docker compose ps
psql "postgresql://uem:uem@127.0.0.1:54329/uem?sslmode=verify-full" -c "select version();"
redis-cli --tls -h 127.0.0.1 -p 63799 --cacert deploy/certs/dev-ca.crt PING
```

`PGSSLROOTCERT` must point at `deploy/certs/dev-ca.crt` for the `psql` check.

Exit check: `psql` returns PostgreSQL 16, and `redis-cli` returns `PONG`. Kafka and ClickHouse show healthy in `docker compose ps`.

### Phase 4 — crypto and contracts

Implement `packages/crypto` with Node `crypto` only. Derive a 32-byte key with `hkdfSync('sha256', secret, salt, info, 32)`. Salt is the fixed string `uem-salt-v1`. Encrypt with `aes-256-gcm`, a random 12-byte nonce, and `getAuthTag()`. Concatenate `nonce ‖ tag ‖ ciphertext` and base64-encode it. Decrypt throws when the tag does not match. Do not fall back to AES-CBC.

```ts
import { createCipheriv, hkdfSync, randomBytes } from "node:crypto";

export function encrypt(plaintext: string, secret: string, info: string): string {
  const key = Buffer.from(hkdfSync("sha256", Buffer.from(secret), Buffer.from("uem-salt-v1"), Buffer.from(info), 32));
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([nonce, cipher.getAuthTag(), ciphertext]).toString("base64");
}
```

Write the matching `decrypt`. In `packages/contracts`, define Zod schemas for the envelope, the register body, the command message (`executionId`, `type`, `timeoutSeconds`, `args`), and the topic name `uem.telemetry`.

```bash
pnpm --filter @uem/crypto test
```

Exit check: a test encrypts and decrypts `"ping"`, and a test that flips one ciphertext byte expects a throw.

### Phase 5 — schema

Add SQL files in `packages/db/migrations`, in filename order. The runner records each filename in `schema_migrations` and applies the file inside a transaction. The API calls this runner before it listens. No repository runs `CREATE TABLE`.

First migration: the tables listed in the PostgreSQL section below, plus this policy pattern on every tenant-owned table:

```sql
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE agents FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agents
  USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

The queue claim, used by the API in Phase 6, is one statement:

```sql
WITH claimed AS (
  SELECT id FROM agent_command_queue
  WHERE agent_id = $1
    AND expires_at > now()
    AND available_at <= now()
    AND delivery_count < 10
    AND (status = 'pending' OR (status IN ('leased', 'acknowledged') AND lease_until < now()))
  ORDER BY created_at
  LIMIT 10
  FOR UPDATE SKIP LOCKED
)
UPDATE agent_command_queue q
SET status = 'leased',
    lease_until = now() + interval '2 minutes',
    delivery_count = delivery_count + 1,
    updated_at = now()
FROM claimed
WHERE q.id = claimed.id
RETURNING q.command;
```

Kysely connects with `ssl: { ca: readFileSync(process.env.TLS_CA_PATH), rejectUnauthorized: true }`. `DATABASE_URL` uses `sslmode=verify-full`.

```bash
export NODE_EXTRA_CA_CERTS="$PWD/deploy/certs/dev-ca.crt"
pnpm --filter @uem/db migrate
psql "$DATABASE_URL" -c "\dt"
```

Exit check: `\dt` lists `agent_command_queue` and `event_outbox`. A query with no `app.tenant_id` set returns zero rows from `agents`.

### Phase 6 — satellite API

Scaffold NestJS 11 on the Fastify adapter in `apps/satellite-api`. Listen with the API certificate.

```ts
const app = await NestFactory.create(AppModule, new FastifyAdapter({
  https: {
    key: readFileSync(process.env.TLS_KEY_PATH!),
    cert: readFileSync(process.env.TLS_CERT_PATH!),
    ca: readFileSync(process.env.TLS_CA_PATH!),
  },
}));
await app.listen(43110, "0.0.0.0");
```

Build the modules in this order: health, identity, tenancy, agents, commands, relay ingest.

- Abort startup when `JWT_PRIVATE_KEY_PEM`, `JWT_PUBLIC_KEY_PEM`, or `ENCRYPTION_MASTER_KEY` is missing. Sign user JWTs with RS256, issuer `uem-satellite-api`, audience `uem-console`.
- On each request, run `select set_config('app.tenant_id', $tenant, true)` on the checked-out client before any query.
- `POST /api/agents/register` requires an enrollment token. Hash the token, compare with Argon2id, and reject an unknown token with 401. New agents start as `pending` unless that token has `auto_approve`.
- `POST /api/agents/authenticate` returns the session token encrypted under the agent bearer key (`info` label `agent-session`). The session filter decrypts `X-Session-Token` and compares it to the stored session.
- Command create inserts `agent_command_queue` with `ON CONFLICT (execution_id) DO NOTHING` in the same transaction as `command_executions`.
- Lease, acknowledge, and complete use the claim SQL from Phase 5. Acknowledge sets `lease_until` to `now() + (timeout_seconds || ' seconds')::interval + interval '60 seconds'`, clamped to `expires_at`.
- `POST /api/relay/batch` decrypts the body with the client session key (`info` label `client-batch`). Insert `relay_batches (batch_id)` first. A unique violation means the batch was already applied. Return 200 without writing again.
- Redis uses `rediss://` and the dev CA. Every `SET` passes a TTL.
- ioredis and `pg` both set `rejectUnauthorized: true`.

```bash
export NODE_EXTRA_CA_CERTS="$PWD/deploy/certs/dev-ca.crt"
pnpm --filter @uem/satellite-api dev
curl --cacert deploy/certs/dev-ca.crt https://127.0.0.1:43110/health
curl --cacert deploy/certs/dev-ca.crt -X POST https://127.0.0.1:43110/api/agents/register \
  -H 'content-type: application/json' \
  -d '{"hardwareFingerprint":"abc","enrollmentToken":"nope"}'
```

Exit check: `/health` returns 200, and register with a bad token returns 401. An `http://` curl to port 43110 fails because nothing speaks plaintext there.

### Phase 7 — worker, Kafka, ClickHouse

`apps/satellite-worker` boots the same Nest context with no controllers, and an HTTPS health server on `43113`. It is the only process that constructs a Kafka producer.

```ts
const producer = kafka.producer({
  idempotent: true,
  allowAutoTopicCreation: false,
});
await producer.connect();
```

KafkaJS `ssl` is `{ ca: [readFileSync(caPath)], rejectUnauthorized: true }` and the broker list is `127.0.0.1:19092`. Produce with `acks: -1`. The message key is `agentId`. Stamp `published_at` only after the send promise resolves.

Leader lock: `SET uem:worker:leader <token> NX PX 15000`. Renew every 5 seconds with a Lua script that deletes the key only when the value equals the token. If Redis errors, take `pg_try_advisory_lock` on a constant bigint.

Two loops, leader only:

- Every 15 seconds, `UPDATE agent_command_queue SET status = 'dead' WHERE status NOT IN ('completed', 'dead') AND (delivery_count >= 10 OR expires_at < now())`.
- Every 2 seconds, claim up to 100 outbox rows with `FOR UPDATE SKIP LOCKED` where `published_at IS NULL AND attempts < 10`, publish, then set `published_at`. On failure, increment `attempts` and store `last_error`.

ClickHouse reads Kafka over TLS. Engine settings to put on `uem_telemetry_queue`:

```sql
SETTINGS
  kafka_broker_list = 'kafka:9093',
  kafka_topic_list = 'uem.telemetry',
  kafka_group_name = 'clickhouse-uem-telemetry',
  kafka_format = 'JSONEachRow',
  kafka_security_protocol = 'ssl',
  kafka_ssl_ca_location = '/certs/dev-ca.crt',
  kafka_skip_broken_messages = 0;
```

The destination table is `ReplacingMergeTree(version)` with `ORDER BY (tenant_id, agent_id, event_time, event_id)`, `PARTITION BY toYYYYMM(event_time)`, and `TTL event_time + INTERVAL 2 YEAR`. A materialized view copies the queue into that table.

```bash
pnpm --filter @uem/satellite-worker dev
```

Exit check: insert one `event_outbox` row from `psql`. Within a few seconds `published_at` is set, and ClickHouse shows the row. Query latest state with `argMax`, not a bare `SELECT`, because `ReplacingMergeTree` deduplicates at merge time.

### Phase 8 — relay and agent

Relay (`apps/satellite-client`) listens on `43111` with its own certificate. It uses `better-sqlite3` at `BUFFER_DB_PATH`, WAL mode, `busy_timeout = 5000`. It does not open PostgreSQL, Redis, Kafka, or ClickHouse.

Loops, all always on:

- Every 30 seconds, `GET /api/relay/agent-tokens` with the cached generation. HTTP 304 keeps the SQLite copy.
- Every 5 seconds, `POST /api/relay/commands/lease` and store the encrypted command bodies.
- Every 30 seconds, flush up to 30 batches. Each batch is at most 500 items or 400 KB, encrypted with the client session key. Stop the tick when the pending count does not fall. Purge synced rows older than 7 days. Move rows with `retry_count >= 5` to `dead`.

Agent polls hit the relay, not the API. The relay serves leased commands from SQLite. The catch-all proxy preserves `Authorization`, adds `X-Client-Id`, passes 401 through, and refuses `/api/internal`.

The agent is a Node worker, not a Nest app. It reads `relayUrl`, `enrollmentToken`, and `dataDir` from its config file. Use `fetch` with an `undici` `Agent` whose `ca` is the dev CA. Encrypt every body. Heartbeat every 20 seconds. Poll every 10 seconds. Run at most 2 commands, tracked with a counter you decrement in `finally`. Execute with `execFile` and `shell: false`, and ignore any `shell` field on the command. Before running, check the local set of completed `execution_id`s.

```bash
pnpm --filter @uem/satellite-client dev
pnpm --filter @uem/endpoint-agent dev
```

Exit check: stop the API, post a heartbeat to the relay, and see HTTP 200 plus a new SQLite row. Start the API again and see that row flush. A second run of the same `execution_id` does not launch a process.

### Phase 9 — installers

The installer writes the config file and starts the service. The agent process only reads that file.

```bash
pnpm --filter @uem/endpoint-agent package
```

That script bundles `agent.cjs` with esbuild, downloads the Node 22 runtime for the target OS, and wraps it.

- Windows, from NSIS: `apps/endpoint-agent/dist/installers/UEMEndpointAgent-<version>-win-x64.exe`. GUI on double-click. Silent from `cmd`: `UEMEndpointAgent-<version>-win-x64.exe /S /RELAY=https://127.0.0.1:43111 /TOKEN=enr_...`. Service host is WinSW.
- Linux: `sudo ./UEMEndpointAgent-<version>-linux-x64.run --relay https://127.0.0.1:43111 --token enr_...`. With no flags, use Zenity when it exists, otherwise Whiptail. The script creates user `uem-agent`, writes `/etc/uem/agent.json` mode 0600, installs a systemd unit, and starts it.

Ship the dev CA file next to the installer for local installs, and point the agent config `caPath` at it. A real deployment replaces that with the site CA.

Exit check: `sha256sum` of the Linux `.run` matches the checksum file the package script writes. `--help` prints the relay and token flags. A silent install against a running relay produces a heartbeat in the API.

### Phase 10 — console

```bash
cd apps/console
pnpm dlx create-next-app@latest . --ts --tailwind --eslint --app --src-dir --use-pnpm
pnpm dlx shadcn@latest init
```

Run the dev server on HTTPS with the console certificate, port `43112`. Set `API_URL=https://127.0.0.1:43110` and `NODE_EXTRA_CA_CERTS` to the dev CA. The browser never receives the API JWT as a JavaScript-readable value. A route handler sets an httpOnly cookie.

Pages, in this order: sign in, fleet list (empty, loading, error), enrollment token, install-an-endpoint (download plus the silent command), approve a pending agent, send a command, command status, agent detail with last heartbeat.

```bash
pnpm --filter @uem/console dev
```

Exit check: `https://127.0.0.1:43112` loads the sign-in page in a browser that trusts `dev-ca.crt`. Signing in with the dev user reaches an empty fleet.

### Phase 11 — prove the loop

Run the tests, then the full path.

```bash
pnpm test
```

Tests that have to pass:

- Two concurrent leases of the same agent return disjoint rows.
- A second insert with the same `execution_id` inserts nothing.
- Register without a valid enrollment token returns 401.
- Tampering with an AES-GCM payload throws.
- Replaying a `batch_id` does not complete a command twice.
- The executor ignores a caller-supplied shell name.

Then start Compose, the API, the worker, the relay, and the console. Install the agent with the silent Linux command, approve it if the token is not auto-approve, send a script command from the console, and watch the status move `pending` to `leased` to `acknowledged` to `completed`.

Exit check: the console shows the command output, `event_outbox.published_at` is set, and ClickHouse has the same `execution_id`.

## Spec the phases implement

## Framework decision

**Build the control plane and the LAN relay in NestJS 11 on Fastify, TypeScript.** That is the right platform language for this system.

- The control plane is a large modular monolith (identity, tenancy, agents, commands, relay ingest, inventory), which is what Nest modules, guards, and a separate worker bootstrap express well. Spring Boot would reproduce the same shape with a heavier runtime and a second language. A Go or Rust API would fight the size of the domain. FastAPI is a poor fit for dozens of long-running workers and a typed multi-app contract.
- Fastify, not Express. The old `uem-rbac-proxy` Express process goes away. The API verifies the user JWT itself. Trusting `X-User-Id` from a proxy is a spoofable identity boundary.
- The endpoint agent is a **plain Node worker** that imports shared packages, not a Nest application. A DI container on every laptop is wasted memory. The thing operators install is not a source tree: slice 1 publishes a Windows installer and a Linux installer, and each one supports a GUI wizard and a silent command-line install. A later Go agent can speak the same contract if the installed footprint matters. Rust is only justified later for the update verifier. Java on endpoints is the wrong footprint.
- Shared code lives in `packages/contracts` (Zod) and `packages/crypto` (AES-256-GCM + HKDF-SHA256, wire format `base64(nonce ‖ tag ‖ ciphertext)`).

## Target shape

```mermaid
flowchart TB
    subgraph cloud [Cloud]
        UI[console Next.js]
        API[satellite-api NestJS]
        Worker[satellite-worker same codebase]
        PG[(PostgreSQL)]
        RD[(Redis)]
        KF[(Kafka analytics only)]
        CH[(ClickHouse)]
    end
    subgraph lan [Customer LAN]
        SC[satellite-client NestJS]
        SQ[(SQLite buffer)]
    end
    subgraph device [Endpoint]
        AG[endpoint-agent installed by Windows or Linux setup]
    end
    UI -->|user JWT| API
    API --> PG
    API --> RD
    Worker --> PG
    Worker -->|outbox publish| KF
    KF --> CH
    SC -->|bulk lease and batch flush| API
    SC --> SQ
    AG -->|LAN poll heartbeat results| SC
```

Three tiers stay. Each exists for the same reasons as the original: agents do not egress to the internet, the relay authenticates and buffers through a WAN outage, and a site downloads a payload once.

**Transport ADR.** The PostgreSQL lease queue is the only command plane. Do not port the two dormant SignalR hubs. They are an unauthenticated command surface with no client. Agents poll the relay every 10 seconds. The relay bulk-leases commands for its own agents and serves those polls from SQLite, so command pickup is LAN-local and cloud request rate is per site, not per device. A lost WAN link still blocks new leases. Already-leased commands still run. A later wake channel, if added, may only say "poll now". It must not become a second delivery path.

## What stays, and what changes

Keep:

- Status machine `pending → leased → acknowledged → completed`, with `dead` after 10 deliveries. Claim with `FOR UPDATE SKIP LOCKED`, 2-minute lease, `UNIQUE(execution_id)` plus `ON CONFLICT DO NOTHING`.
- Store-and-forward on the relay: ack the agent when SQLite commits, flush in bounded batches, stop the flush when depth does not fall.
- Polyglot data: PostgreSQL for authoritative state, ClickHouse for append-only telemetry, Redis for sessions and leader locks, SQLite on the relay and the agent.
- Envelope-encrypted agent session tokens. Proof of possession by authenticated decryption. Four principals: user, agent, satellite client, internal service.
- Safe process execution: fixed shell, argument vector, ignore any caller-supplied shell name, concurrency cap.

Fix in this design, before code:

- Enrollment requires a one-time tenant enrollment token. Unknown devices land in `pending` until the console approves them. Dev seed can auto-approve one token so the demo still runs. Missing secrets abort startup. JWT is RS256 with issuer and audience checks. Signing key and encryption key are separate; HKDF `info` labels derive purpose-specific keys.
- Tenant isolation is PostgreSQL row-level security driven by `SET LOCAL app.tenant_id` on every request, plus the application `WHERE`. A forgotten filter is no longer the only barrier.
- Presence comes from `agent_heartbeat_current.last_contacted`. No in-process agent registry.
- HTTP API and schedulers are different processes with different environment variables. They share SQL through `packages/db`. Two API replicas do not run schedulers. The worker uses a Redis lock with a PostgreSQL advisory-lock fallback. Correctness of command delivery still comes from `SKIP LOCKED`.
- Relay buffer calls the purge of synced rows and moves `RetryCount >= 5` to a `dead` state that is visible, not a silent skip.
- Relay batches dedupe on `batch_id`. The agent stores executed `execution_id`s and skips a redelivery.
- Kafka is analytics only. Publish goes through a PostgreSQL outbox in the same transaction as the state change. Producer uses `acks=all`, idempotence, and key `agentId`. Consumer commits after the sink acknowledges. Local compose may use replication factor 1; the setting is environment-driven.
- One schema path: ordered SQL files. No startup `CREATE TABLE` inside repositories.
- Correlation ids and OpenTelemetry on the agent → relay → API → database path. Structured logs with `pino`.
- TLS on every hop, including Compose, with verification on. Agent and relay bodies add AES-256-GCM. Hubs that can dispatch commands are not built.

## Finalized technical requirements

One git repository. Five runnable code environments, two shared packages, and four infrastructure processes. Versions below are the ones slice 1 is built against.

### Repository and toolchain

- Runtime: Node.js 22 LTS. `engines.node` is `>=22`. The endpoint installer bundles that same major version per OS and arch.
- Package manager: pnpm 9, workspace file `pnpm-workspace.yaml`. TypeScript 5, `strict` on, in `packages/tsconfig`.
- Tests: Vitest. API queue tests run against the Compose PostgreSQL. Crypto and executor tests run in-process.
- Lint and format: ESLint plus Prettier. One command from the root starts infra, migrates, and runs every app.
- Layout:
  - `apps/satellite-api` — HTTP control plane. Package `@uem/satellite-api`.
  - `apps/satellite-worker` — scheduled jobs. Package `@uem/satellite-worker`. Separate process and environment from the API, sharing SQL through `packages/db`.
  - `apps/satellite-client` — LAN relay. Package `@uem/satellite-client`.
  - `apps/endpoint-agent` — device worker and installer scripts. Package `@uem/endpoint-agent`.
  - `apps/console` — operator UI. Package `@uem/console`.
  - `packages/contracts` — Zod schemas and topic names. No I/O.
  - `packages/crypto` — HKDF-SHA256 and AES-256-GCM. No I/O.
  - `packages/db` — Kysely types, SQL migrations, migrator. Used by the API and the worker only.
- Local secrets live in `.env` files copied from `.env.example`. Missing production secrets abort startup. Compose passwords are local-only values such as `uem` / `uem`.

Host ports, chosen so they do not collide with common defaults. All of them are TLS:

- Console `https://127.0.0.1:43112`, API `https://127.0.0.1:43110`, worker health `https://127.0.0.1:43113`, relay `https://127.0.0.1:43111`.
- PostgreSQL host `54329` with `sslmode=verify-full`. Redis host `63799` on the TLS port only (`rediss://`).
- Kafka SSL host `19092` (container `9093`). ClickHouse HTTPS host `18123` (container `8443`). Do not publish a plaintext port for any of these.

### satellite-api

- NestJS 11, Fastify adapter, `pino`, `jose` (RS256), `argon2`, `pg` pool max 10, Kysely, `ioredis`, Zod validation pipe, OpenTelemetry.
- Listens with its own certificate on `0.0.0.0:43110`. Routes under `/api`. `GET /health` (liveness) and `GET /ready` (PostgreSQL and Redis reachable).
- Connects to PostgreSQL and Redis over TLS. Writes telemetry by inserting `event_outbox` in the same transaction as the state change. This process does not open a Kafka connection and does not open a ClickHouse connection.
- Required environment: `DATABASE_URL` (`sslmode=verify-full`), `REDIS_URL` (`rediss://`), `TLS_KEY_PATH`, `TLS_CERT_PATH`, `TLS_CA_PATH`, `JWT_PRIVATE_KEY_PEM`, `JWT_PUBLIC_KEY_PEM`, `JWT_ISSUER=uem-satellite-api`, `JWT_AUDIENCE=uem-console`, `ENCRYPTION_MASTER_KEY`, `INTERNAL_SERVICE_TOKEN`, `CORS_ORIGIN`. JWT issuer and audience validation are on. The encryption key is a different value from either JWT key.
- User session JWT lifetime 24h. Agent bearer key lifetime 8h. Agent session lifetime 24h. Satellite client session lifetime 120 minutes. Client secrets stored as Argon2id hashes.
- Dev seed, only when `SEED_DEV_DATA=true`: one tenant, one domain, user `admin@uem.local`, and one auto-approve enrollment token printed in the API log.

### satellite-worker

- Same Nest application context, no controllers. HTTPS health listener only, on `43113`.
- Connects to PostgreSQL (pool max 5), Redis, and Kafka, all with TLS and `rejectUnauthorized: true`. Required environment adds `KAFKA_BROKERS=127.0.0.1:19092`, `KAFKA_CLIENT_ID=uem-satellite-worker`, `KAFKA_TOPIC_TELEMETRY=uem.telemetry`.
- One leader runs the loops. Standby processes stay up and retry the lock every 5 seconds. Acquire with Redis `SET uem:worker:leader <token> NX PX 15000`, renew every 5 seconds with a compare-and-delete Lua script. If Redis is down, fall back to `pg_try_advisory_lock` on a fixed bigint. Command correctness still comes from `FOR UPDATE SKIP LOCKED` on the queue.

### satellite-client

- NestJS 11 on Fastify. `better-sqlite3` for the buffer. `@fastify/http-proxy` for the catch-all. `cockatiel` for jittered retries toward the API.
- Listens with its own certificate on `0.0.0.0:43111`. This process does not connect to PostgreSQL, Redis, Kafka, or ClickHouse.
- Required environment: `SATELLITE_API_URL=https://127.0.0.1:43110`, `CLIENT_ID`, `CLIENT_TOKEN`, `BUFFER_DB_PATH`, `PORT`, `TLS_KEY_PATH`, `TLS_CERT_PATH`, `TLS_CA_PATH`. Upstream calls verify the API certificate.
- Tunables, with these defaults: flush every 30s, prefetch leases every 5s, token sync every 30s, batch cap 500 items or 400 KB, purge synced rows after 7 days, skip to `dead` at retry count 5.
- The proxy keeps the agent `Authorization` header, adds `X-Client-Id`, passes 401 through, and refuses to forward `/api/internal`.

### endpoint-agent

- Plain Node 22 worker bundled by esbuild to `agent.cjs`. No Nest, no inbound port. It talks only to the relay URL in its config file.
- Config path after install: `C:\ProgramData\UEM\agent.json` or `/etc/uem/agent.json` (mode 0600). Fields: `relayUrl`, `enrollmentToken`, `dataDir`.
- Intervals: heartbeat 20s, command poll 10s, at most 2 command executions at once. An `execution_id` already stored locally is not run again.
- Identity file in `dataDir` is encrypted with the shared AES-GCM helper. The installer writes config and starts the service. The running agent does not read installer flags.

### console

- Next.js current stable, React, Tailwind, shadcn/ui. Dev server on `43112`.
- Server-side environment: `API_URL=https://127.0.0.1:43110`, `SESSION_SECRET`, `TLS_KEY_PATH`, `TLS_CERT_PATH`, `TLS_CA_PATH`. The browser holds an httpOnly session cookie. The console has no database and no queue client. JSON on this hop is protected by HTTPS.

### PostgreSQL

- Image `postgres:16-alpine`. Database `uem`, user `uem`. SSL on, `hostssl` in `pg_hba.conf`, clients use `sslmode=verify-full`. Isolation left at the server default, Read Committed. The queue claim is safe because the lock is explicit.
- Access library is Kysely plus SQL files. The claim statement is a hand-written CTE: select eligible ids `ORDER BY created_at LIMIT 10 FOR UPDATE SKIP LOCKED`, then `UPDATE ... FROM claimed` setting `status='leased'`, `lease_until = now() + interval '2 minutes'`, `delivery_count = delivery_count + 1`, and `RETURNING` the payload.
- Migrations are ordered files in `packages/db/migrations/*.sql`, applied by one runner, recorded in `schema_migrations(filename primary key, applied_at)`. Startup of the API runs the migrator and then serves traffic. Repositories do not issue DDL.
- Extension `pgcrypto`. RLS enabled on tenant-owned tables. Each request runs `SELECT set_config('app.tenant_id', $1, true)` and policies require `tenant_id = current_setting('app.tenant_id')::uuid`. The worker sets the tenant id per row it processes.
- Tables and the columns that define behavior:
  - `tenants`, `domains` (`tenant_id`).
  - `users` (`tenant_id`, email unique, password hash, role).
  - `enrollment_tokens` (`tenant_id`, token hash, `expires_at`, `auto_approve`, `use_count`).
  - `agents` (`tenant_id`, `agent_id` unique, fingerprint hash, `status` pending or active, `client_id` nullable).
  - `agent_credentials` (bearer key hash, current session token, expiry).
  - `satellite_clients` (`tenant_id`, `client_id`, secret hash, `token_generation` bigint bumped when the token set changes).
  - `agent_command_queue` (`execution_id` unique, `agent_id`, `command` jsonb, `status`, `lease_until`, `delivery_count`, `available_at`, `expires_at`). Partial index on `(agent_id, created_at)` for rows still in `pending`, `leased`, or `acknowledged`.
  - `command_executions` (`execution_id`, workflow status, result summary for the console).
  - `agent_heartbeat_current` (`agent_id` primary key, `last_contacted`, hostname, IP, agent version). Live means `last_contacted` within 60 seconds. That threshold is computed on read. There is no presence job.
  - `relay_batches` (`batch_id` unique, `client_id`, received at).
  - `event_outbox` (`id`, `topic`, `message_key`, `payload` jsonb, `created_at`, `published_at`, `attempts`, `last_error`).

### Redis

- Image `redis:7-alpine`. Plaintext port disabled. Clients use `rediss://` and verify the dev CA. Used for session cache, the worker leader lock, and register rate limits. Every `SET` includes a TTL. There is no key without an expiry.
- Key names and TTLs: `agent_session:{id}` 24h, `agent_bearer:{id}` 8h, `client_session:{id}` 120m, `uem:worker:leader` 15s, `ratelimit:register:{ip}` 1 minute.
- PostgreSQL remains the source of truth for the session token. Redis is a cache. A flush logs everyone out of the cache and the next call reloads from PostgreSQL.

### SQLite

- Relay file `buffer.db`, `better-sqlite3`, journal mode WAL, `busy_timeout` 5000 ms. Tables: `buffered_relay_items`, `leased_commands`, `active_agent_tokens`.
- Agent identity file is encrypted with AES-256-GCM. It stores the agent id, bearer key, and the set of completed `execution_id`s.

### ClickHouse

- Image `clickhouse/clickhouse-server:24.8`. HTTPS on `8443`, published as host `18123`. The Kafka engine uses `kafka_security_protocol = 'ssl'`. Database `uem`. Workload is device telemetry: many relays, bursts, duplicates from retries, latest-state and aggregate reads. Operational lookups stay in PostgreSQL.
- Ingestion path is the Kafka engine plus a materialized view ([Kafka engine](https://clickhouse.com/docs/engines/table-engines/integrations/kafka), derived). The API does not insert into ClickHouse.
- Destination engine is `ReplacingMergeTree(version)` ([replacement pattern](https://clickhouse.com/docs/en/guides/replacing-merge-tree), official). `ORDER BY (tenant_id, agent_id, event_time, event_id)`. Latest-state queries use `argMax`, because replacement happens when parts merge.
- `PARTITION BY toYYYYMM(event_time)` and `TTL event_time + INTERVAL 2 YEAR` ([partitions](https://clickhouse.com/docs/partitions), derived). Current heartbeats stay in PostgreSQL. A 20-second heartbeat series is not written to ClickHouse in this slice.
- `kafka_skip_broken_messages = 0`, so a poison payload stalls that consumer instead of disappearing. The outbox row remains the replay source.

### Message queue

Kafka is the analytics bus. It is not the command bus. There is no `uem.commands` topic and no BullMQ, RabbitMQ, or SQS.

- Image `apache/kafka:3.9`, KRaft, single node in Compose. The only listener is `SSL://0.0.0.0:9093`, published on host port `19092`. Clients verify the broker certificate.
- Topic `uem.telemetry`: 6 partitions, retention 7 days, `compression.type=lz4`, `cleanup.policy=delete`. Message key is `agentId`. Local replication factor is 1 and `min.insync.replicas` is 1. Both are environment settings. Production values are replication factor 3 and `min.insync.replicas` 2.
- The only producer is the worker. KafkaJS settings: `idempotent: true`, `acks: -1`, compression `lz4`, finite retries. A publish counts as done when the delivery report succeeds. The outbox row is then stamped `published_at`.
- The only consumer in this slice is the ClickHouse Kafka engine table `uem_telemetry_queue`, materialized into `uem.telemetry`. No application consumer commits offsets.

### Jobs

Cloud jobs run inside `satellite-worker`, and only on the leader.

- Dead-letter sweep, every 15 seconds. Marks `dead` when `delivery_count >= 10` or `expires_at` has passed, for rows not already `completed` or `dead`. A leased row whose `lease_until` has passed becomes claimable again inside the claim statement. That redelivery does not need its own job.
- Outbox publisher, every 2 seconds, batches of 100. Claims unpublished rows with `FOR UPDATE SKIP LOCKED`, publishes, then sets `published_at`. At `attempts >= 10` the row stays unpublished, `last_error` is set, and the loop moves on. Those rows are the visible failure list.
- Catalog sync, CVE sync, and ClickHouse-to-PostgreSQL rollups are the same leader loop later. They are not started in slice 1.

Relay loops, inside `satellite-client`, always on (one relay process per site, so no leader lock):

- Token sync every 30 seconds. Sends the cached `token_generation`. A matching generation returns 304 and the relay keeps its SQLite copy.
- Command prefetch every 5 seconds. `POST /api/relay/commands/lease` for agents of this client, store the leased payloads in SQLite, serve agent polls from that table.
- Flush every 30 seconds. Up to 30 batches per tick. Each batch is at most 500 items or 400 KB. If pending depth does not fall, the tick stops. Synced rows older than 7 days are purged on that tick. Rows at retry count 5 move to `dead`.

Agent loops, inside the installed service:

- Heartbeat every 20 seconds. Command poll every 10 seconds. Concurrency cap 2. Shutdown waits for in-flight commands up to the command timeout, then exits.

## Endpoint installers

The endpoint deliverable is an installation file per OS. Both files install the same agent, write the same config, and register a service. An upgrade replaces binaries and leaves the device identity in place.

Shared unattended contract, same meaning on Windows and Linux:

- Relay URL and enrollment token are required for a silent install.
- Optional install directory. Defaults are `C:\Program Files\UEM Endpoint Agent` and `/opt/uem-endpoint-agent`.
- Service install is the default. `--no-service` is the escape hatch for a foreground debug run.
- Uninstall is a flag on the same file. It stops the service and removes program files. It leaves `/etc/uem` and `C:\ProgramData\UEM` unless `--purge` is set, so a reinstall keeps the agent id.
- Exit codes: 0 success, 2 missing required silent arguments, 3 connectivity check failed, 4 service registration failed.

Windows artifact: `UEMEndpointAgent-<version>-win-x64.exe`, built with NSIS.

- GUI: double-click opens a wizard. Pages collect relay URL and enrollment token, run a connectivity check against the relay `/health`, show progress, and finish by starting the Windows service.
- Command line, from `cmd` or PowerShell: `UEMEndpointAgent-<version>-win-x64.exe /S /RELAY=https://relay.local:43111 /TOKEN=enr_...`
- Uninstall from cmd: `UEMEndpointAgent-<version>-win-x64.exe /S /UNINSTALL`
- The service host is WinSW, because `node.exe` does not handle Windows service stop correctly on its own. The service runs the bundled Node runtime against `agent.cjs`.

Linux artifact: `UEMEndpointAgent-<version>-linux-x64.run`.

- Command line: `sudo ./UEMEndpointAgent-<version>-linux-x64.run --relay https://relay.local:43111 --token enr_...`
- GUI: with no flags, a desktop session that has Zenity gets GTK dialogs for the same fields and the connectivity check. A terminal without Zenity gets a Whiptail wizard. If neither UI is available and flags were omitted, the installer prints the required command and exits 2.
- The installer creates user `uem-agent`, writes `/etc/uem/agent.json` mode 0600, installs a systemd unit, and starts it.
- Uninstall: `sudo ./UEMEndpointAgent-<version>-linux-x64.run --uninstall`

Build and publish:

- `pnpm --filter @uem/endpoint-agent package` bundles the agent with esbuild, downloads the pinned Node runtime for that OS and arch, and collects the `better-sqlite3` prebuild. Node binaries are not committed.
- NSIS (`makensis`) produces the Windows exe from Linux. The Linux `.run` is a self-extracting script around the same payload layout.
- Artifacts land in `apps/endpoint-agent/dist/installers/` with a SHA-256 checksum file. Authenticode and GPG signing are a hook in that script. Slice 1 publishes checksums. Signing runs when a release key is present and does not block a local build.
- The console has an Install an endpoint page: pick Windows or Linux, mint an enrollment token, show the silent command with that token filled in, and offer the installer download. The API serves the built files in local dev.

macOS uses this same flag contract later. It is not part of this slice.

## Slice 1 behavior

Operator console:

- Sign in, see an empty fleet, create an enrollment token and a satellite client credential.
- Open Install an endpoint, download the Windows or Linux installer, and copy either the GUI steps or the silent command.
- Approve a pending agent. Live, stale, and pending states are distinct.
- Send a script command to selected agents. Watch `pending`, `leased`, `acknowledged`, `completed`, and `dead`.
- Open an agent and see last heartbeat plus the last result.

API:

- User login issues an RS256 JWT.
- `POST /api/agents/register` rejects a missing or unknown enrollment token.
- Agent authenticate returns a session token encrypted under that agent's bearer key.
- `POST /api/relay/commands/lease`, acknowledge, and complete implement the claim SQL.
- `POST /api/relay/batch` dedupes on `batch_id`, completes executions, and writes the outbox.
- Heartbeat upsert. Health and readiness endpoints.

Relay and agent:

- Relay syncs tokens on a generation watermark (full pull only when the generation changes), validates edge sessions locally, buffers results, prefetches leases, and purges synced rows.
- Agent derives an id from a sanitized fingerprint, enrolls, heartbeats, polls the relay, runs the command with a bounded worker pool, and skips an `execution_id` it already finished.
- After a GUI or silent install, the service starts on its own and enrolls with the token the installer wrote. A second install upgrades the binaries without minting a new agent id.

Tests that must exist before the slice is called done: two workers cannot lease the same row; a second enqueue with the same `execution_id` inserts nothing; registration without a token returns 401; crypto round-trip including a tampered tag fails; a replayed `batch_id` does not double-complete; the agent executor ignores a caller-supplied shell.

Local stack is Docker Compose: PostgreSQL, Redis, Kafka, and ClickHouse on TLS, plus the apps on the HTTPS ports above. README explains the loop, the transport ADR, and the phase commands. No committed secrets. Compose uses obvious local-only passwords. Private keys under `deploy/certs/` stay gitignored.

## Later slices, not this build

- Inventory discovery into ClickHouse and a software-normalization claim pipeline.
- Agentless SSH and WinRM behind one executor interface, credentials in memory only.
- Patch cache on the relay, token-bucket throttle, and rings.
- Remote control only after per-device authorization and an audit record. MeshCentral stays a separate process.
- Authenticode and GPG signing of the installers once a release key is available, a macOS package using the same flags, and a Go agent only if the installed Node footprint is too large.
