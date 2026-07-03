# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FatVPN is a cross-platform VPN app (Flutter mobile + .NET 10 BFF + Telegram bot) fronting a **Remnawave** VPN panel. The project is currently at Day 2 of a 10-day plan — the BFF backend is built; the Flutter mobile app does not exist yet.

## Commands

All commands run from the `backend/` directory unless noted.

```bash
# Start Postgres (required before running the API)
docker-compose up -d

# Build
dotnet build FatVpn.Bff.slnx

# Apply EF migrations
dotnet ef database update --project src/FatVpn.Bff.Infrastructure --startup-project src/FatVpn.Bff.Api

# Add a new migration
dotnet ef migrations add <MigrationName> --project src/FatVpn.Bff.Infrastructure --startup-project src/FatVpn.Bff.Api

# Run the API (http://localhost:5030)
dotnet run --project src/FatVpn.Bff.Api

# Set Remnawave API token (required once per machine, not in git)
cd src/FatVpn.Bff.Api
dotnet user-secrets set "Remnawave:ApiToken" "<token>"
```

Manual API testing: `src/FatVpn.Bff.Api/FatVpn.Bff.Api.http` has VS Code REST Client requests for every endpoint.

No test projects exist yet.

## Architecture

```
Flutter App ──HTTPS/JWT──► FatVPN BFF (.NET 10) ──Bearer──► Remnawave panel
                                    │                         (z.fatvdsnvv.space)
Telegram Bot ──X-Bot-Secret──► /internal/tokens
                                    │
                              PostgreSQL :5433
```

### Solution Projects (`backend/src/`)

| Project | Purpose |
|---|---|
| `FatVpn.Bff.Api` | ASP.NET Core Web API — controllers, DI wiring, entry point |
| `FatVpn.Bff.Domain` | Plain entity classes: `Token`, `Device`, `Trial`, `FatVpnClaimTypes` |
| `FatVpn.Bff.Infrastructure` | EF Core DbContext, JWT service, Remnawave HTTP client, migrations |

### API Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | none | Health check |
| POST | `/internal/tokens` | `X-Bot-Secret` header | Bot registers short-token → Remnawave subscription ID |
| POST | `/auth/token` | none | App exchanges short token for JWT |
| GET | `/servers` | none | Country-grouped Remnawave node list |
| GET | `/me` | JWT Bearer | Subscription status/expiry |
| GET | `/config` | JWT Bearer | sing-box JSON config proxied from Remnawave |

`POST /trial` is scaffolded in domain but not yet implemented.

### Key Design Decisions

- **Bot auth**: Telegram bot calls `/internal/tokens` with a shared secret (`Bot:Secret`). The app never talks to Remnawave directly.
- **JWT claim**: The custom claim `fatvpn_token_id` carries the `Token.Id` so the BFF can look up the Remnawave subscription on each authenticated request.
- **Remnawave subscription proxy**: `/config` streams the sing-box config from `GET /sub/{id}?format=singbox` — no auth on the Remnawave side, the subscription URL is the credential.
- **Trial anti-abuse**: `Device` stores a hashed device key. `Trial` records grants. Both tables are scaffolded but the trial endpoint is not yet built.

### Infrastructure / Configuration

- **Postgres**: `fatvpn` DB on port `5433` (host), `5432` (container). Credentials: `fatvpn`/`fatvpn_dev`.
- **Remnawave**: Base URL in `appsettings.json`; `ApiToken` via `dotnet user-secrets` (UserSecretsId: `3d5f08d5-dec7-4629-8e42-bc979ebe72cf`).
- **JWT**: HS256, `FatVpn.Bff` issuer, `FatVpn.App` audience. Dev secret in `appsettings.Development.json`.

### Docs

- `docs/api-contract.md` — BFF API reference
- `docs/ui-design-spec.md` — Flutter UI spec
- `docs/bot-integration-spec.md` — Telegram bot integration spec
- `VPN-App-Project.md` — master project document (Russian): requirements, 10-day plan, open questions
