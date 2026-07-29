# ТЗ для разработчика бота: pairing приложения FatVPN

> Документ самодостаточен — его можно отдать стороннему разработчику бота,
> не знакомому с остальной архитектурой. Описывает **только** изменения в
> Telegram-боте (`/opt/FatVPN/bot/`, Python 3.11, aiogram 2.x).

> ✅ **Статус: реализовано и задеплоено на тестовый сервер (2026-07-06).** Все
> изменения ниже применены к `@testfatvpnnbot`; проводка бот→BFF проверена (реальный
> `upsert_subscription` из контейнера бота → BFF → 200). Осталось прогнать полный
> pairing через Telegram (нажатие `/start pair<code>` живым пользователем). Этот
> документ — референс/чеклист для переноса на **прод-бота**.

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

---

# Доработка 2: ключ выбирает пользователь (2026-07-28)

> Статус: **написано целиком — и BFF, и бот** (2026-07-28). Код бота лежит не в
> этом репозитории: он правится прямо в `/opt/FatVPN/bot` на сервере. Ниже —
> описание того, что сделано, и чек-лист приёмки. **Ни на чём живом не
> проверено.**
>
> Разделы ниже описывают итоговое поведение; в паре мест оно отличается от
> первого наброска этого ТЗ (покупка второго ключа больше не переключает
> приложение, а замена ключа выражается через `replacesSubscriptionId`, а не
> через безусловный `makeActive`).

## Зачем

У пользователя может быть **несколько ключей**, а у аккаунта в BFF активная
подписка ровно одна. Сейчас выбор происходит молча и в двух местах по-разному:

- при pairing бот сам берёт ключ **с самым поздним сроком** (`handle_pair`, Точка 2
  выше) — пользователя не спрашивают;
- при продлении бот шлёт `upsert_subscription` **для любого** ключа, и продление
  ключа №2 переводило приложение с ключа №1 на №2 у пользователя за спиной.

Решение: выбор ключа становится явным действием. Всё, что не является явным
выбором, больше не переключает приложение.

## Что уже сделано на стороне BFF

| Что | Где |
|---|---|
| `POST /internal/tokens` принимает `telegramUserId` — код перестаёт быть отдельной личностью, продление доезжает до сессии, открытой вставкой кода | `InternalTokensController` |
| `POST /internal/account/subscription` принимает `makeActive` — без него вызов про неактивный ключ игнорируется | `InternalAccountController` |
| `POST /auth/token` (вставка кода в приложении) делает этот ключ активным и выдаёт аккаунт-сессию | `AuthController` |

Полное описание полей — `docs/api-contract.md`, разделы `/internal/tokens`,
`/internal/account/subscription`, `/auth/token`.

## Точка 1. `pairing_state.py` — хранить варианты выбора

К существующему модулю добавить хранилище кандидатов: держим список ключей
на сервере и передаём в `callback_data` только индекс. Так `callback_data`
остаётся коротким (лимит Telegram — 64 байта) и пользователь не может
подсунуть чужой `short_uuid`, подделав callback.

```python
# telegram_user_id -> (pair_code, [(short_uuid, expires_ms), ...], expires_epoch)
_choices = {}

def remember_choices(user_id: int, code: str, keys: list):
    _choices[user_id] = (code, keys, time.time() + TTL_SECONDS)

def take_choice(user_id: int, index: int):
    """(pair_code, short_uuid, expires_ms) или None, если протухло/индекс кривой."""
    item = _choices.pop(user_id, None)
    if not item:
        return None
    code, keys, exp = item
    if time.time() >= exp or index < 0 or index >= len(keys):
        return None
    return (code, keys[index][0], keys[index][1])
```

> TTL здесь должен быть **не больше 15 минут** — столько живёт pair-код в BFF
> (`PairController.CodeLifetime`). Существующего `TTL_SECONDS = 15 * 60` хватает.

## Точка 2. `handle_pair` — спросить, если ключей больше одного

Логика «взять ключ с максимальным сроком» заменяется на:

