# FatVPN BFF — контракт API (черновик)

> Источник: раздел 8 `VPN-App-Project.md`. Уточняется по ходу Дня 2 и Дня 6.

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
