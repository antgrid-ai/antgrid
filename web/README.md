# Antgrid License API

Bun + Hono service. Handles identity (GitHub/Google/magic-link), device-flow activation, JWT issuance, device lifecycle.

## Dev

```bash
cp .env.example .env
# fill secrets (OAuth providers, etc.), then:
# Run a local Postgres 16+ (e.g. via installer or docker run ...)
bun install
bun run migrate
bun run dev
```

## Test

```bash
export PG_DATABASE_URL='postgres://postgres:pass@localhost:5432/postgres'
# ADO.NET form also accepted: 'Host=...;Database=...;Username=...;Password=...'
bun test
```

The test helper (`tests/helpers/pg.ts`) creates an ephemeral per-file database on the
Postgres at `PG_DATABASE_URL`, runs migrations, and drops it at teardown. No
container/Docker required — a plain local Postgres is enough.

## Pending work

- **Relay ↔ web M2M auth.** Current design only covers web → relay push (HMAC-signed `/internal/revoke`, `/internal/expire`), and the relay doesn't implement those handlers yet. The reverse path (relay → web, e.g. real-time jti revocation lookups) has no auth mechanism. Design and implement a shared M2M scheme (mTLS or signed service tokens) after the current implementation is verified end-to-end.

## Deploy

Target: Azure Container Apps + Azure Database for PostgreSQL Flexible Server, with secrets in Azure Key Vault. Deployment tooling (bicep / GitHub Actions) is not yet in this repo.