```python
async def handle_pair(user_id: int, code: str):
    from api.fatvpn_bff_api import complete_pairing
    from services import pairing_state

    keys = _collect_keys(user_id)      # [(short_uuid, expires_ms), ...] — код из Точки 2 выше

    if not keys:
        pairing_state.remember(user_id, code)      # без изменений
        await bot.send_message(user_id, "🔑 Чтобы подключить приложение, сначала "
                                        "оформите подписку или получите пробный период …")
        return

    if len(keys) == 1:
        short_uuid, expires_ms = keys[0]
        await _finish_pair(user_id, code, short_uuid, expires_ms)
        return

    # Несколько ключей — выбирает пользователь, а не бот.
    pairing_state.remember_choices(user_id, code, keys)
    kb = types.InlineKeyboardMarkup()
    for i, (short_uuid, expires_ms) in enumerate(keys):
        until = datetime.fromtimestamp(expires_ms / 1000).strftime("%d.%m.%Y")
        kb.add(types.InlineKeyboardButton(
            f"🔑 {short_uuid[:8]} · до {until}", callback_data=f"pairsel:{i}"))
    await bot.send_message(user_id, "Каким ключом подключить приложение?", reply_markup=kb)


@dp.callback_query_handler(lambda c: c.data.startswith("pairsel:"))
async def on_pair_select(call: types.CallbackQuery):
    from services import pairing_state
    chosen = pairing_state.take_choice(call.message.chat.id, int(call.data.split(":")[1]))
    if chosen is None:
        await call.answer("Код устарел — откройте приложение заново", show_alert=True)
        return
    code, short_uuid, expires_ms = chosen
    await call.answer()
    await _finish_pair(call.message.chat.id, code, short_uuid, expires_ms)


async def _finish_pair(user_id: int, code: str, short_uuid: str, expires_ms: int):
    from api.fatvpn_bff_api import complete_pairing
    try:
        await complete_pairing(code, user_id, short_uuid, expires_ms)
        await bot.send_message(user_id, "✅ Приложение FatVPN подключено. Вернитесь в приложение.")
    except Exception as e:
        await bot.send_message(user_id, "⚠️ Не удалось подключить приложение. Откройте его и попробуйте снова.")
        print(f"pair error: {e}")
```

> `/internal/pair/complete` всегда считается явным выбором — на стороне BFF он
> переключает аккаунт на присланный ключ без дополнительных флагов.

## Точка 3. `fatvpn_bff_api.py` — новые поля

```python
async def register_short_token(remnawave_subscription_id: str, expires_at_ms: int,
                               telegram_user_id: int) -> str:
    token = generate_short_token()
    await _post("/internal/tokens", {
        "shortToken": token,
        "remnawaveSubscriptionId": remnawave_subscription_id,
        "expiresAt": _iso(expires_at_ms),
        "telegramUserId": telegram_user_id,        # ← новое, слать ВСЕГДА
    })
    return token

async def upsert_subscription(telegram_user_id: int, subscription_id: str,
                              expires_at_ms: int, key_code: str = None,
                              make_active: bool = False,                   # ← новое
                              replaces_subscription_id: str = None):       # ← новое
    payload = {
        "telegramUserId": telegram_user_id,
        "subscriptionId": subscription_id,
        "expiresAt": _iso(expires_at_ms),
        "makeActive": make_active,
    }
    if key_code:
        payload["keyCode"] = key_code
    if replaces_subscription_id:
        payload["replacesSubscriptionId"] = replaces_subscription_id
    await _post("/internal/account/subscription", payload)


async def expire_short_token(short_token: str, remnawave_subscription_id: str,
                             telegram_user_id: int):                       # ← новое
    """Погасить код заменённого ключа — см. Точку 6."""
    await _post("/internal/tokens", {
        "shortToken": short_token,
        "remnawaveSubscriptionId": remnawave_subscription_id,
        "expiresAt": _iso(int((time.time() - 60) * 1000)),
        "telegramUserId": telegram_user_id,
    })
```

`telegram_user_id` в `register_short_token` — обязательный: без него код,
вставленный в приложении, снова становится «сам себе подписка», и продление до
него не доходит. Все вызывающие места надо обновить.

## Точка 4. Кто как зовёт `upsert_subscription`

| Место в боте | Что передаётся | Почему |
|---|---|---|
| `add_client_request_remnawave` (покупка / триал) | ничего | покупка второго ключа не должна снимать приложение с первого. BFF сам подхватит ключ, если активного нет или он истёк; а покупка «из приложения» доводится через отложенный pair-код, и это уже явный выбор |
| `refresh_remnawave_key` («Поменять ключ») | `replaces_subscription_id=<старый shortUuid>` | ключ пересоздан; приложение едет за ним, только если сидело на заменённом |
| `extend_remnawave_key_with_refresh` (продление перевыпуском) | `replaces_subscription_id=<старый shortUuid>` | то же самое: `shortUuid` меняется, хотя для пользователя это «продление» |
| `handle_extend_subscription` («Продлить») | ничего | `shortUuid` не меняется; BFF применит срок к активному ключу |
| `handle_key_details` (просмотр ключа) | ничего | **раньше просмотр ключа переключал приложение на него** — открыл список, полистал, и приложение уехало на последний просмотренный. Теперь BFF такой вызов отбрасывает |

