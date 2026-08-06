# Перенос доработок на прод-бота FatVPN — техническое приложение

> Документ для разработчиков основного (прод) Telegram-бота. Самодостаточен:
> знание остальной архитектуры не требуется. Все доработки уже реализованы и
> проверены на тестовом боте `@testfatvpnnbot`.
>
> Полные исходные ТЗ: `docs/bot-integration-spec.md` (код для приложения),
> `docs/bot-pairing-spec.md` (pairing + «Доработка 2: ключ выбирает
> пользователь»). Этот файл — сводка того, что именно надо перенести.

---

## 1. Что вообще происходит

Появилось мобильное приложение FatVPN (Android + iOS). Между приложением и
панелью Remnawave стоит наш сервис — **BFF** (`/opt/fatvpn-bff` на сервере
`87.121.221.229`). Приложение никогда не ходит в панель напрямую.

Бот в этой схеме отвечает за две вещи:

1. **Связать** пользователя Telegram с приложением — либо по одноразовому коду
   pairing, либо выдав 32-символьный «Код для FatVPN App».
2. **Держать в BFF актуальной** информацию о том, какой подпиской пользователь
   сейчас пользуется (создание ключа, смена, продление).

Без второго пункта продление подписки в боте не доезжает до приложения:
пользователь оплатил, а приложение продолжает показывать «подписка истекла».

**Все изменения аддитивны.** Платёжка, рефералка, выдача инструкций и весь
существующий функционал не затрагиваются. Все вызовы BFF обёрнуты в
`try/except` — недоступность BFF не должна ломать выдачу ключа.

---

## 2. Контракт с BFF (3 вызова)

Базовый адрес: см. §5 (зависит от того, на одном сервере бот с BFF или нет).
Все вызовы защищены заголовком `X-Bot-Secret: <BOT_SECRET>`.

Везде `expiresAt` — строка **ISO 8601 в UTC**. В боте срок хранится в
миллисекундах, конвертация:
`datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()`

### 2.1 `POST /internal/tokens` — зарегистрировать «Код для FatVPN App»

```json
{
  "shortToken": "A1B2C3D4E5F6G7H8J9K0L1M2N3P4Q5R6",
  "remnawaveSubscriptionId": "a1b2c3d4",
  "expiresAt": "2026-08-04T12:00:00+00:00",
  "telegramUserId": 123456789
}
```

`shortToken` — 32 символа `[A-Z0-9]`, генерирует бот.
`remnawaveSubscriptionId` — `short_uuid` ключа.
`telegramUserId` — **слать всегда**. Без него код становится «сам себе
подписка», и последующее продление до приложения не доходит.

### 2.2 `POST /internal/pair/complete` — завершить pairing по коду

Вызывается, когда пользователь пришёл в бот по ссылке `?start=pair<КОД>`.

```json
{
  "pairCode": "AB12CD",
  "telegramUserId": 123456789,
  "subscriptionId": "a1b2c3d4",
  "expiresAt": "2026-08-04T12:00:00+00:00"
}
```

Ответы: **200** — принято; **404** — код неизвестен или истёк (сказать
пользователю «код устарел, откройте приложение заново»); **409** — код уже
использован.

Этот вызов всегда трактуется как **явный выбор** пользователя — BFF переключает
аккаунт на присланный ключ без дополнительных флагов.

### 2.3 `POST /internal/account/subscription` — обновить подписку аккаунта

```json
{
  "telegramUserId": 123456789,
  "subscriptionId": "a1b2c3d4",
  "expiresAt": "2026-08-04T12:00:00+00:00",
  "makeActive": false,
  "keyCode": "A1B2...",                  // необязательно
  "replacesSubscriptionId": "old-uuid"   // необязательно
}
```

Upsert по `telegramUserId`. Смысл флагов — в §4, это самая важная часть.

---

## 3. Файлы, которые меняются

Структура тестового бота — Python 3.11 / aiogram 2.x, каталог `/opt/FatVPN/bot/`.
Если в прод-боте структура другая, ориентироваться по функциям.

