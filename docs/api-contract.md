# FatVPN BFF — контракт API

> Источник: раздел 8 `VPN-App-Project.md`.

## Статус: Дни 2–3 реализованы и проверены end-to-end

Все эндпоинты реализованы в `backend/src/FatVpn.Bff.Api/Controllers`.

Проверено end-to-end на боевом сервере (87.121.221.229):
- Бот нажимает «Поменять ключ» → регистрирует 32-символьный токен через `POST /internal/tokens`
- `POST /auth/token` возвращает JWT
- `GET /config` проксирует сырую подписку Remnawave с правильным Content-Type
- `GET /servers` возвращает список из 10 стран / 36 нод

**Секреты не хранятся в git.** На новой машине перед запуском выполнить:

```
cd backend/src/FatVpn.Bff.Api
dotnet user-secrets set "Remnawave:ApiToken" "<токен из панели>"
```

`Jwt:Secret` и `Bot:Secret` для локальной разработки — в `appsettings.Development.json`.

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
Список стран с вложенным списком реальных нод (адрес/порт для клиентского TCP-пинга).

- **Ответ:** `[{ "country": string, "flag": string, "nodeCount": int, "nodes": [{ "id": string, "name": string, "address": string, "port": int, "usersOnline": int }] }]`

### `GET /config`
Конфиг подписки для текущего пользователя (по JWT). Проксирует ответ Remnawave as-is.

- **Ответ:** сырой контент подписки Remnawave с оригинальным `Content-Type`
- **Примечание:** Remnawave на текущей инсталляции возвращает base64-кодированный список
  vless:// URI. Sing-box шаблон в панели не настроен — при необходимости JSON-формата
  нужно настроить шаблоны в Remnawave или добавить `?format=singbox` после конфигурации панели.
- **Ошибки:** 401 — JWT истёк, 502 — Remnawave недоступен

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

**Открытые вопросы:**
- Sing-box шаблоны в Remnawave — нужна настройка панели, чтобы `/config` отдавал JSON.
- Лимит устройств на ключ (у Sota — 1) — влияет на `/auth/token` и `/trial`.
- `POST /trial` — эндпоинт не реализован (День 4+ по плану).