Отложенный pair-код (`pairing_state.take`) теперь разбирается не только при
создании ключа, но и в обоих путях продления: пользователь с истёкшим ключом
приходит из приложения, продлевает — и pairing завершается сам.

## Точка 5. Показ кода без перевыпуска ключа

Уже сделано и менять не требуется: `handle_key_details` выдаёт «📱 Код для FatVPN
App» прямо на экране просмотра ключа и кэширует его в `self.key_token_map`, так
что повторные открытия экрана не плодят новых кодов. Пересоздавать ключ ради
кода не нужно. Изменилось только одно — в `register_short_token` теперь
передаётся `user_id`.

## Точка 6. Гасить код заменённого ключа

«Поменять ключ» пересоздаёт `short_uuid` — старая подписка в панели умирает, а
строка `Tokens` со старым кодом живёт до своего `expiresAt`. Пользователь,
который найдёт в переписке с ботом старый код и вставит его, попадёт на
**мёртвую подписку**. С доработкой выше цена выросла: раньше ломалась только эта
сессия, теперь вставка кода — явный выбор, и на мёртвую подписку переехал бы
весь аккаунт.

Отдельного эндпоинта для отзыва нет и не нужно: код гасится тем же
`/internal/tokens` с прошедшим `expiresAt` (`expire_short_token` в Точке 3).
В `handle_change_key` это делается **до** регистрации нового кода; старый код
берётся из `self.key_token_map` — кэша, который уже есть в `KeyHandler` и
наполняется при просмотре ключа (а к «Поменять ключ» пользователь приходит
именно с экрана ключа).

⚠️ **Остаточный случай.** `key_token_map` живёт в памяти процесса, так что после
перезапуска бота код заменяемого ключа неизвестен и погасить его нечем — он
доживёт до своего `expiresAt`. Чтобы закрыть и это, код надо хранить в БД рядом
с ключом. Отдельная задача.

## Чек-лист проверки (доработка 2)

1. Один ключ + `?start=pair<КОД>` → как раньше, без меню.
2. Два ключа + `?start=pair<КОД>` → меню выбора; выбранный ключ приезжает в
   `pair/complete`; в приложении в «Текущий ключ» — именно он.
3. Кнопка выбора, нажатая через 20 минут → «код устарел», без падения.
4. «Продлить» **неактивный** ключ → в приложении ничего не поменялось
   (ни срок, ни ключ).
5. «Продлить» **активный** ключ → в приложении новый срок, экран продления не
   появляется.
6. «Поменять ключ» → приложение переехало на новый ключ и продолжает работать
   без повторного входа.
7. Вставить в приложении код второго ключа → приложение переключилось на него,
   «Текущий ключ» совпадает с ботом; последующее продление этого ключа доезжает.
8. «Поменять ключ», затем вставить в приложении **старый** код → «Такого ключа
   нет или он истёк», аккаунт остался на новом ключе (Точка 6).
9. Открыть в боте экран **другого** (не активного) ключа → в приложении ничего
   не поменялось. Раньше просмотр переключал.
10. Ключ истёк, `?start=pair<КОД>` → бот пишет «Подписка истекла — продлите» и
    показывает обычное меню; после продления приложение подключается само.
11. Порядок деплоя: **сначала BFF, потом бот.** Старый BFF молча игнорирует
    новые поля — бот отработает без ошибок, но `telegramUserId` не сохранится и
    коды останутся непривязанными.

---

# Прогон доработки 2 на живом тестовом боте (2026-07-30)

> Первый раз, когда «Доработка 2» проверялась руками, а не только читалась.
> Бот `@testfatvpnnbot`, BFF на `https://api.fatklyuchi.space`. Роль приложения
> играли прямые вызовы API — APK для этого не нужен.

## Что подтвердилось