| Файл | Что | Статус |
|---|---|---|
| `api/fatvpn_bff_api.py` | весь модуль обращений к BFF | **новый** |
| `services/pairing_state.py` | хранилище отложенных pair-кодов и вариантов выбора | **новый** |
| `main_refactored.py` | перехват `/start pair<код>`, `handle_pair`, callback `pairsel:` | правка |
| `database/db_remnawave.py` | `add_client_request_remnawave`, `refresh_remnawave_key`, `extend_remnawave_key_with_refresh` | правка |
| `handlers/key_handlers.py` | `handle_change_key`, `handle_extend_subscription`, `handle_key_details` | правка |

На тестовом сервере рядом с каждым изменённым файлом лежит оригинал
`<файл>.pre-keychoice` — по нему видно точный diff.

### 3.1 `api/fatvpn_bff_api.py` (новый)

```python
import os, time, random, string
import aiohttp
from datetime import datetime, timezone

BFF_URL = os.environ.get("BFF_URL", "http://fatvpn-bff:5030")
BOT_SECRET = os.environ["BOT_SECRET"]        # не хардкодить

def _iso(expires_at_ms: int) -> str:
    return datetime.fromtimestamp(expires_at_ms / 1000, tz=timezone.utc).isoformat()

def generate_short_token(length=32) -> str:
    return ''.join(random.choices(string.ascii_uppercase + string.digits, k=length))

async def _post(path: str, payload: dict):
    async with aiohttp.ClientSession() as session:
        async with session.post(f"{BFF_URL}{path}", json=payload,
                                headers={"X-Bot-Secret": BOT_SECRET},
                                timeout=aiohttp.ClientTimeout(total=10)) as resp:
            if resp.status not in (200, 201):
                raise Exception(f"BFF error {resp.status}: {await resp.text()}")

async def register_short_token(remnawave_subscription_id: str, expires_at_ms: int,
                               telegram_user_id: int) -> str:
    token = generate_short_token()
    await _post("/internal/tokens", {
        "shortToken": token,
        "remnawaveSubscriptionId": remnawave_subscription_id,
        "expiresAt": _iso(expires_at_ms),
        "telegramUserId": telegram_user_id,
    })
    return token

async def expire_short_token(short_token: str, remnawave_subscription_id: str,
                             telegram_user_id: int):
    """Погасить код заменённого ключа — см. §4.3."""
    await _post("/internal/tokens", {
        "shortToken": short_token,
        "remnawaveSubscriptionId": remnawave_subscription_id,
        "expiresAt": _iso(int((time.time() - 60) * 1000)),
        "telegramUserId": telegram_user_id,
    })

async def complete_pairing(pair_code: str, telegram_user_id: int,
                           subscription_id: str, expires_at_ms: int):
    await _post("/internal/pair/complete", {
        "pairCode": pair_code,
        "telegramUserId": telegram_user_id,
        "subscriptionId": subscription_id,
        "expiresAt": _iso(expires_at_ms),
    })

async def upsert_subscription(telegram_user_id: int, subscription_id: str,
                              expires_at_ms: int, key_code: str = None,
                              make_active: bool = False,
                              replaces_subscription_id: str = None):
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
```

### 3.2 `services/pairing_state.py` (новый)

Хранилище в памяти процесса. Коды живут 15 минут — столько же, сколько pair-код
в BFF, поэтому БД не нужна.

```python
import time

_pending = {}   # user_id -> (pair_code, expires_epoch)
_choices = {}   # user_id -> (pair_code, [(short_uuid, expires_ms), ...], expires_epoch)
TTL_SECONDS = 15 * 60

def remember(user_id: int, code: str):
    _pending[user_id] = (code, time.time() + TTL_SECONDS)

def take(user_id: int):
    item = _pending.pop(user_id, None)
    if not item:
        return None
    code, exp = item
    return code if time.time() < exp else None

def remember_choices(user_id: int, code: str, keys: list):
    _choices[user_id] = (code, keys, time.time() + TTL_SECONDS)

def take_choice(user_id: int, index: int):
    item = _choices.pop(user_id, None)
    if not item:
        return None
    code, keys, exp = item
    if time.time() >= exp or index < 0 or index >= len(keys):
        return None
    return (code, keys[index][0], keys[index][1])
```

