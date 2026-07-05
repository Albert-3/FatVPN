# ТЗ для разработчика бота: pairing приложения FatVPN

> Документ самодостаточен — его можно отдать стороннему разработчику бота,
> не знакомому с остальной архитектурой. Описывает **только** изменения в
> Telegram-боте (`/opt/FatVPN/bot/`, Python 3.11, aiogram 2.x).

## Зачем это

Раньше приложение FatVPN подключалось так: бот показывал в чате 32-символьный
токен, пользователь через deep link прокидывал его в приложение. Проблемы: токен
светится в чате, при смене/продлении ключа связка рвётся, нет входа для нового
пользователя.

Новая схема — **pairing** (связывание по одноразовому коду):

```
1. Пользователь открывает приложение → жмёт «Подключить через Telegram»
2. Приложение открывает бот со ссылкой  t.me/<bot>?start=pair<КОД>
3. Бот определяет пользователя, берёт его подписку и сообщает её BFF по коду
4. Приложение (само опрашивая BFF) подключается. Пользователь ничего не копирует.
5. При смене/продлении ключа бот сообщает новую подписку BFF → приложение
   продолжает работать без переподключения.
```

Ключевая идея: BFF теперь хранит **аккаунт** (ключ — Telegram `user_id`) и его
текущую подписку. Задача бота — **держать эту подписку в BFF актуальной** и
**завершать pairing** по коду.

Старый deep-link-путь (`register_short_token`) не удаляется — работает как
раньше, на переходный период.

---

## Что вызывает бот у BFF (контракт)

BFF доступен из контейнера бота по `http://fatvpn-bff:5030` (общая docker-сеть
`fatvpn_default`, уже настроена). Оба вызова защищены заголовком
`X-Bot-Secret: <BOT_SECRET>` — так же, как существующий `POST /internal/tokens`.

### 1. `POST /internal/pair/complete` — завершить pairing по коду

Вызывается, когда пользователь пришёл в бот по ссылке `?start=pair<КОД>`
и у него есть активная подписка.

```json
Запрос:
{
  "pairCode": "AB12CD",              // код из ссылки (то, что после "pair")
  "telegramUserId": 123456789,       // message.chat.id
  "subscriptionId": "a1b2c3d4",      // short_uuid активного ключа
  "expiresAt": "2026-08-04T12:00:00+00:00"   // ISO 8601 (UTC)
}
```
- **200** — код принят, приложение подключится.
- **404** — код неизвестен или истёк (показать пользователю «код устарел, откройте приложение заново»).
- **409** — код уже использован.

### 2. `POST /internal/account/subscription` — обновить текущую подписку аккаунта

Вызывается **при любом изменении активного ключа** пользователя: создание,
смена («Поменять ключ»), продление. Это то, что чинит «продление ломает вход».
Upsert по `telegramUserId`.

```json
Запрос:
{
  "telegramUserId": 123456789,
  "subscriptionId": "a1b2c3d4",      // актуальный short_uuid
  "expiresAt": "2026-08-04T12:00:00+00:00"
}
```
- **200** — сохранено.

> `expiresAt` бот везде хранит в миллисекундах (unix ms). Конвертация в ISO —
> как в существующем коде: `datetime.fromtimestamp(ms/1000, tz=timezone.utc).isoformat()`.

---

## Изменения в коде бота (4 точки + 1 вспомогательный модуль)

### Точка 0. `api/fatvpn_bff_api.py` — новые вызовы + вынос секрета

Сейчас `BOT_SECRET` **захардкожен** в этом файле — перенести в переменную
окружения (значение то же, из `docker inspect fatvpn-bff` → `Bot__Secret`).

