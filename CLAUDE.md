# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FatVPN is a cross-platform VPN app (Flutter mobile + .NET 10 BFF + Telegram bot) fronting a **Remnawave** VPN panel. The Android app is feature-complete and device-tested: pairing onboarding, on-the-fly trial (2 days, `Trial:DurationDays`), real sing-box VPN tunnel, split tunneling, live server ranking, local expiry reminders (client-scheduled `flutter_local_notifications`, no FCM), EN/RU. Auth uses an access+refresh token split with a "subscription expired → renew" screen (e2e-verified on emulator 2026-07-08). **iOS is now feature-complete and device-tested too** (2026-07-24): sing-box tunnel via a `PacketTunnel` Network Extension, split tunneling by domain/IP (per-app is impossible on iOS without MDM), DNS-leak/background/network-switch validated on a real iPhone; built via Codemagic → TestFlight (build 18). ⚠️ That validation covered "the tunnel carries traffic", not "the tunnel is correct": it never tested IPv6 leaks, a network switch **under load**, whether disconnecting actually restores the internet, recovery from a killed extension, or what stays on disk after logout — which is how the 2026-07-27 audit found three criticals in code that had passed. The audit remediation (2026-07-28) touches every layer of the iOS tunnel — including the TUN stack (`gvisor` → `system`), MTU, on-demand/kill-switch and the extension lifecycle — and **it compiles but has never been run**: Codemagic `ios-release` went green as **build 136** (2026-07-28), which proves the Swift builds, the `analyze && test` gate passes on CI, and the App Groups entitlement survives re-signing into the exported `.ipa` — and proves nothing about behaviour, since a broken tunnel compiles exactly as well as a working one. Treat build 18 as the last iOS data point about *behaviour*, and build 136 as the first about *buildability*. See `docs/ios-vpn-tunnel-spec.md` for the iOS story (its Phase 7 section now records what the validation did not cover) and `docs/app-bff-integration.md` for the full status log. That remediation was then **read back line by line (2026-07-28)** and 30 defects were found *in the fixes themselves* — 16 corrected on the spot and the other 14 (V17–V30) the next day, 2026-07-29, all listed under "Вычитка ремедиации" in `docs/improvement-plan-ios.md`. None of the 14 has been run on a device: they are Dart under host tests and Swift that has only ever met a compiler. Two of those were CI defects that build 136 then exercised: the quality gate had no `set -e`, so a failing `flutter analyze` was printed and published anyway, and the App Group entitlement check read the archived bundle instead of the re-signed `.ipa` and passed green when it found nothing. The heaviest of them was V17: logout-by-401 and subscription-expiry (402) bypassed the persisted-state wipe, which on iOS with on-demand meant the OS could raise the tunnel on credentials the panel had already revoked — closed 2026-07-29 by `VpnController.stopAndForgetStandalone()` plus a fallback in `AuthController` covering every way a session dies, and waiting on T15 for its first real test. **Home-screen widgets landed 2026-07-28** (`docs/home-widgets-spec.md`): an Android app widget and an iOS WidgetKit extension rendering one shared snapshot — state, location, session clock — written by the app and, when the app is not running, by the tunnel itself (the plugin's state broadcast on Android, `PacketTunnelProvider` on iOS). The power button is a **separate** control — a tap anywhere else on the widget only opens the app — and it works in both directions: on Android it disconnects natively and **connects natively too** (2026-07-28), by running the app's own connect code in a background Flutter engine (`WidgetConnectService` → `widgetConnectMain` in `lib/main.dart` → `WidgetConnectRunner`), so raising the tunnel still does the live 402 entitlement check and fetches a fresh config instead of reusing the one on disk. It opens the app only where a screen is unavoidable: no session, a lapsed subscription, or the first-ever VPN consent dialog. On iOS the button cannot touch the tunnel (no NE entitlement in the widget's App ID), so from iOS 17 it is a real `Button(intent:)` that parks the action in the App Group and brings the app forward — the app collects it via `AuthController.pollWidgetAction()`, a path that does not depend on `fatvpn://` reaching Dart (which has never been verified on iOS). With no country chosen — every first press — both platforms connect to the fastest node overall; the choice now persists (`SelectedLocationStore`, cleared on sign-out), which the app itself used to forget on every restart. Android offers **two sizes in the picker** — the 4×2 card and a 2×2 square (`FatVpnWidgetSquareProvider`, an empty subclass: a provider's default size lives in its `appwidget-provider` XML and there is one per receiver) — drawn by three layouts the launcher picks between by the tile's actual size. The iOS widget is a **third bundle id** (`com.fatvpn.fatvpnApp.FatVpnWidget`) whose App ID needs the **App Groups** capability enabled in the Apple portal before the next TestFlight build — without it signing strips the entitlement and the widget can read nothing (the `codemagic.yaml` entitlement check now covers that appex, so the build fails instead). **Build 142 (2026-07-28) died on exactly that**: `Signing for "FatVpnWidget" requires a development team` — the widget had no provisioning profile, so `use-profiles` skipped the target silently and Xcode failed in the archive. Codemagic matches `ios_signing.bundle_identifier` as a substring (which is why `PacketTunnel` is signed for free) but only creates what is missing when the search matches *nothing*, and on this account the profiles are made by hand anyway — it creates only the certificate. ✅ The portal was fixed the same day and **verified by eye**: the App ID exists with App Groups bound to `group.com.fatvpn.fatvpnApp`, and the `FatVpnWidget App Store` profile is active with App Groups among its capabilities. Nothing is left there, and builds 143–145 proved the portal was never the problem: the profile sat there ACTIVE for half an hour while the fetch still brought only two. The fetch searches by bundle id, so `0a5890c` stopped searching — it now takes **every** ACTIVE App Store profile the team has (`app-store-connect profiles list --save`), and a pre-archive step checks all three bundle ids in seconds instead of failing ten minutes in. That fix works: `ios-release` has been green since, and **build 183 (2026-07-31) reached TestFlight with the widget in it**. There is no `triggering:`, so every build is started by hand. The build number is `max(commits on HEAD, what App Store Connect already holds + 1)` — the commit count alone repeats on a rebuild of the same commit, and App Store Connect answers 409 to a number it has already seen, which is how build 183 uploaded once and then failed the retry. **The iOS widget has now been seen on a device (2026-07-31): it renders real data, so the App Group works, and the power button did nothing at all** — the intent was a member of the widget target only, while `openAppWhenRun` performs it *in the app's process*; and even in the right process it fires *after* both places that poll for it. Both are fixed in `e8bbe22`, neither is verified. The Android widget has never been run. Remaining (non-iOS): trial reinstall anti-abuse (the Android stopgap hashes `ANDROID_ID`; real Play Integrity / App Attest waits on store accounts), cert pinning, and the prod migration — HTTPS and the domain are done (2026-07-30, see the Production Server section). Work merged into `master` (pairing onboarding fast-forward 2026-07-09; iOS via squash 2026-07-24).