### 3.3 `/start` — перехват pairing-ссылки

В самом начале обработчика `/start`, до существующей логики (сейчас там
разбирается реферальный код):

```python
@dp.message_handler(commands=['start'])
async def send_welcome(message: types.Message):
    arg = message.text[7:] if len(message.text) > 7 else ""
    if arg.startswith("pair"):
        await handle_pair(message.chat.id, arg[4:])   # arg[4:] — сам код
        return
    # ...существующая логика без изменений...
```

### 3.4 `handle_pair` — выбор ключа делает пользователь

Собрать все ключи пользователя. Дальше три случая:

- **ключей нет** — запомнить код (`pairing_state.remember`) и показать обычное
  меню покупки/триала. Pairing завершится сам, когда ключ появится;
- **один ключ** — сразу `complete_pairing`;
- **несколько** — показать инлайн-меню выбора. В `callback_data` кладётся
  **только индекс** (`pairsel:0`, `pairsel:1`, …), сами ключи лежат на сервере в
  `remember_choices`. Так укладываемся в лимит Telegram 64 байта и пользователь
  не может подставить чужой `short_uuid`, подделав callback.

```python
    kb = types.InlineKeyboardMarkup()
    for i, (short_uuid, expires_ms) in enumerate(keys):
        until = datetime.fromtimestamp(expires_ms / 1000).strftime("%d.%m.%Y")
        kb.add(types.InlineKeyboardButton(
            f"🔑 {short_uuid[:8]} · до {until}", callback_data=f"pairsel:{i}"))
    await bot.send_message(user_id, "Каким ключом подключить приложение?", reply_markup=kb)


@dp.callback_query_handler(lambda c: c.data.startswith("pairsel:"))
async def on_pair_select(call: types.CallbackQuery):
    chosen = pairing_state.take_choice(call.message.chat.id, int(call.data.split(":")[1]))
    if chosen is None:
        await call.answer("Код устарел — откройте приложение заново", show_alert=True)
        return
    code, short_uuid, expires_ms = chosen
    await call.answer()
    await _finish_pair(call.message.chat.id, code, short_uuid, expires_ms)
```

`_finish_pair` — обёртка над `complete_pairing` с сообщением «✅ Приложение
FatVPN подключено, вернитесь в приложение» и текстом ошибки в except.

### 3.5 «Код для FatVPN App» на экране ключа

Уже работает и переписывать не надо: `handle_key_details` показывает код прямо
на экране просмотра ключа и кэширует его в `self.key_token_map`, поэтому
повторные открытия не плодят новых кодов. Пересоздавать ключ ради кода не нужно.
Единственное изменение — в `register_short_token` теперь передаётся `user_id`.

---

## 4. Главное: кто и как зовёт `upsert_subscription`

Это та часть, где легко сделать по-разному и получить неверное поведение.
Исходная проблема: у пользователя может быть **несколько ключей**, а активная
подписка в приложении ровно одна. Раньше выбор происходил молча — и приложение
уезжало на другой ключ за спиной у пользователя.

**Правило: всё, что не является явным выбором пользователя, не переключает
приложение.**

| Место в боте | Что передаём | Почему именно так |
|---|---|---|
| `add_client_request_remnawave` (покупка / триал) | ничего сверх обязательных полей | покупка второго ключа не должна снимать приложение с первого. BFF сам подхватит ключ, если активного нет или он истёк |
| `refresh_remnawave_key` («Поменять ключ») | `replaces_subscription_id=<старый short_uuid>` | ключ пересоздан; приложение переезжает на новый, только если сидело на заменённом |
| `extend_remnawave_key_with_refresh` (продление перевыпуском) | `replaces_subscription_id=<старый short_uuid>` | то же: `short_uuid` меняется, хотя для пользователя это «продление» |
| `handle_extend_subscription` («Продлить») | ничего | `short_uuid` не меняется, BFF применит новый срок к активному ключу |
| `handle_key_details` (просмотр ключа) | ничего | **раньше сам просмотр переключал приложение** на открытый ключ: полистал список — приложение уехало на последний просмотренный. Теперь BFF такой вызов отбрасывает |