```python
import os
import aiohttp
from datetime import datetime, timezone

BFF_URL = "http://fatvpn-bff:5030"
BOT_SECRET = os.environ["BOT_SECRET"]     # было: захардкожено в файле

def _iso(expires_at_ms: int) -> str:
    return datetime.fromtimestamp(expires_at_ms / 1000, tz=timezone.utc).isoformat()

async def _post(path: str, payload: dict):
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{BFF_URL}{path}",
            json=payload,
            headers={"X-Bot-Secret": BOT_SECRET},
            timeout=aiohttp.ClientTimeout(total=10),
        ) as resp:
            if resp.status not in (200, 201):
                text = await resp.text()
                raise Exception(f"BFF error {resp.status}: {text}")

async def complete_pairing(pair_code: str, telegram_user_id: int,
                           subscription_id: str, expires_at_ms: int):
    await _post("/internal/pair/complete", {
        "pairCode": pair_code,
        "telegramUserId": telegram_user_id,
        "subscriptionId": subscription_id,
        "expiresAt": _iso(expires_at_ms),
    })

async def upsert_subscription(telegram_user_id: int, subscription_id: str,
                              expires_at_ms: int):
    await _post("/internal/account/subscription", {
        "telegramUserId": telegram_user_id,
        "subscriptionId": subscription_id,
        "expiresAt": _iso(expires_at_ms),
    })
```

> `BOT_SECRET` нужно добавить в env контейнера бота
> (`/opt/FatVPN/docker-compose.yml`, секция `environment`), значение — то же,
> что `Bot__Secret` у контейнера BFF.

### Вспомогательный модуль: хранилище «ожидающих» pairing-кодов

Нужно для кейса «пользователь начал pairing, а ключа ещё нет»: бот запоминает
код и завершает pairing автоматически после того, как ключ создастся (покупка/
триал). Коды короткоживущие, поэтому хватит модуля с dict в памяти.

Новый файл `bot/services/pairing_state.py`:
```python
import time

# telegram_user_id -> (pair_code, expires_epoch)
_pending = {}
TTL_SECONDS = 15 * 60

def remember(user_id: int, code: str):
    _pending[user_id] = (code, time.time() + TTL_SECONDS)

def take(user_id: int):
    """Вернуть код и удалить его, если он не протух. Иначе None."""
    item = _pending.pop(user_id, None)
    if not item:
        return None
    code, exp = item
    return code if time.time() < exp else None
```

### Точка 1. `main_refactored.py` → `send_welcome` — перехват `pair<код>`

В самом начале обработчика `/start` (до текущей логики) добавить ветку.
Параметр после `/start ` уже доступен как `message.text[7:]` (сейчас там
реферальный код).

```python
@dp.message_handler(commands=['start'])
async def send_welcome(message: types.Message):
    arg = message.text[7:] if len(message.text) > 7 else ""
    if arg.startswith("pair"):
        await handle_pair(message.chat.id, arg[4:])   # arg[4:] = сам код
        return
    # ...дальше существующая логика без изменений...
```

### Точка 2. `handle_pair` — новая функция (там же, в `main_refactored.py`)

Берёт **последний по сроку** ключ пользователя и завершает pairing. Если ключа
нет — запоминает код и ведёт пользователя на получение подписки.

```python
async def handle_pair(user_id: int, code: str):
    from database.db import getem, get_full_email_with_uuid, gettime
    from api.fatvpn_bff_api import complete_pairing
    from services import pairing_state

    # выбрать ключ с самым поздним сроком
    best = None  # (short_uuid, expires_ms)
    for (username,) in getem(user_id):          # username == short_uuid
        full = get_full_email_with_uuid(user_id, username)   # short_uuid|user_uuid
        t = gettime(full)
        if t and t is not False:
            ems = int(t)
            if best is None or ems > best[1]:
                best = (username, ems)

    if best is None:
        # ключа нет — запомнить код и отправить оформлять подписку/триал
        pairing_state.remember(user_id, code)
        await bot.send_message(
            user_id,
            "🔑 Чтобы подключить приложение, сначала оформите подписку или "
            "получите пробный период — приложение подключится автоматически.",
        )
        # здесь показать обычное меню покупки/триала (как в send_welcome)
        return

    short_uuid, expires_ms = best
    try:
        await complete_pairing(code, user_id, short_uuid, expires_ms)
        await bot.send_message(user_id, "✅ Приложение FatVPN подключено. Вернитесь в приложение.")
    except Exception as e:
        await bot.send_message(user_id, "⚠️ Не удалось подключить приложение. Откройте его и попробуйте снова.")
        print(f"pair error: {e}")
```