## Commands

All commands run from the `backend/` directory unless noted.

```bash
# Start Postgres (required before running the API). Name the service: a bare
# `up -d` would also start the bff and caddy containers, which is what the
# server wants and a developer running `dotnet run` does not.
docker compose up -d postgres

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

Tests: `dotnet test tests/FatVpn.Bff.Tests/FatVpn.Bff.Tests.csproj` — 125 tests (116 + 9 that skip without Docker).

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
- **Session tokens (access + refresh split, see `docs/api-contract.md` "Модель токенов")**: A session is a short access JWT (**30 min**, `Jwt:AccessTokenLifetime`) plus a long, revocable, rotating refresh token (**90 days**, `Jwt:RefreshTokenLifetime`, stored hashed as `RefreshToken`). The JWT lifetime is **decoupled** from the subscription; entitlement is checked live per request, and `/config`/`/servers` return **402** when the subscription has lapsed (vs 401 for a bad token). The app refreshes silently, so an extension or key change never forces re-pairing. **Reuse detection**: presenting an already-revoked (rotated/logged-out) refresh token revokes the whole session family, forcing a re-pair (`AuthController.RevokeFamilyAsync`) — **except inside `Jwt:RefreshGraceWindow` (30 s)**, where a second presentation is treated as the app racing itself and is answered with another token of the same family. A "family" is the rotation chain of one sign-in (`RefreshTokens.FamilyId`, 2026-07-29), **not** the account: with one key on three phones, the phone that replays a spent token no longer signs the other two out. Rotation itself is one conditional `UPDATE`, so two parallel refreshes can no longer both succeed. The client should always keep the **last** refresh token it received.
- **JWT claim**: `fatvpn_account_id` (pairing sessions) or `fatvpn_token_id` (legacy deep-link / trial) identifies the session; the BFF resolves the current Remnawave subscription live on each request (`SubscriptionResolver`).
- **Pairing**: The app is the entry point — `POST /pair/start` → user opens the bot via `t.me/<bot>?start=pair<code>` → bot calls `/internal/pair/complete` → app polls `/pair/status` and connects. `Account` (keyed by Telegram user id) holds the current subscription, kept fresh by the bot. Pairing codes are **single-use**: `/pair/status` mints the session once, then flips the code to `Consumed` (`PairingStatus`) so a repeated poll can't hand out a second session; `/internal/pair/complete` only accepts a `Pending` code (409 otherwise).
- **Which key the app runs on** (2026-07-28): a user can hold several keys in the bot while the account carries exactly one active subscription, so every write says whether the user *chose* this key. Pairing and pasting a "Код для FatVPN App" are both explicit choices and both now produce an **account** session: `/internal/tokens` takes `telegramUserId` and stamps `Tokens.AccountId`, and `/auth/token` for an owned key writes that key into the account and issues `fatvpn_account_id`. Everything else (`/internal/account/subscription` without `makeActive`) only refreshes the key that is *already* active — extending key #2 used to drag a subscriber off key #1. Before this, a pasted key resolved through the `Tokens` row alone, which the bot only rewrites on reissue: extending a subscription left the app on "expired" and answered 404 to the user's own key. Keys with no owner (older bot builds, trial keys) behave exactly as before. The bot half is written too — pairing now asks *which* key when the user holds several, instead of silently taking the longest-lived one. Reading the live bot turned up something the spec never mentioned: merely *opening* a key's screen called `upsert_subscription`, so browsing your keys moved the app onto whichever you looked at last; that is what `replacesSubscriptionId` and the "an already-lapsed key is not worth protecting" rule exist for. **Both halves are deployed (2026-07-28)** and verified end-to-end against the live stack — pasting a code, switching keys, and a session surviving a key change all check out. Bot sources live only in `/opt/FatVPN/bot`, originals kept as `<file>.pre-keychoice`. Full record: `docs/app-bff-integration.md`; the Telegram-side checklist in `docs/bot-pairing-spec.md` §"Доработка 2" has **not** been walked by hand. The Flutter changes (404 message on a bad key, pairing surviving process death) are still uncommitted and need an APK build.
- **One key, up to 3 devices** (2026-07-29, employer request): pasting a key used to bind it to the first phone (`Tokens.BoundDeviceKeyHash`) and answer **409** to every other. It now takes one of `Auth:MaxDevicesPerKey` (default **3**) numbered slots in the new `TokenDevices` table; a device already holding a slot re-enters as often as it likes, and the fourth gets 409 with `{"error":"device_limit"}` so the app can say "already on 3 devices" instead of the misleading "linked to another phone". **The cap is enforced by the unique index `(TokenId, SlotIndex)`, not by a count** — counting rows and then inserting lets every racer read "room for one more", which is exactly what the Testcontainers tests caught when the first attempt used a counter column (8 racing devices got 4 in). Reissuing the key in the bot frees all slots. Pairing stays uncapped. Legacy builds that send no `attestationToken` still get a session without taking a slot. `BoundDeviceKeyHash` is kept-and-ignored so a rollback to the previous image still works; the migration backfills each bound key into slot 0. Written, tested (125 BFF + 242 app tests, migration verified against a live Postgres with a pre-existing binding) — **not deployed and not run on a device**.
- **Trial**: `POST /trial` creates a Remnawave user on the fly (squad `Remnawave:TrialSquadUuid`, `Trial:DurationDays`, currently 2). Anti-abuse: `Device` stores a salted hash of the `attestationToken`; the token must be **16–512 chars** (an empty one hashed to the same identity for everybody and handed the first caller's trial to every later one), and the endpoint is capped at 5/hour per IP. A device whose trial is still running gets its session **reissued** (200); 409 only once the trial is spent. ⚠️ The token is a random per-install key — reinstall = new trial; real Play Integrity / SSAID binding is still TODO (see `docs/api-contract.md`).
- **Remnawave subscription proxy**: `/config` returns the panel's response with our Hysteria2 hosts appended — Remnawave renders them into no subscription format we consume, so `SubscriptionAugmenter` synthesizes the links itself (hosts in `Remnawave:HysteriaHosts`, on by default via `Remnawave:AugmentHysteria`). Otherwise it is passed through as-is (currently base64 `vless://` URIs); sing-box JSON format would require configuring templates in the Remnawave panel.