### 4.1 Отложенный pairing

`pairing_state.take(user_id)` надо разбирать не только при создании ключа, но и
в **обоих** путях продления. Сценарий: у пользователя ключ истёк, он пришёл из
приложения по pairing-ссылке, продлил — pairing должен завершиться сам, без
повторного захода в приложение.

### 4.2 `add_client_request_remnawave` — создание ключа

После `savecfg(...)`:

```python
    await upsert_subscription(client_id, short_uuid, expiry_timestamp)
    pending = pairing_state.take(client_id)
    if pending:
        await complete_pairing(pending, client_id, short_uuid, expiry_timestamp)
```

### 4.3 Гасить код заменённого ключа

«Поменять ключ» пересоздаёт `short_uuid` — старая подписка в панели умирает, но
строка с её кодом живёт до своего `expiresAt`. Пользователь, который найдёт в
переписке старый код и вставит его в приложение, попадёт на **мёртвую
подписку** — и, поскольку вставка кода теперь явный выбор, туда переедет весь
аккаунт.

Отдельного эндпоинта для отзыва нет: код гасится тем же `/internal/tokens` с
уже прошедшим `expiresAt` (`expire_short_token`). Делается это в
`handle_change_key` **до** регистрации нового кода; старый код берётся из
`self.key_token_map`.

⚠️ **Известное ограничение.** `key_token_map` живёт в памяти процесса — после
перезапуска бота код заменяемого ключа неизвестен и погасить его нечем, он
доживёт до своего `expiresAt`. Чтобы закрыть и это, код надо хранить в БД рядом
с ключом. Отдельная задача, на релиз не влияет.

### 4.4 Код выдают **все** входы, а не только «Мои ключи» (добавлено 2026-08-03)

Найдено на живом боте: экран после **покупки** (`handle_tarif_purchase`) и экран
**пробного ключа** (`trial_handler`) не звали ни `register_short_token`, ни
`upsert_subscription`. Пользователь платил и не получал ничего, что можно вставить в
приложение, — код существовал только если потом зайти в «Мои ключи». Это не косметика:
BFF в этот момент вообще не знал, что у аккаунта появился ключ.

При переносе на прод-бота проверить обе ветки. В каждой после успешной выдачи ключа:

```python
    expires_at_ms = gettime(full_key) or fallback_ms   # срок из панели, не арифметика
    short_token = await register_short_token(short_uuid, expires_at_ms, user_id)
    key_handler.key_token_map[full_key] = short_token   # чтобы экран ключа не выпустил второй
    await upsert_subscription(user_id, short_uuid, expires_at_ms, key_code=short_token)
```

— **без** `make_active`: BFF сам подхватит ключ, если активного нет или он истёк, а
переезд с живого ключа на другой остаётся явным действием пользователя. Весь блок в
`try`: деньги уже списаны, и ошибка здесь не имеет права оставить пользователя без
экрана. И не забыть проводку `trial_handler.key_handler = key_handler` — без неё
пробный ключ получит второй код при первом же заходе в «Мои ключи».

---

## 5. Инфраструктура

| Параметр | Значение |
|---|---|
| BFF | контейнер `fatvpn-bff`, `/opt/fatvpn-bff/backend/` на `87.121.221.229` |
| Адрес BFF, если бот на том же сервере | `http://fatvpn-bff:5030` (общая docker-сеть `fatvpn_default`) |
| Адрес BFF, если бот на другом сервере | публичный: сейчас `http://87.121.221.229:5030`, после переезда на HTTPS — `https://api.fatklyuchi.space` |
| `BOT_SECRET` | из `docker inspect fatvpn-bff` → переменная `Bot__Secret`. Добавить в `environment` сервиса бота |

Если бот прода живёт **на другом сервере** — сообщите его IP: `/internal/*`
надо будет закрыть по источнику, сейчас эти эндпоинты защищены только общим
секретом.

Общая docker-сеть (когда боты на одном сервере) объявляется в обоих
compose-файлах, вручную `docker network connect` не нужен:

```yaml
# бот
networks:
  default:
    name: fatvpn_default

# BFF
services:
  bff:
    networks: [default, fatvpn_default]
networks:
  fatvpn_default:
    external: true
```