| Проверка | Как проверяли | Итог |
|---|---|---|
| Выбор ключа за пользователем, а не за ботом | В меню нажат ключ **с самым коротким** сроком (`y2K8Po…`), при том что старый код всегда брал самый длинный | ✅ в базе оказался выбранный |
| Сквозная нумерация кнопок при листании | Выбран ключ со **второй страницы** (`r9Lp…`) | ✅ приехал он, а не сосед |
| Отмена ничего не меняет | «↩️ В меню» | ✅ активный ключ и `UpdatedAt` не тронуты |
| Просмотр **не активного** ключа не переключает | Открыт экран `r9Lp…` при активном `gEk3…` | ✅ активный остался прежним |
| Вызов про чужой живой ключ без `makeActive` | `POST /internal/account/subscription` напрямую | ✅ не переключил; с `makeActive:true` — переключил |
| Вставка кода — явный выбор | `POST /auth/token` кодом неактивного ключа | ✅ аккаунт переехал, `CurrentKeyCode` стал его собственным |
| Ротация refresh и отзыв повторно предъявленного | `POST /auth/refresh` дважды одним токеном | ✅ внутри 30-секундного окна — 200 (гонка самого приложения), после — 401 |
| Лимит 3 устройства на ключ | 4 последовательных, затем 8 **параллельных** входов | ✅ ровно 3 слота, остальным `409 device_limit`; повторный вход занятого устройства проходит |

## Что найдено и исправлено по ходу

1. **Стена кнопок.** Меню рисовало по кнопке на каждый ключ — у одного из
   тестовых аккаунтов их 24. Добавлена пагинация по 5 (`_PAIR_PAGE_SIZE`,
   `_pair_menu_markup`) и кнопка «↩️ В меню».

2. **Кнопка из старого меню подключала не тот ключ.** Предложение хранится одно
   на пользователя и перезаписывается новым pairing, а в `callback_data` ехал
   только номер позиции. Нажатие в более раннем сообщении применяло этот номер к
   **текущему** списку: пользователь жал кнопку с одним ключом и получал другой.
   Именно это дважды дало ложный результат в самом прогоне. Теперь кнопка несёт
   код своего предложения (`pairsel:<code>:<index>`), `take_choice` сверяет его и
   **не тратит** действующее предложение при отказе. Проверено девятью прямыми
   тестами `services/pairing_state.py` (файл теста — в скретчпаде сессии).

3. **Старое меню оставалось с живыми кнопками.** Два одинаковых меню в чате
   различить невозможно. Теперь при новом pairing предыдущее сообщение
   переписывается в «Это предложение устарело — выберите ключ в сообщении ниже»
   и остаётся без кнопок.

4. **Диалог упирался в тупик.** После «✅ Приложение подключено» в чате не было
   ни одной кнопки. Теперь к финальному сообщению (и к сообщению об ошибке)
   прикладывается обычное меню бота.

5. **BFF: после смены ключа показывался код прежнего.** `AccountUpsert`
   переписывал `CurrentKeyCode` только если вызывающий прислал код, а pairing
   его не шлёт. `/me` возвращал `subscriptionId` нового ключа и `keyCode`
   старого — в приложении это строка «Текущий ключ», и вставка такого кода на
   втором телефоне увела бы его на другую подписку. Теперь при смене подписки
   без кода поле обнуляется. Два теста в `PairingControllerTests`.

## Что осталось непроверенным

**Токен доступа бота к панели Remnawave мёртв** — `z.fatvdsnvv.space` отвечает
боту `401 Unauthorized` и на `/api/users`, и на `/api/nodes` (токен BFF на тех же
эндпоинтах даёт 200; токены у них разные). Пока это так, тестовый бот не может
создать ни одного ключа, поэтому **не проверены**:

- «Поменять ключ» — и, следом, что приложение переезжает за новым ключом без
  повторного входа;
- гашение кода заменённого ключа (Точка 6) — проверять нечего, пока замена не
  проходит;
- «Продлить» кнопкой в боте (сам контракт, на котором она держится, проверен —
  см. таблицу выше);
- выдача триала.

Токен лежит открытым текстом в `bot/core/config.py` (`REMNAWAVE_TOKEN`), а не в
переменных окружения — отдельная задача к переносу в прод.

Ещё одно, не блокирующее: **каждый просмотр экрана ключа после перезапуска бота
выпускает новый код** — кэш `key_token_map` живёт в памяти процесса. На одном
ключе за вечер накопилось четыре живых кода. Известное ограничение (Точка 6),
лечится хранением кода в БД рядом с ключом.
