# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FatVPN is a cross-platform VPN app (Flutter mobile + .NET 10 BFF + Telegram bot) fronting a **Remnawave** VPN panel. The Android app is feature-complete and device-tested: pairing onboarding, on-the-fly trial (2 days, `Trial:DurationDays`), real sing-box VPN tunnel, split tunneling, live server ranking, local expiry reminders (client-scheduled `flutter_local_notifications`, no FCM), EN/RU. Auth uses an access+refresh token split with a "subscription expired → renew" screen (e2e-verified on emulator 2026-07-08). **iOS is now feature-complete and device-tested too** (2026-07-24): sing-box tunnel via a `PacketTunnel` Network Extension, split tunneling by domain/IP (per-app is impossible on iOS without MDM), DNS-leak/background/network-switch validated on a real iPhone; built via Codemagic → TestFlight (build 18). ⚠️ That validation covered "the tunnel carries traffic", not "the tunnel is correct": it never tested IPv6 leaks, a network switch **under load**, whether disconnecting actually restores the internet, recovery from a killed extension, or what stays on disk after logout — which is how the 2026-07-27 audit found three criticals in code that had passed. The audit remediation (2026-07-28) touches every layer of the iOS tunnel — including the TUN stack (`gvisor` → `system`), MTU, on-demand/kill-switch and the extension lifecycle — and **it compiles but has never been run**: Codemagic `ios-release` went green as **build 136** (2026-07-28), which proves the Swift builds, the `analyze && test` gate passes on CI, and the App Groups entitlement survives re-signing into the exported `.ipa` — and proves nothing about behaviour, since a broken tunnel compiles exactly as well as a working one. Treat build 18 as the last iOS data point about *behaviour*, and build 136 as the first about *buildability*. See `docs/ios-vpn-tunnel-spec.md` for the iOS story (its Phase 7 section now records what the validation did not cover) and `docs/app-bff-integration.md` for the full status log. That remediation was then **read back line by line (2026-07-28)** and 30 defects were found *in the fixes themselves* — 16 corrected on the spot, 14 still open, all listed under "Вычитка ремедиации" in `docs/improvement-plan-ios.md`. Two of those were CI defects that build 136 then exercised: the quality gate had no `set -e`, so a failing `flutter analyze` was printed and published anyway, and the App Group entitlement check read the archived bundle instead of the re-signed `.ipa` and passed green when it found nothing. The one still open and worth knowing: logout-by-401 and subscription-expiry (402) bypass the persisted-state wipe, which on iOS with on-demand means the OS can raise the tunnel on credentials the panel already revoked (V17). **Home-screen widgets landed 2026-07-28** (`docs/home-widgets-spec.md`): an Android app widget and an iOS WidgetKit extension rendering one shared snapshot — state, location, session clock — written by the app and, when the app is not running, by the tunnel itself (the plugin's state broadcast on Android, `PacketTunnelProvider` on iOS). Disconnecting is native on Android (one tap, no app); connecting always goes through the app, because raising the tunnel needs the live 402 entitlement check and a fresh config. The iOS widget is a **third bundle id** (`com.fatvpn.fatvpnApp.FatVpnWidget`) whose App ID needs the **App Groups** capability enabled in the Apple portal before the next TestFlight build — without it signing strips the entitlement and the widget can read nothing (the `codemagic.yaml` entitlement check now covers that appex, so the build fails instead). Neither platform's widget has been run. Remaining (non-iOS): trial reinstall anti-abuse, HTTPS+domain/prod migration. Work merged into `master` (pairing onboarding fast-forward 2026-07-09; iOS via squash 2026-07-24).

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

Tests: `dotnet test tests/FatVpn.Bff.Tests/FatVpn.Bff.Tests.csproj` — 113 tests (106 + 7 that skip without Docker).

- Unit/controller tests run on **SQLite in memory**, not the EF InMemory provider: InMemory ignores
  unique indexes and cannot execute `ExecuteUpdate`, so it could not exercise the atomic
  claim-and-rotate paths at all.
