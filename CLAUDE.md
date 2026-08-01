# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FatVPN is a cross-platform VPN app (Flutter mobile + .NET 10 BFF + Telegram bot) fronting a **Remnawave** VPN panel. The Android app is feature-complete and device-tested: pairing onboarding, on-the-fly trial (2 days, `Trial:DurationDays`), real sing-box VPN tunnel, split tunneling, live server ranking, local expiry reminders (client-scheduled `flutter_local_notifications`, no FCM), EN/RU. Auth uses an access+refresh token split with a "subscription expired → renew" screen (e2e-verified on emulator 2026-07-08). **iOS is now feature-complete and device-tested too** (2026-07-24): sing-box tunnel via a `PacketTunnel` Network Extension, split tunneling by domain/IP (per-app is impossible on iOS without MDM), DNS-leak/background/network-switch validated on a real iPhone; built via Codemagic → TestFlight (build 18). ⚠️ That validation covered "the tunnel carries traffic", not "the tunnel is correct": it never tested IPv6 leaks, a network switch **under load**, whether disconnecting actually restores the internet, recovery from a killed extension, or what stays on disk after logout — which is how the 2026-07-27 audit found three criticals in code that had passed. The audit remediation (2026-07-28) touches every layer of the iOS tunnel — including the TUN stack (`gvisor` → `system`), MTU, on-demand/kill-switch and the extension lifecycle — and **it compiles but has never been run**: Codemagic `ios-release` went green as **build 136** (2026-07-28), which proves the Swift builds, the `analyze && test` gate passes on CI, and the App Groups entitlement survives re-signing into the exported `.ipa` — and proves nothing about behaviour, since a broken tunnel compiles exactly as well as a working one. Treat build 18 as the last iOS data point about *behaviour*, and build 136 as the first about *buildability*. See `docs/ios-vpn-tunnel-spec.md` for the iOS story (its Phase 7 section now records what the validation did not cover) and `docs/app-bff-integration.md` for the full status log. That remediation was then **read back line by line (2026-07-28)** and 30 defects were found *in the fixes themselves* — 16 corrected on the spot and the other 14 (V17–V30) the next day, 2026-07-29, all listed under "Вычитка ремедиации" in `docs/improvement-plan-ios.md`. None of the 14 has been run on a device: they are Dart under host tests and Swift that has only ever met a compiler. Two of those were CI defects that build 136 then exercised: the quality gate had no `set -e`, so a failing `flutter analyze` was printed and published anyway, and the App Group entitlement check read the archived bundle instead of the re-signed `.ipa` and passed green when it found nothing. The heaviest of them was V17: logout-by-401 and subscription-expiry (402) bypassed the persisted-state wipe, which on iOS with on-demand meant the OS could raise the tunnel on credentials the panel had already revoked — closed 2026-07-29 by `VpnController.stopAndForgetStandalone()` plus a fallback in `AuthController` covering every way a session dies, and waiting on T15 for its first real test. **Home-screen widget: Android and iOS** (`docs/home-widgets-spec.md`). The Android app widget renders a snapshot — state, location, session clock — written by the app and, when the app is not running, by the tunnel itself (the plugin's state broadcast). The power button is a **separate** control — a tap anywhere else on the widget only opens the app — and it works in both directions: it disconnects natively and **connects natively too**, by running the app's own connect code in a background Flutter engine (`WidgetConnectService` → `widgetConnectMain` in `lib/main.dart` → `WidgetConnectRunner`), so raising the tunnel still does the live 402 entitlement check and fetches a fresh config instead of reusing the one on disk. It opens the app only where a screen is unavoidable: no session, a lapsed subscription, or the first-ever VPN consent dialog. With no country chosen — every first press — it connects to the fastest node overall; the choice persists (`SelectedLocationStore`, cleared on sign-out). Android offers **two sizes in the picker** — the 4×2 card and a 2×2 square (`FatVpnWidgetSquareProvider`, an empty subclass: a provider's default size lives in its `appwidget-provider` XML and there is one per receiver) — drawn by three layouts the launcher picks between by the tile's actual size. The press has an answer of its own, because a connect takes seconds and until it lands the tile would redraw exactly what it drew before — indistinguishable from a dead button: the direction of the tap is written down (`stopRequestedAt`/`connectRequestedAt`) and drawn over the real state until the tunnel speaks for itself, the disc got a ripple, and the tap buzzes via `WidgetHaptics` using `USAGE_HARDWARE_FEEDBACK` — the tap lands in a broadcast receiver, i.e. always a background process, where the platform silently drops any vibration whose usage is not on a short allow-list, so the semantically neater `USAGE_TOUCH` would ship a button that never buzzes. **The Android widget has never been run past the "disconnected" state on a device.** **The iOS WidgetKit extension was removed on 2026-08-01 and written again from scratch the same day**, with the one change the removal's own research implied: **the press is served by two different App Intents, and the widget picks between them by the device's iOS version** (`#available(iOSApplicationExtension 18.0, *)` in the view, so it is the OS drawing the tile that decides, never the SDK). On **iOS 18+** `FatVpnTogglePowerIntent` (`AudioPlaybackIntent`, `openAppWhenRun: false`) is performed in the app's process in the background and nothing appears on screen. On **iOS 17.x** `FatVpnOpenAppAndTogglePowerIntent` (`openAppWhenRun: true`) opens the app and parks the press in the App Group, and the app carries it out on the launch or resume that press caused (`AuthController.pollWidgetAction` → `HomeScreen`), through its own connect code. That split is the whole design: the earlier version spent three build cycles trying markers because it assumed a background path existed on 17, and §9 of the spec establishes it does not — Apple documents no way on iOS 17 to launch a terminated app in the background for a widget intent (confirmed only for iOS 18), and a force-quit app is barred from background launch until opened by hand, which is the main scenario for a VPN widget. `openAppWhenRun: true` is meanwhile the *only* behaviour that iPhone ever reproduced reliably, so on 17 it is now the intended path rather than a symptom. Vibration has exactly one owner per path — native `AudioServicesPlaySystemSound` in the background on 18, and Dart `HapticFeedback` in the app on 17, fired when it collects the parked press (a widget extension has no vibromotor at all, and the app process has no usable one until it is on screen); adding a second buzzer to either path is the easy way to break this. The other fix from that research is in: the tile carries **no** `.widgetURL` where the button is real (iOS 17 is reported to let it swallow `Button(intent:)` taps — thread 731758 — which explains every "opens the app, connects nothing" report). Written from scratch, not restored: `ios/FatVpnWidget/` (view, two intents, haptics, strings), `ios/Shared/FatVpnWidgetStore.swift` (App Group snapshot + press overlay + parked action + native press trail, compiled into all three targets), `ios/Runner/FatVpnWidgetToggle.swift` (the iOS-18 background toggle: native stop, connect through the app's Flutter engine), the `fatvpn/widget` and `fatvpn/widget_connect_host` channels in `AppDelegate.swift`, `ios/tool/add_widget_target.rb`, and the widget steps in `codemagic.yaml` — so iOS signing covers three bundle ids again, and CI now verifies **both** intent types are present in **both** bundles' `Metadata.appintents` (a build that dropped one would work on half the devices and the failing half reports nothing). Widget deployment target is 16.0 (below that there is no `AppIntents` framework); Runner stays on 13.0 with `-weak_framework AppIntents`, without which the app would not launch at all on iOS 13–15. ⚠️ **None of it has been run**: `flutter analyze` is clean and 255 Dart tests pass, and the Swift has never met a compiler — there is no Mac here, only Codemagic. `docs/home-widgets-spec.md` §10 has the acceptance run, and its first step is "remove the widget from the home screen and add it back", because WidgetKit archives the view and no earlier attempt started there. Two collateral fixes from that investigation **stay**, because they were never widget-specific: `FlutterDeepLinkingEnabled` (every `fatvpn://` open used to crash Flutter's own deep-link navigator with a caught null-check, because it competed with `app_links`, which was then proven to deliver nothing at all on this scene-based iOS template — the engine's own channel is the one path a device has carried end-to-end into Dart), and the support bundle carrying tails of the previous log files. **The first bug reported from a real user's iPhone (build 186, 2026-07-31) was the app throwing away a session it had just been given**: the renew screen refreshes the expired trial session while `/pair/status` is polled, and `_doRefresh` applied that response unconditionally, so a rotation of the dead session landed on top of the paid one pairing had just delivered — twice in a row, which the user read as "the bot says connected but the app shows nothing". Fixed in `fa9bc8f`, and the mirror (a late `/pair/status` clobbering a pasted key) in `4d3530b`; shipped as TestFlight **188/189** and **confirmed working by the user on 2026-08-01** — the first behavioural data point on iOS since build 18, every release in between having proved only that it compiles. What that confirms is the reported flow (pick a key in the bot after the trial lapses, come back to the app); the mirror path — start pairing, abandon it, paste the key instead — was not separately exercised. Two lessons worth keeping: the user's account of which button they pressed was wrong and the prod tables (`PairingCodes.Status`, abandoned `RefreshTokens` chains) were what actually diagnosed it; and any `await` whose result is written to shared state needs a recency check, because every session-replacing path (pairing, pasted key, trial, sign-out) races every other. Remaining (non-iOS): trial reinstall anti-abuse (the Android stopgap hashes `ANDROID_ID`; real Play Integrity / App Attest waits on store accounts), cert pinning, and the prod migration — HTTPS and the domain are done (2026-07-30, see the Production Server section). Work merged into `master` (pairing onboarding fast-forward 2026-07-09; iOS via squash 2026-07-24).

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
- `docs/home-widgets-spec.md` — **home-screen widget (Android and iOS)**: the snapshot it renders, why *connecting* goes through the app's own code (live entitlement check) while *disconnecting* is native. §9 is the record of why the iOS widget was removed on 2026-08-01 — what Apple actually documents about which process a widget App Intent runs in, and why no marker could have launched a terminated app on iOS 17. **§10 is the current iOS design** (rewritten from scratch the same day): the two intents, which iOS version gets which, who owns the vibration on each path, and the acceptance run. Section 4 and parts of 5–8 describe the previous scheme and are kept as history
- `docs/store-compliance.md` — **what App Store and Google Play require (2026-07-31)**: one canonical table of what the app does with data, and every store-side form that has to repeat it — Apple's 5.4 and App Privacy, Play's VPN declaration, Data safety and prominent disclosure — each marked done or not. Its companion files are `backend/legal/privacy.{html,ru.html}` (the hosted policy, served by Caddy at `/privacy` and `/privacy/ru`) and the three `PrivacyInfo.xcprivacy` (Runner, PacketTunnel and FatVpnWidget — the widget's came back with the widget on 2026-08-01). Read it before touching any of them: the rule it exists for is that policy, store form and code must give the same answer, and a divergence is its own rejection
- `docs/release-test-checklist.md` — acceptance run before deploying. Section **2a** holds the audit's acceptance criteria (T1–T25; numbers are not contiguous — navigate by the T-сборка / T-Android / T-iOS subheadings). The **T-iOS** block was rewritten 2026-07-28 with explicit "how to check" / "what counts as failure" per item, because the Phase 7 validation (2026-07-24) passed while five findings were live
- `VPN-App-Project.md` — master project document (Russian): requirements, 10-day plan, open questions