### Точка 3. `database/db_remnawave.py` — синхронизация подписки в BFF

После каждого места, где у пользователя появляется/меняется активный ключ,
вызвать `upsert_subscription`, а при создании — ещё и завершить отложенный
pairing.

**а) `add_client_request_remnawave`** (создание ключа — покупка и триал идут
через неё). После `savecfg(...)` (примерно строка 98):
```python
    from api.fatvpn_bff_api import upsert_subscription
    from services import pairing_state
    await upsert_subscription(client_id, short_uuid, expiry_timestamp)
    pending = pairing_state.take(client_id)
    if pending:
        from api.fatvpn_bff_api import complete_pairing
        await complete_pairing(pending, client_id, short_uuid, expiry_timestamp)
```

**б) `refresh_remnawave_key`** (смена ключа — `short_uuid` пересоздаётся).
После `savecfg(user_id, ...)` (примерно строка 295):
```python
    from api.fatvpn_bff_api import upsert_subscription
    await upsert_subscription(user_id, short_uuid, expiry_timestamp)
```

> Функции этого файла асинхронные — `await` можно вызывать напрямую.
> Оберните вызовы в `try/except`, чтобы недоступность BFF не ломала выдачу
> ключа (ключ важнее синка; при сбое подписка досинкается при следующем действии).

### Точка 4. `handlers/key_handlers.py` — продление и смена

**а) `handle_change_key`** — тут уже вызывается `register_short_token(short_uuid, expires_at_ms)`
(примерно строка 232). Рядом добавить:
```python
    from api.fatvpn_bff_api import upsert_subscription
    await upsert_subscription(user_id, short_uuid, expires_at_ms)
```

**б) `handle_extend_subscription`** — после успешного `extend_remnawave_key(...)`
(здесь `short_uuid` НЕ меняется, меняется только срок). У обработчика есть
`user_id = call.message.chat.id` и `email` (полный `short_uuid|user_uuid`).
После успешного продления и `gettime`:
```python
    from api.fatvpn_bff_api import upsert_subscription
    short_uuid = email.split('|')[0]
    if time_result and time_result is not False:
        await upsert_subscription(user_id, short_uuid, int(time_result))
```

---

## Что НЕ трогаем

Платёжка, рефералка, выдача инструкций/платформ, `register_short_token` и весь
существующий deep-link-путь остаются как есть. Все изменения аддитивны — бот
продолжает работать по-старому даже если BFF-эндпоинты ещё не готовы (вызовы
обёрнуты в `try/except`).

## Чек-лист проверки (тестовый бот `@testfatvpnnbot`)

1. `t.me/testfatvpnnbot?start=pairTEST01` при наличии ключа → бот пишет
   «Приложение подключено», в BFF прилетел `pair/complete`.
2. Тот же сценарий без ключа → бот ведёт на покупку; после создания ключа
   pairing завершается автоматически.
3. «Поменять ключ» → в BFF прилетел `account/subscription` с новым `short_uuid`.
4. «Продлить» → в BFF прилетел `account/subscription` с тем же `short_uuid`,
   новым сроком.
5. Недоступность BFF не мешает выдаче/продлению ключа (проверить с
   выключенным BFF — ключ выдаётся, ошибка только в логах).

## Деплой

```bash
cd /opt/FatVPN
docker compose build --no-cache
docker compose up -d --force-recreate
```

`BOT_SECRET` предварительно добавить в `environment` сервиса бота в
`docker-compose.yml` (значение из `docker inspect fatvpn-bff` → `Bot__Secret`).
