# FatVPN BFF — контракт API

> Источник: раздел 8 `VPN-App-Project.md`.

## Статус: все эндпоинты реализованы

Все эндпоинты реализованы в `backend/src/FatVpn.Bff.Api/Controllers`.

Проверено end-to-end на тестовом сервере (87.121.221.229, тестовый бот `@testfatvpnnbot` — это не прод):
- Бот нажимает «Поменять ключ» → регистрирует 32-символьный токен через `POST /internal/tokens`
- `POST /auth/token` возвращает JWT
- `GET /config` проксирует сырую подписку Remnawave с правильным Content-Type
- `GET /servers` возвращает список из 10 стран / 36 нод

Pairing-эндпоинты (`/pair/*`, `/internal/pair/complete`, `/internal/account/subscription`) — **задеплоены на тестовый сервер и проверены** (2026-07-06): pairing-цикл curl-ом, проводка бот→BFF, полный e2e на реальном телефоне (см. `docs/app-bff-integration.md`). BFF там выставлен наружу по HTTP (`http://87.121.221.229:5030`).

Проверено end-to-end только локально (не на проде, 2026-07-05):
- `POST /trial` — MVP-версия, см. подробности и открытые вопросы ниже.

**Секреты не хранятся в git.** На новой машине (и обязательно на проде!) перед запуском выполнить:

```
cd backend/src/FatVpn.Bff.Api
dotnet user-secrets set "Remnawave:ApiToken" "<токен из панели>"
dotnet user-secrets set "Trial:DeviceKeySalt" "<случайная строка>"
```

`Jwt:Secret` и `Bot:Secret` для локальной разработки — в `appsettings.Development.json`.

⚠️ **`Trial:DeviceKeySalt` в `appsettings.json` пустой по умолчанию.** Без него хеш device-ключа считается с пустой солью — не критично для работы (уникальность всё равно сохраняется), но снижает приватность/защиту от подбора устройства по хешу. **Задать реальное случайное значение до деплоя `/trial` на прод** — на сервере это делается либо через `dotnet user-secrets` в контейнере, либо через переменную окружения `Trial__DeviceKeySalt` (по аналогии с `Bot__Secret`, см. `docs/bot-integration-spec.md`).

## Модель токенов (важно)

С релиза refresh-split (2026-07-08) сессия — это **пара токенов**:

- **`accessToken`** — короткоживущий JWT (**30 мин**, `Jwt:AccessTokenLifetime`).
  Срок жизни **развязан** со сроком подписки: JWT отвечает «кто ты», а право
  доступа проверяется **живьём** в каждом запросе. Claim — `fatvpn_account_id`
  (pairing) или `fatvpn_token_id` (legacy/trial).
- **`refreshToken`** — долгоживущий (**90 дней**, `Jwt:RefreshTokenLifetime`),
  **отзываемый**, **ротируемый** непрозрачный секрет. В БД хранится только его
  SHA-256-хеш; сырое значение отдаётся клиенту один раз. Приложение меняет его
  на свежий access через `/auth/refresh`.
- **Истечение подписки:** `accessToken` НЕ протухает вместе с подпиской (в отличие
  от старой схемы). Вместо этого `/config` и `/servers` при истёкшей подписке
  отдают **402 Payment Required**, а `/me` — `status: "expired"`. Так приложение
  отличает «нужно продлить» (402) от «токен невалиден» (401) и ведёт на экран
  продления, а не на онбординг.

## Публичные эндпоинты (мобильное приложение)

### `POST /auth/token`
Обмен короткого токена (полученного из Telegram-бота) на пару токенов.

- **Запрос:** `{ "shortToken": string }`
- **Ответ:** `{ "accessToken": string, "refreshToken": string, "expiresAt": datetime }`
- **Ошибки:** 404 — токен не найден/просрочен

### `POST /auth/refresh`
Обмен refresh-токена на свежий access (с ротацией refresh). Право подписки здесь
**не** проверяется — истёкшая подписка тоже должна уметь рефрешить, чтобы дойти до
экрана продления и подхватить будущее продление.