### Порядок деплоя

**Сначала BFF, потом бот.** Старый BFF молча игнорирует новые поля: бот
отработает без ошибок, но `telegramUserId` не сохранится и коды останутся
непривязанными.

```bash
cd /opt/fatvpn-bff/backend && git pull && docker compose build --no-cache bff && docker compose up -d bff
cd /opt/FatVPN && docker compose build --no-cache && docker compose up -d --force-recreate
```

---

---

## 5a. ✅ ПЕРЕНОС ВЫПОЛНЕН 2026-08-06

Сделано на боевом боте `@Fat_VPN_bot` (`/opt/FatVPN/bot/` на 95.85.248.29,
где после переезда живёт и BFF).

**Перед началом снята резервная копия:** `/opt/fatvpn-bot-backups/` —
`db-20260806-164629.db` (через `sqlite3 .backup`, а не копированием файла:
бот пишет в базу постоянно, и `cp` дал бы порванную копию; `integrity_check`
пройден) и `code-20260806-164629.tar.gz`. Откат — распаковать архив и
пересобрать; точечный откат — файлы `*.pre-integration-20260806` рядом с
оригиналами.

**Как переносили.** Не копированием файлов, а вставками по анкерам, потому что
коды разошлись **в обе стороны**. Добавлено целиком два новых файла
(`api/fatvpn_bff_api.py`, `services/pairing_state.py`) и 19 вставок в пяти:
`main_refactored.py` (перехват `/start pair<код>`, меню выбора ключа и четыре
callback-обработчика — зарегистрированы **до** catch-all, иначе их съедает
роутер), `database/db_remnawave.py` (создание, продление и смена ключа сообщают
в BFF, с `replacesSubscriptionId`), `callback_handlers.py`, `key_handlers.py`,
`trial_handler.py`.

**Что сознательно сохранено** — ради этого и делалась ручная работа:

- родные формулировки экранов «ключ» и «поменять ключ» (в тестовом боте они
  переписаны на «до выхода приложения»); код приложения вставлен **внутрь**
  сообщения, а не поверх;
- реферальные коды в `/start` (`adduserref`, `increment_ref_click`);
- правки от 2026-08-06: «Стабильное соединение» и ссылки на
  `api.fatklyuchi.space/privacy/ru` и `/terms/ru`;
- `core/config.py` (там собственные токены боевого бота) и `bot/db.db` не
  тронуты вовсе.

**Одно намеренное отступление от тестового кода.** В тестовом боте вызовы BFF в
«Поменять ключ» стоят вне `try`: при недоступном BFF ключ уже пересоздан, но
пользователь видит «Ошибка смены ключа» — то есть пункт 5 чек-листа там не
выполняется. На боевом блок обёрнут в `try`, как и требует §1 брифа.

**Проверено с сервера:** синтаксис всех семи файлов, старт бота
(`Bot: FatVPN | Бот [@Fat_VPN_bot]` → `Start polling`, ноль Traceback), связь с
BFF из контейнера — вызов с несуществующим кодом отвечает **404**, а не 401/403,
то есть секрет принят. `BFF_URL` остался внутренним `http://fatvpn-bff:5030` —
бот и BFF теперь на одной машине и в одной docker-сети.

⚠️ **Ничего из §6 с сервера проверить нельзя** — все 11 пунктов требуют живого
Telegram. Пройти руками, отдельно посмотреть пагинацию меню выбора при более чем
пяти ключах (в чек-листе её нет).

⚠️ **Долг, не блокирующий работу:** `BOT_SECRET` вшит в
`api/fatvpn_bff_api.py` как fallback (так же, как в тестовом боте), а
`/opt/FatVPN` — git-репозиторий, и при коммите секрет уйдёт в историю.
Правильно — вынести в `.env` и `environment:` в compose. Сюда же ложится общая
задача ротации секретов бота.

## 6. Чек-лист приёмки

Проверять на прод-боте после переноса. Пункты 1–5 — базовая связка,
6–11 — выбор ключа.

1. Один ключ + `?start=pair<КОД>` → бот пишет «Приложение подключено», меню
   выбора не показывается.
