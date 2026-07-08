# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FatVPN is a cross-platform VPN app (Flutter mobile + .NET 10 BFF + Telegram bot) fronting a **Remnawave** VPN panel. The Android app is feature-complete and device-tested: pairing onboarding, on-the-fly trial, real sing-box VPN tunnel, split tunneling, live server ranking, EN/RU. Auth uses an access+refresh token split with a "subscription expired → renew" screen (e2e-verified on emulator 2026-07-08). See `docs/app-bff-integration.md` for the full status log and what's left (chiefly: trial reinstall anti-abuse, HTTPS+domain/prod migration, iOS tunnel). Work lives on branch `feat/pairing-onboarding` (not yet merged to `master`).

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

### Flutter app (`app/`)

```bash
# Get dependencies
cd app
flutter pub get

# List devices / emulators
flutter devices
flutter emulators

# Launch the Pixel 7 API 35 emulator
flutter emulators --launch pixel_7_-_api_35_0

# Run on a specific device
flutter run -d emulator-5554
```

- Android SDK lives at `C:\Android\Sdk` (moved off the default `%LOCALAPPDATA%` path because it contained a space, which breaks NDK tooling). `flutter config --android-sdk` points at it.
- Org/package id: `com.fatvpn.fatvpn_app`.
- If a `flutter run` is killed mid-build on Windows, the next Gradle run can fail with a file-lock `IOException` on `app\build\...`. Fix: `cd app/android && ./gradlew.bat --stop`, then delete `app/build`, then retry.

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
| POST | `/internal/pair/complete` | `X-Bot-Secret` | Bot completes pairing by code → binds Account |
| POST | `/internal/account/subscription` | `X-Bot-Secret` | Bot upserts an account's current subscription (create/change/extend) |
| POST | `/auth/token` | none | App exchanges short token for access+refresh (legacy deep-link path) |
| POST | `/auth/refresh` | none | App exchanges refresh token for a fresh access (rotates refresh) |
| POST | `/auth/logout` | none | Best-effort refresh-token revocation (always 204) |
| POST | `/trial` | none | Grants a trial: creates a Remnawave user on the fly, returns access+refresh |
| POST | `/pair/start` | none | App starts pairing; returns pairCode + pollToken |
| GET | `/pair/status` | pollToken | App polls until the bot completes pairing (returns access+refresh) |
| GET | `/servers` | JWT Bearer | Country-grouped Remnawave node list (402 if subscription lapsed) |
| GET | `/me` | JWT Bearer | Subscription status/expiry |
| GET | `/config` | JWT Bearer | Subscription config proxied as-is from Remnawave (402 if lapsed) |

### Key Design Decisions