- `ConcurrencyIntegrationTests` spin up a real PostgreSQL via **Testcontainers** and hammer
  `/pair/status`, `/auth/refresh`, `/trial`, `/auth/token` and the account upsert with parallel
  callers. They need Docker running and **skip** (not fail) without it.

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
- **Release signing** (`cfe1f2b`): the keystore and its passwords live in `app/android/key.properties`, which is gitignored along with `*.jks`. A checkout **without** that file still builds — it falls back to the debug key and logs that it did — so `flutter run --release` works on a fresh clone and on CI. Before publishing, confirm the signature is real (`./gradlew :app:signingReport`, or `apksigner verify --print-certs` must not show `CN=Android Debug`).
- **Release ABIs:** x86/x86_64 are excluded from `release` via the Variant API (`androidComponents.onVariants(selector().withBuildType("release")) { variant.packaging.jniLibs.excludes }`), and the bundle splits by ABI and density (language split is off — Flutter ships its own localizations). ⚠️ Do **not** "simplify" this to `ndk { abiFilters }`: AGP takes the **union** of `abiFilters` across `defaultConfig` and the build type, and the Flutter Gradle plugin populates `defaultConfig` — so a filter there widens the set instead of narrowing it (verified: the AAB still shipped x86_64). Debug stays universal so it installs on the x86_64 emulator. Ship `flutter build appbundle`, not a universal APK — measured 2026-07-28: AAB 138.6 MB on disk (70.3 MB of that is debug symbols Play does not ship), per-device download 35.0 MB arm64 / 34.6 MB arm32, well inside the 200 MB base-module limit.
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
| GET | `/health` | none | Health check — now backed by a `DbContext` check (`ok` / `degraded`) |
| POST | `/internal/tokens` | `X-Bot-Secret` header | Bot registers short-token → Remnawave subscription ID |
| POST | `/internal/pair/complete` | `X-Bot-Secret` | Bot completes pairing by code → binds Account |
| POST | `/internal/account/subscription` | `X-Bot-Secret` | Bot upserts an account's current subscription (create/change/extend) |
| POST | `/auth/token` | none | App exchanges short token for access+refresh (legacy deep-link path) |
| POST | `/auth/refresh` | none | App exchanges refresh token for a fresh access (rotates refresh) |
| POST | `/auth/logout` | none | Best-effort refresh-token revocation (always 204) |
| POST | `/trial` | none | Grants a trial: creates a Remnawave user on the fly, returns access+refresh |
| POST | `/pair/start` | none | App starts pairing; returns pairCode + pollToken |
| GET | `/pair/status` | pollToken (query **or** `X-Pair-Poll-Token` header) | App polls until the bot completes pairing (returns access+refresh) |
| GET | `/servers` | JWT Bearer | Country-grouped Remnawave node list, cached 45 s (402 if subscription lapsed) |
| GET | `/me` | JWT Bearer | Subscription status/expiry (`status` is only ever `active` or `expired`) |
| GET | `/config` | JWT Bearer | Remnawave subscription, with our Hysteria2 hosts spliced in (402 if lapsed) |

Every public endpoint is rate limited per IP (`RateLimiting:*` — 300/min global, 20/min auth, 60/min `/pair/status`, 5/hour `/trial`) and answers **429 + `Retry-After`** over budget. A failed panel call is **502**, not 500. Full contract, including the required and optional configuration keys: `docs/api-contract.md`.

### Key Design Decisions

