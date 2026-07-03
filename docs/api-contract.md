# FatVPN BFF — контракт API (черновик)

> Источник: раздел 8 `VPN-App-Project.md`. Уточняется по ходу Дня 2 и Дня 6.

## Статус: День 2 реализован и проверен на реальной панели

Все эндпоинты ниже реализованы в `backend/src/FatVpn.Bff.Api/Controllers`.
Проверено вживую: `POST /internal/tokens` → `POST /auth/token` → `GET /me` →
`GET /config`/`GET /servers` (последние два — на реальном API-токене Remnawave,
`/servers` вернул настоящий список из 10 стран / 36 нод).

**Секреты не хранятся в git.** На новой машине перед запуском выполнить:

```
cd backend/src/FatVpn.Bff.Api
dotnet user-secrets init
dotnet user-secrets set "Remnawave:ApiToken" "<токен из панели, раздел Настройки Remnawave → API токены>"
```

`Jwt:Secret` и `Bot:Secret` для локальной разработки уже лежат в
`appsettings.Development.json` (dev-заглушки, не для прод).

## Публичные эндпоинты (мобильное приложение)

### `POST /auth/token`
Обмен короткого токена (полученного из Telegram-бота) на JWT.

- **Запрос:** `{ "shortToken": string }`
- **Ответ:** `{ "accessToken": string, "expiresAt": datetime }`
- **Ошибки:** 404 — токен не найден/просрочен

### `POST /trial`
Выдать триал новому устройству (без ввода кода).

- **Запрос:** `{ "attestationToken": string, "platform": "ios" | "android" }`
- **Ответ:** `{ "accessToken": string, "expiresAt": datetime }`
- **Ошибки:** 409 — триал для этого устройства уже был выдан
- **Зависимость:** требует подтверждённого от заказчика срока триала (2 или 3 дня)

### `GET /servers`
Список стран/нод + адреса для пинга на клиенте.

- **Ответ:** `[{ "country": string, "flag": string, "nodeCount": int, "pingHost": string }]`

### `GET /config`
Конфиг sing-box для текущего пользователя (по JWT).

- **Ответ:** JSON-конфиг sing-box (протокол зависит от решения по спайку xHTTP, День 1)

### `GET /me`
Статус подписки, срок действия.

- **Ответ:** `{ "status": "trial" | "active" | "expired", "expiresAt": datetime }`

## Внутренние эндпоинты (только для тестового/боевого Telegram-бота)

### `POST /internal/tokens`
Регистрация короткого токена ботом при нажатии «сменить ключ».

- **Авторизация:** секрет бота (заголовок, не JWT)
- **Запрос:** `{ "shortToken": string, "remnawaveSubscriptionId": string, "expiresAt": datetime }`
- **Ответ:** 201 Created

---

**Открытые вопросы (см. раздел 11/14 основного документа):**
- Точный формат подписки Remnawave — уточняется в День 1 через admin API.
- Лимит устройств на ключ (у Sota — 1) — влияет на `/auth/token` и `/trial`.