- **Bot auth**: Telegram bot calls `/internal/*` with a shared secret (`Bot:Secret`). The app never talks to Remnawave directly.
- **Session tokens (access + refresh split, see `docs/api-contract.md` "Модель токенов")**: A session is a short access JWT (**30 min**, `Jwt:AccessTokenLifetime`) plus a long, revocable, rotating refresh token (**90 days**, `Jwt:RefreshTokenLifetime`, stored hashed as `RefreshToken`). The JWT lifetime is **decoupled** from the subscription; entitlement is checked live per request, and `/config`/`/servers` return **402** when the subscription has lapsed (vs 401 for a bad token). The app refreshes silently, so an extension or key change never forces re-pairing.
- **JWT claim**: `fatvpn_account_id` (pairing sessions) or `fatvpn_token_id` (legacy deep-link / trial) identifies the session; the BFF resolves the current Remnawave subscription live on each request (`SubscriptionResolver`).
- **Pairing**: The app is the entry point — `POST /pair/start` → user opens the bot via `t.me/<bot>?start=pair<code>` → bot calls `/internal/pair/complete` → app polls `/pair/status` and connects. `Account` (keyed by Telegram user id) holds the current subscription, kept fresh by the bot.
- **Trial**: `POST /trial` creates a Remnawave user on the fly (squad `Remnawave:TrialSquadUuid`, `Trial:DurationDays`, currently 2). Anti-abuse: `Device` stores a salted hash of the `attestationToken` (409 on repeat). ⚠️ The token is a random per-install key — reinstall = new trial; real Play Integrity / SSAID binding is still TODO (see `docs/api-contract.md`).
- **Remnawave subscription proxy**: `/config` proxies raw Remnawave response as-is (currently returns base64 vless:// URIs). Sing-box JSON format requires configuring templates in Remnawave panel.

### Infrastructure / Configuration

- **Postgres**: `fatvpn` DB on port `5433` (host), `5432` (container). Credentials: `fatvpn`/`fatvpn_dev`.
- **Remnawave**: Base URL in `appsettings.json`; `ApiToken` via `dotnet user-secrets` (UserSecretsId: `3d5f08d5-dec7-4629-8e42-bc979ebe72cf`).
- **JWT**: HS256, `FatVpn.Bff` issuer, `FatVpn.App` audience. Dev secret in `appsettings.Development.json`.

### Production Server (87.121.221.229)

| Component | Path | Container |
|---|---|---|
| BFF | `/opt/fatvpn-bff/backend/` | `fatvpn-bff` (**public** `0.0.0.0:5030`, HTTP) |
| Bot (Python) | `/opt/FatVPN/` | `fatvpn-bot` |
| Postgres | — | `fatvpn-postgres` (`127.0.0.1:5433`, localhost-only) |

> **State as of 2026-07-06:** BFF is exposed publicly over **HTTP** for the pairing demo (app APK points at `http://87.121.221.229:5030`). The BFF checkout is on branch **`feat/pairing-onboarding`**, not `master` — merge once validated. `ufw` is enabled (allows `22`/`5030`/`4444`). Postgres was moved off `0.0.0.0` to localhost. Next: HTTPS + domain (see `docs/app-bff-integration.md` pairing section).

Docker network `fatvpn_default` is shared between `fatvpn-bot` and `fatvpn-bff` so the bot reaches BFF via `http://fatvpn-bff:5030`. The network is declared in both compose files — no manual `docker network connect` needed after restarts:
- Bot compose (`/opt/FatVPN/docker-compose.yml`): `networks.default.name: fatvpn_default`
- BFF compose (`/opt/fatvpn-bff/backend/docker-compose.yml`): `networks.fatvpn_default: external: true`, bff service connected to both `default` and `fatvpn_default`

`BOT_SECRET` is set in BFF container env (`Bot__Secret`), not in a file — retrieve with `docker inspect fatvpn-bff`.

⚠️ **TODO before `/trial` goes live on prod:** `Trial__DeviceKeySalt` container env must be set to a real random value — it's empty in `appsettings.json` by default (falls back to an unsalted hash, not a hard failure, but weakens device-key privacy). Set it the same way as `Bot__Secret` (container env, not a file). See `docs/api-contract.md` for details.

✅ **Server hardening done (2026-07-06):** Postgres moved to `127.0.0.1:5433` (BFF compose), `ufw` enabled (`22`/`5030`/`4444`). Postgres creds are still weak (`fatvpn`/`fatvpn_dev`) — rotate before real prod. Note: Docker-published ports bypass `ufw`, so the BFF (`5030`) stays reachable regardless; the real protection for Postgres is the localhost bind.

⚠️ **Fixed a pre-existing bug (2026-07-06):** `/opt/FatVPN/docker-compose.yml` had a duplicated `networks:` key — `docker compose` v2 refused to parse it, silently blocking bot redeploys. Removed the duplicate (backup at `/root/bot-compose.yml.bak`).

Deploy BFF: `cd /opt/fatvpn-bff/backend && git pull && docker compose build --no-cache bff && docker compose up -d bff`  
Deploy bot: `cd /opt/FatVPN && docker compose build --no-cache && docker compose up -d --force-recreate`

### Docs

- `docs/app-bff-integration.md` — status of wiring the Flutter screens to the real BFF (done/pending, deep-link auth flow)
- `docs/api-contract.md` — BFF API reference
- `docs/ui-design-spec.md` — Flutter UI spec
- `docs/bot-integration-spec.md` — Telegram bot integration spec (deep-link token flow)
- `docs/bot-pairing-spec.md` — standalone dev spec for the bot-side pairing changes (new Account-based onboarding)
- `VPN-App-Project.md` — master project document (Russian): requirements, 10-day plan, open questions
