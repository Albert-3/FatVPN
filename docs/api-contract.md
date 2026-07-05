# FatVPN BFF — контракт API

> Источник: раздел 8 `VPN-App-Project.md`.

## Статус: все эндпоинты реализованы

Все эндпоинты реализованы в `backend/src/FatVpn.Bff.Api/Controllers`.

Проверено end-to-end на боевом сервере (87.121.221.229):
- Бот нажимает «Поменять ключ» → регистрирует 32-символьный токен через `POST /internal/tokens`
- `POST /auth/token` возвращает JWT
- `GET /config` проксирует сырую подписку Remnawave с правильным Content-Type
- `GET /servers` возвращает список из 10 стран / 36 нод

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
- **Ошибки:** 409 — триал для этого устройства уже был выдан; 503 — пул триальных подписок пуст
- **Срок триала:** 3 дня, подтверждено заказчиком (2026-07-05) — `Trial:DurationDays` в конфиге, уже стоит `3` по умолчанию.
- **Реализация (MVP, см. "Открытые вопросы"):**
  - `attestationToken` пока НЕ верифицируется через Play Integrity/App Attest — он просто солёно хешируется (`Trial:DeviceKeySalt`) и используется как ключ устройства в таблице `Devices`. Полноценная верификация — отдельная задача (нужны Google Cloud service account и Apple App Attest ключи).
  - Remnawave-подписка для триала берётся из заранее наполненного пула (`TrialSubscriptionSlots`), а не создаётся через Remnawave Admin API на лету. Пул наполняется через `POST /internal/trial-pool`.

### `POST /internal/trial-pool`
Добавить Remnawave-подписки в пул для выдачи триалов (внутренний, для бота/админа).

- **Авторизация:** секрет бота (`X-Bot-Secret`)
- **Запрос:** `{ "remnawaveSubscriptionIds": string[] }`
- **Ответ:** `{ "added": int }` — сколько новых записей добавлено (дубликаты пропускаются)

### `GET /internal/trial-pool`
Проверить остаток пула триальных подписок.

- **Авторизация:** секрет бота (`X-Bot-Secret`)
- **Ответ:** `{ "total": int, "available": int }`

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
- Реальная верификация `attestationToken` (Play Integrity / App Attest) — не реализована, см. `POST /trial` выше.
- Пул `TrialSubscriptionSlots` нужно наполнять вручную через `POST /internal/trial-pool` — ещё не решено, кто и как создаёт эти подписки в самой Remnawave-панели (бот? скрипт? вручную?) и как пул пополняется, когда заканчивается.