- **Запрос:** `{ "refreshToken": string }`
- **Ответ:** `{ "accessToken": string, "refreshToken": string, "expiresAt": datetime }`
- **Ошибки:** 401 — refresh неизвестен / отозван / истёк (приложение выходит на онбординг)

### `POST /auth/logout`
Best-effort отзыв refresh-токена при выходе. Всегда 204 (нельзя пробить, какие токены существуют).

- **Запрос:** `{ "refreshToken": string }`
- **Ответ:** 204 No Content

### `POST /pair/start`
Приложение начинает pairing (связывание по одноразовому коду). Показывает `pairCode`/QR и открывает бота ссылкой `t.me/<bot>?start=pair<pairCode>`.

- **Запрос:** тело не требуется
- **Ответ:** `{ "pairCode": string, "pollToken": string, "expiresAt": datetime }` (это pairing-`expiresAt` — срок жизни кода, не подписки)
- `pairCode` — 8 символов (base32 без похожих букв), уходит в Telegram deep link.
- `pollToken` — секрет устройства, с которым приложение опрашивает статус. Не передаётся в чат.
- Код живёт 15 минут.

### `GET /pair/status?pollToken=<...>`
Приложение опрашивает, пока бот не завершит pairing.

- **Ответ:** `{ "status": "pending" }` | `{ "status": "completed", "accessToken": string, "refreshToken": string, "expiresAt": datetime }` | `{ "status": "expired" }`
- **Ошибки:** 404 — `pollToken` неизвестен
- `accessToken` — JWT на **Account** (claim `fatvpn_account_id`), в отличие от deep-link-пути (claim `fatvpn_token_id`). `refreshToken` — как в `/auth/token`.

### `POST /trial`
Выдать триал новому устройству (без ввода кода).

- **Запрос:** `{ "attestationToken": string, "platform": "ios" | "android" }`
- **Ответ:** `{ "accessToken": string, "refreshToken": string, "expiresAt": datetime }`
- **Ошибки:** 409 — триал для этого устройства уже был выдан; 502 — не удалось создать подписку в Remnawave
- **Срок триала:** **2 дня** (`Trial:DurationDays` в `appsettings.json`; было 3, изменено на 2 по решению заказчика 2026-07-07).
- **Выдача подписки — на лету (2026-07-07):** `POST /trial` **создаёт нового пользователя в Remnawave** через `POST /api/users` (squad `Remnawave:TrialSquadUuid`, по умолчанию `Default-Squad`, `NO_RESET`, срок = now + `Trial:DurationDays`) и берёт его `shortUuid` как `remnawaveSubscriptionId`. Пул (`TrialSubscriptionSlots`) больше **не используется** — это масштабируется на любое число установок из стора без ручного пополнения. Старые эндпоинты `/internal/trial-pool` оставлены как legacy (не задействованы).
- **Анти-абуз (MVP, см. "Открытые вопросы"):**
  - `attestationToken` пока НЕ верифицируется через Play Integrity/App Attest — он просто солёно хешируется (`Trial:DeviceKeySalt`) и используется как ключ устройства в таблице `Devices` (409 при повторе).

### `POST /internal/trial-pool` (legacy, не используется)
Ранее наполнял пул триальных подписок. После перехода на выдачу на лету (2026-07-07)
не задействован; эндпоинт и таблица `TrialSubscriptionSlots` оставлены, чтобы не
делать миграцию. Можно удалить при чистке.

- **Авторизация:** секрет бота (`X-Bot-Secret`)
- **Запрос:** `{ "remnawaveSubscriptionIds": string[] }`
- **Ответ:** `{ "added": int }`

### `GET /internal/trial-pool` (legacy, не используется)
- **Авторизация:** секрет бота (`X-Bot-Secret`)
- **Ответ:** `{ "total": int, "available": int }`

### `GET /servers`
Список стран с вложенным списком реальных нод (адрес/порт для клиентского TCP-пинга).