### Infrastructure / Configuration

- **Postgres**: `fatvpn` DB on port `5433` (host), `5432` (container). Credentials: `fatvpn`/`fatvpn_dev`.
- **Remnawave**: Base URL in `appsettings.json`; `ApiToken` via `dotnet user-secrets` (UserSecretsId: `3d5f08d5-dec7-4629-8e42-bc979ebe72cf`).
- **JWT**: HS256 (algorithm pinned, `ClockSkew` 30 s), `FatVpn.Bff` issuer, `FatVpn.App` audience. Dev secret in `appsettings.Development.json` — **untracked**; copy `appsettings.Development.example.json` on a fresh clone.

### Production Server (87.121.221.229)

| Component | Path | Container |
|---|---|---|
| BFF | `/opt/fatvpn-bff/backend/` | `fatvpn-bff` (**public** `0.0.0.0:5030`, HTTP — see below) |
| Caddy | same compose | `fatvpn-caddy` (`80`/`443`, TLS for `api.fatklyuchi.space`) |
| Bot (Python) | `/opt/FatVPN/` | `fatvpn-bot` |
| Postgres | — | `fatvpn-postgres` (`127.0.0.1:5433`, localhost-only) |

> **HTTPS is live (2026-07-30): `https://api.fatklyuchi.space`.** Caddy runs beside the BFF in the same compose and holds a Let's Encrypt certificate; `http://` redirects to it. The domain is the customer's, in **their** Cloudflare account, delegated to Cloudflare nameservers — but every record is **`DNS only` (grey cloud), and must stay that way**: the free proxy passes only HTTP/HTTPS on its own port list and no UDP at all, so an orange cloud kills VLESS on a non-standard port and Hysteria2 (QUIC) outright. That is what took the nodes down the one time it was tried. `sub.fatklyuchi.space` is separately fronted by **Yandex Cloud CDN**, not Cloudflare.
>
> Plain `http://87.121.221.229:5030` is **deliberately still open**: builds already on people's phones point at it. Retire it only once every shipped build uses the domain — a new APK is not enough, the old ones have to be gone.
>
> `ufw` allows `22`/`80`/`443`/`5030`/`4444`. Postgres is bound to localhost. The checkout is on `master`; deployment config (`docker-compose.yml`, `Caddyfile`) is tracked, and only `.env` is local — so `git pull` on the server is clean.

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
- `docs/improvement-plan-bff.md` / `-app-android.md` / `-ios.md` — per-area findings (bugs, security, performance) with file:line and proposed fixes, each marked with its current status. BFF is closed by `820b1fe` bar HTTPS — but note that remediation sat undeployed for a day and, when it finally reached the server (2026-07-28), **every body-taking endpoint answered 500**: its `[property: StringLength(...)]` on request records is metadata MVC's binder refuses (fixed in `26dfae4`/`43e1a8d`, now guarded by a reflection test). "Compiles and passes 113 tests" was not the same as "runs"; Android and iOS are both closed in `master` but device-verified on neither. ⚠️ On iOS the Swift **now compiles** — Codemagic `ios-release` went green as build 136 (2026-07-28), which also proved the App Groups capability survives re-signing — but nothing beyond compilation is verified, so no iOS finding rates better than "fixed in code, builds, untested on a device". Each doc also records **where the audit itself was wrong** — those finding texts were corrected, not just annotated
- `docs/home-widgets-spec.md` — **home-screen widgets (2026-07-28)**, Android app widget + iOS WidgetKit extension: the shared snapshot both platforms render from, why *connecting* always goes through the app (live entitlement check) while *disconnecting* is native on Android and cannot be on iOS (NE entitlement), and the App Group capability the new iOS App ID (`com.fatvpn.fatvpnApp.FatVpnWidget`) needs before the next TestFlight build. Written, compiled on neither platform yet
- `docs/store-compliance.md` — **what App Store and Google Play require (2026-07-31)**: one canonical table of what the app does with data, and every store-side form that has to repeat it — Apple's 5.4 and App Privacy, Play's VPN declaration, Data safety and prominent disclosure — each marked done or not. Its companion files are `backend/legal/privacy.{html,ru.html}` (the hosted policy, served by Caddy at `/privacy` and `/privacy/ru`) and the three `PrivacyInfo.xcprivacy`. Read it before touching any of the three: the rule it exists for is that policy, store form and code must give the same answer, and a divergence is its own rejection
- `docs/release-test-checklist.md` — acceptance run before deploying. Section **2a** holds the audit's acceptance criteria (T1–T25; numbers are not contiguous — navigate by the T-сборка / T-Android / T-iOS subheadings). The **T-iOS** block was rewritten 2026-07-28 with explicit "how to check" / "what counts as failure" per item, because the Phase 7 validation (2026-07-24) passed while five findings were live
- `VPN-App-Project.md` — master project document (Russian): requirements, 10-day plan, open questions