- **Bot auth**: Telegram bot calls `/internal/*` with a shared secret (`Bot:Secret`). The app never talks to Remnawave directly.
- **Session tokens (access + refresh split, see `docs/api-contract.md` "Модель токенов")**: A session is a short access JWT (**30 min**, `Jwt:AccessTokenLifetime`) plus a long, revocable, rotating refresh token (**90 days**, `Jwt:RefreshTokenLifetime`, stored hashed as `RefreshToken`). The JWT lifetime is **decoupled** from the subscription; entitlement is checked live per request, and `/config`/`/servers` return **402** when the subscription has lapsed (vs 401 for a bad token). The app refreshes silently, so an extension or key change never forces re-pairing. **Reuse detection**: presenting an already-revoked (rotated/logged-out) refresh token revokes the whole session family, forcing a re-pair (`AuthController.RevokeFamilyAsync`) — **except inside `Jwt:RefreshGraceWindow` (30 s)**, where a second presentation is treated as the app racing itself and is answered with another token of the same family. Rotation itself is one conditional `UPDATE`, so two parallel refreshes can no longer both succeed. The client should always keep the **last** refresh token it received.
- **JWT claim**: `fatvpn_account_id` (pairing sessions) or `fatvpn_token_id` (legacy deep-link / trial) identifies the session; the BFF resolves the current Remnawave subscription live on each request (`SubscriptionResolver`).
- **Pairing**: The app is the entry point — `POST /pair/start` → user opens the bot via `t.me/<bot>?start=pair<code>` → bot calls `/internal/pair/complete` → app polls `/pair/status` and connects. `Account` (keyed by Telegram user id) holds the current subscription, kept fresh by the bot. Pairing codes are **single-use**: `/pair/status` mints the session once, then flips the code to `Consumed` (`PairingStatus`) so a repeated poll can't hand out a second session; `/internal/pair/complete` only accepts a `Pending` code (409 otherwise).
- **Which key the app runs on** (2026-07-28): a user can hold several keys in the bot while the account carries exactly one active subscription, so every write says whether the user *chose* this key. Pairing and pasting a "Код для FatVPN App" are both explicit choices and both now produce an **account** session: `/internal/tokens` takes `telegramUserId` and stamps `Tokens.AccountId`, and `/auth/token` for an owned key writes that key into the account and issues `fatvpn_account_id`. Everything else (`/internal/account/subscription` without `makeActive`) only refreshes the key that is *already* active — extending key #2 used to drag a subscriber off key #1. Before this, a pasted key resolved through the `Tokens` row alone, which the bot only rewrites on reissue: extending a subscription left the app on "expired" and answered 404 to the user's own key. Keys with no owner (older bot builds, trial keys) behave exactly as before. The bot half is written too — pairing now asks *which* key when the user holds several, instead of silently taking the longest-lived one — and **uploaded to `/opt/FatVPN/bot` but not deployed** (originals kept as `<file>.pre-keychoice`; both containers still run the old images). Deploy order is BFF first: an old BFF silently ignores the new JSON fields. Reading the live bot also turned up something the spec never mentioned — merely *opening* a key's screen called `upsert_subscription`, so browsing your keys moved the app onto whichever you looked at last; that is what `replacesSubscriptionId` and the "an already-lapsed key is not worth protecting" rule exist for. Full change list and deploy commands: `docs/app-bff-integration.md`; acceptance checklist: `docs/bot-pairing-spec.md` §"Доработка 2". ⚠️ Verified by tests only — nothing has run end-to-end.
- **Trial**: `POST /trial` creates a Remnawave user on the fly (squad `Remnawave:TrialSquadUuid`, `Trial:DurationDays`, currently 2). Anti-abuse: `Device` stores a salted hash of the `attestationToken`; the token must be **16–512 chars** (an empty one hashed to the same identity for everybody and handed the first caller's trial to every later one), and the endpoint is capped at 5/hour per IP. A device whose trial is still running gets its session **reissued** (200); 409 only once the trial is spent. ⚠️ The token is a random per-install key — reinstall = new trial; real Play Integrity / SSAID binding is still TODO (see `docs/api-contract.md`).
- **Remnawave subscription proxy**: `/config` returns the panel's response with our Hysteria2 hosts appended — Remnawave renders them into no subscription format we consume, so `SubscriptionAugmenter` synthesizes the links itself (hosts in `Remnawave:HysteriaHosts`, on by default via `Remnawave:AugmentHysteria`). Otherwise it is passed through as-is (currently base64 `vless://` URIs); sing-box JSON format would require configuring templates in the Remnawave panel.

### Infrastructure / Configuration

- **Postgres**: `fatvpn` DB on port `5433` (host), `5432` (container). Credentials: `fatvpn`/`fatvpn_dev`.
- **Remnawave**: Base URL in `appsettings.json`; `ApiToken` via `dotnet user-secrets` (UserSecretsId: `3d5f08d5-dec7-4629-8e42-bc979ebe72cf`).
- **JWT**: HS256 (algorithm pinned, `ClockSkew` 30 s), `FatVpn.Bff` issuer, `FatVpn.App` audience. Dev secret in `appsettings.Development.json` — **untracked**; copy `appsettings.Development.example.json` on a fresh clone.

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

⛔ **Set `TRIAL_DEVICE_KEY_SALT` before the next deploy.** Startup now validates configuration
(`ValidateOnStart`) and **refuses to boot** outside Development without `Trial__DeviceKeySalt`,
`Jwt__Secret` (≥32 bytes), `Bot__Secret` (≥16 chars) and `Remnawave__ApiToken`. `docker-compose.yml`
passes the salt as `${TRIAL_DEVICE_KEY_SALT}`; without it the container crash-loops. Full list of
required and new optional settings: `docs/api-contract.md`.

`appsettings.Development.json` is no longer tracked in git (template: `appsettings.Development.example.json`)
— treat the secrets it used to hold as public, and note the app now refuses to run the Development
configuration on a non-loopback address.

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
- `docs/improvement-plan-index.md` — **full technical audit (2026-07-27)**: top-10 issues, cross-cutting fixes, work order, plus a **status block (2026-07-28)** saying what is closed on each front. Start here
- `docs/improvement-plan-bff.md` / `-app-android.md` / `-ios.md` — per-area findings (bugs, security, performance) with file:line and proposed fixes, each marked with its current status. BFF is closed by `820b1fe` bar HTTPS; Android and iOS are both closed in `master` but device-verified on neither. ⚠️ On iOS the Swift **now compiles** — Codemagic `ios-release` went green as build 136 (2026-07-28), which also proved the App Groups capability survives re-signing — but nothing beyond compilation is verified, so no iOS finding rates better than "fixed in code, builds, untested on a device". Each doc also records **where the audit itself was wrong** — those finding texts were corrected, not just annotated
- `docs/home-widgets-spec.md` — **home-screen widgets (2026-07-28)**, Android app widget + iOS WidgetKit extension: the shared snapshot both platforms render from, why *connecting* always goes through the app (live entitlement check) while *disconnecting* is native on Android and cannot be on iOS (NE entitlement), and the App Group capability the new iOS App ID (`com.fatvpn.fatvpnApp.FatVpnWidget`) needs before the next TestFlight build. Written, compiled on neither platform yet
- `docs/release-test-checklist.md` — acceptance run before deploying. Section **2a** holds the audit's acceptance criteria (T1–T25; numbers are not contiguous — navigate by the T-сборка / T-Android / T-iOS subheadings). The **T-iOS** block was rewritten 2026-07-28 with explicit "how to check" / "what counts as failure" per item, because the Phase 7 validation (2026-07-24) passed while five findings were live
- `VPN-App-Project.md` — master project document (Russian): requirements, 10-day plan, open questions