2. Ключа нет + `?start=pair<КОД>` → бот ведёт на покупку; после создания ключа
   pairing завершается автоматически, без возврата в бот.
3. «Поменять ключ» → приложение переехало на новый ключ и работает **без
   повторного входа**.
4. «Продлить» активный ключ → в приложении новый срок, экран «подписка
   истекла» не появляется.
5. BFF выключен → ключ всё равно выдаётся и продлевается, ошибка только в логах.
6. Два ключа + `?start=pair<КОД>` → меню выбора; в приложении в «Текущий ключ»
   именно выбранный.
7. Кнопка выбора, нажатая через 20 минут → «код устарел», бот не падает.
8. «Продлить» **неактивный** ключ → в приложении не изменилось ничего.
9. Вставить в приложении код второго ключа → приложение переключилось на него,
   последующее продление этого ключа доезжает.
10. «Поменять ключ», затем вставить в приложении **старый** код → «Такого ключа
    нет или он истёк», аккаунт остался на новом ключе.
11. Открыть в боте экран **не активного** ключа → в приложении не изменилось
    ничего.


### 6a. Прогон чек-листа — начат 2026-08-06, НЕ ЗАВЕРШЁН

**Как проверяем, не дожидаясь сборки.** В сборке на телефоне владельца зашит
ещё тестовый бот, поэтому пейринг из приложения увёл бы нас не туда. Вместо
этого код пейринга создаётся напрямую на BFF и открывается ссылкой в боевого
бота:

```bash
# 1. код (живёт 15 минут)
curl -s -X POST https://api.fatklyuchi.space/pair/start   -H 'Content-Type: application/json'   -d '{"attestationToken":"checklist-run-<дата>"}'
# 2. открыть в Telegram: https://t.me/Fat_VPN_bot?start=pair<КОД>
# 3. смотреть, что записалось на сервере:
ssh root@95.85.248.29 "docker exec fatvpn-postgres psql -U fatvpn -d fatvpn -t -A -F' | '   -c \"SELECT \\\"Code\\\", \\\"Status\\\", COALESCE(\\\"AccountId\\\"::text,'нет')   FROM \\\"PairingCodes\\\" ORDER BY \\\"CreatedAt\\\" DESC LIMIT 3;\""
```

`Status`: `0` — ожидает, `1` — бот завершил, `2` — сессия выдана приложению.

| # | Пункт | Результат |
|---|---|---|
| 1 | Один ключ + pair → сразу «подключено» | ⬜ **неприменимо к этому владельцу** — у него несколько ключей, сценарий сразу ушёл в п. 6. Проверять на аккаунте с одним ключом |
| 6 | Два ключа + pair → меню выбора | 🟡 **половина пройдена**: бот перехватил `?start=pair<код>`, показал меню выбора, и — что важнее — **код остался в состоянии «ожидает»**, то есть бот не завершил пейринг самовольно. Осталось выбрать ключ и сверить, что в BFF уехал именно выбранный |
| 2,3,4,5,7,8,9,10,11 | — | ⬜ не начаты |

Наблюдение из прогона, на будущее: **путь пейринга ничего не пишет в лог бота**
— ни перехвата ссылки, ни показа меню, ни выбора. Не ошибка, но когда придёт
жалоба «нажал и ничего», опереться будет не на что. После приёмки добавить
несколько строк логирования.

---

## 7. Что нужно от вашей стороны

Если переносите сами:

1. Исходники прод-бота (или доступ к репозиторию) — чтобы соотнести структуру:
   у тестового это `main_refactored.py`, `database/db_remnawave.py`,
   `handlers/key_handlers.py`.
2. Тестовая среда прод-бота — второй бот-токен и отдельный контейнер. Проверять
   чек-лист на живых пользователях нельзя: ошибка в §4 тихо переключает людей
   между ключами.
3. Кто ставит `BOT_SECRET` в окружение бота и на каком сервере крутится бот
   прода (см. §5).

Быстрее и надёжнее — доступ к серверу прод-бота: перенос занимает несколько
часов, чек-лист прогоняется в тот же день, промежуточная передача требований
не нужна.