- **Авторизация:** JWT Bearer (эндпоинт закрыт с pairing-релиза)
- **Ответ:** `[{ "country": string, "flag": string, "nodeCount": int, "nodes": [{ "id": string, "name": string, "address": string, "port": int, "usersOnline": int }] }]`
- **Ошибки:** 401 — токен невалиден/сессия неизвестна; **402 — подписка истекла**

### `GET /config`
Конфиг подписки для текущего пользователя (по JWT). Проксирует ответ Remnawave as-is.

- **Ответ:** сырой контент подписки Remnawave с оригинальным `Content-Type`
- **Примечание:** Remnawave на текущей инсталляции возвращает base64-кодированный список
  vless:// URI. Sing-box шаблон в панели не настроен — при необходимости JSON-формата
  нужно настроить шаблоны в Remnawave или добавить `?format=singbox` после конфигурации панели.
- **Ошибки:** 401 — токен невалиден/сессия неизвестна; **402 — подписка истекла**; 502 — Remnawave недоступен

### `GET /me`
Статус подписки, срок действия.

- **Ответ:** `{ "status": "trial" | "active" | "expired", "expiresAt": datetime }`

## Внутренние эндпоинты (только для тестового/прод Telegram-бота)

### `POST /internal/tokens`
Регистрация короткого токена ботом при нажатии «сменить ключ» (legacy deep-link-путь).

- **Авторизация:** секрет бота (заголовок, не JWT)
- **Запрос:** `{ "shortToken": string, "remnawaveSubscriptionId": string, "expiresAt": datetime }`
- **Ответ:** 201 Created

### `POST /internal/pair/complete`
Бот завершает pairing по коду: создаёт/обновляет Account и привязывает к нему код.

- **Авторизация:** секрет бота (`X-Bot-Secret`)
- **Запрос:** `{ "pairCode": string, "telegramUserId": int64, "subscriptionId": string, "expiresAt": datetime }`
- **Ответ:** 200 OK
- **Ошибки:** 404 — код неизвестен/истёк; 409 — код уже использован

### `POST /internal/account/subscription`
Бот обновляет текущую подписку аккаунта при любом изменении активного ключа (создание/смена/продление). Upsert по `telegramUserId`. Именно это не даёт продлению/смене ключа рвать сессию приложения.

- **Авторизация:** секрет бота (`X-Bot-Secret`)
- **Запрос:** `{ "telegramUserId": int64, "subscriptionId": string, "expiresAt": datetime }`
- **Ответ:** 200 OK

> Полное ТЗ по стороне бота — `docs/bot-pairing-spec.md`.

---

**Открытые вопросы:**
- Sing-box шаблоны в Remnawave — нужна настройка панели, чтобы `/config` отдавал JSON.
- Лимит устройств на ключ (у Sota — 1) — влияет на `/auth/token` и `/trial`.
- **⚠️ Абуз триала «удалил → скачал заново» (нужно реализовать перед стором).** Сейчас `attestationToken` — это случайный UUID в `flutter_secure_storage`. При удалении приложения хранилище стирается → при переустановке генерируется новый ключ → сервер видит «новое устройство» → **выдаёт ещё один триал**. Т.е. триал можно крутить бесконечно (удалил/поставил). Планы фикса:
  - **Стопгап (без гугл/эппл-аккаунтов): ANDROID_ID (SSAID)** как `attestationToken` вместо случайного UUID. Переживает переустановку (пока APK подписан тем же ключом), сбрасывается только factory reset → повтор даёт 409. Стабилен только на **release**-сборке (у debug ключ подписи может отличаться). Закрывает казуальный абуз, делается быстро.
  - **Правильно (для стора): Play Integrity API (Android) / App Attest (iOS)** — привязка к устройству+приложению, не обходится переустановкой и не подделывается. Требует Google Cloud service account и Apple-аккаунт. Это же закрывает и следующий пункт (верификацию `attestationToken`).
- Реальная верификация `attestationToken` (Play Integrity / App Attest) — не реализована, см. пункт выше и `POST /trial`.
- Выдача триала теперь **на лету** (создание Remnawave-юзера при `POST /trial`), пул `TrialSubscriptionSlots` больше не используется (legacy). Открытый вопрос по пулу снят.
