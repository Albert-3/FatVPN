# ТЗ: интеграция Telegram-бота с BFF FatVPN

> Источник контекста: раздел 3 `VPN-App-Project.md`.

## Статус: реализовано и проверено (День 3)

Интеграция выполнена на тестовом боте `@testfatvpnnbot`. Изменены два файла
в `/opt/FatVPN/bot/`:

- `api/fatvpn_bff_api.py` — новый модуль: генерация 32-символьного токена и вызов BFF
- `handlers/key_handlers.py` — патч: вызов BFF после смены ключа, показ токена пользователю

## Задача

Кнопка **«Поменять ключ»** в боте выдаёт 32-символьный токен `[A-Z0-9]` вместо
длинной sub-ссылки Remnawave. Пользователь вводит этот токен в приложении FatVPN.

## Реализация

### `bot/api/fatvpn_bff_api.py`

```python
import aiohttp
import random
import string
from datetime import datetime, timezone

BFF_URL = "http://fatvpn-bff:5030"   # имя контейнера (Docker-сеть fatvpn_default)
BOT_SECRET = "<из env BFF-контейнера>"  # Bot__Secret из docker inspect fatvpn-bff

def generate_short_token(length=32) -> str:
    chars = string.ascii_uppercase + string.digits
    return ''.join(random.choices(chars, k=length))

async def register_short_token(remnawave_subscription_id: str, expires_at_ms: int) -> str:
    token = generate_short_token()
    expires_dt = datetime.fromtimestamp(expires_at_ms / 1000, tz=timezone.utc)
    payload = {
        "shortToken": token,
        "remnawaveSubscriptionId": remnawave_subscription_id,
        "expiresAt": expires_dt.isoformat()
    }
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{BFF_URL}/internal/tokens",
            json=payload,
            headers={"X-Bot-Secret": BOT_SECRET},
            timeout=aiohttp.ClientTimeout(total=10)
        ) as resp:
            if resp.status not in (200, 201):
                text = await resp.text()
                raise Exception(f"BFF error {resp.status}: {text}")
    return token
```

### Изменения в `handlers/key_handlers.py`

**`handle_change_key`** — после создания нового ключа в Remnawave:
```python
import time as _time
expires_at_ms = int(time_result) if time_result and time_result != False \
    else int((_time.time() + 30 * 86400) * 1000)
from api.fatvpn_bff_api import register_short_token
short_token = await register_short_token(short_uuid, expires_at_ms)
```
Сообщение пользователю показывает оба варианта (Фаза 2 — до выхода Flutter-приложения):
```
✅ · Ключ обновлен!
📱 Код для FatVPN App:
<short_token>
🔗 Ссылка на подписку (до выхода приложения):
<subscription_url>
```
После релиза Flutter-приложения строку с `subscription_url` убрать.

**`handle_key_details`** — просмотр ключа отображает `{subscription_url}` (без изменений).

## Инфраструктура

| Параметр | Значение |
|---|---|
| Бот | Docker-контейнер `fatvpn-bot`, `/opt/FatVPN/` |
| BFF | Docker-контейнер `fatvpn-bff`, `/opt/fatvpn-bff/backend/` |
| Сеть | `fatvpn_default` — объявлена в обоих compose-файлах, пересоздаётся автоматически |
| BFF URL из бота | `http://fatvpn-bff:5030` |
| BOT_SECRET | из `docker inspect fatvpn-bff` → переменная `Bot__Secret` |

### Конфигурация сети (уже применена на сервере)

`/opt/FatVPN/docker-compose.yml` — бот объявляет сеть:
```yaml
networks:
  default:
    name: fatvpn_default
```

`/opt/fatvpn-bff/backend/docker-compose.yml` — BFF подключается к ней:
```yaml
services:
  bff:
    ...
    networks:
      - default
      - fatvpn_default

networks:
  fatvpn_default:
    external: true
```

После этого `docker network connect` вручную не нужен — сеть восстанавливается при любом `docker compose up`.

## Деплой бота

```bash
cd /opt/FatVPN
docker compose build --no-cache
docker compose up -d --force-recreate
```

## Деплой BFF

```bash
cd /opt/fatvpn-bff/backend
git pull
docker compose build --no-cache bff
docker compose up -d bff
```

## Миграция на прод-бот

Текущая интеграция работает только на `@testfatvpnnbot`. При переносе на прод-бот:
1. Скопировать `bot/api/fatvpn_bff_api.py` в прод-репозиторий бота
2. Применить те же патчи к `handlers/key_handlers.py`
3. Убедиться, что прод-бот в той же Docker-сети что и BFF
4. `BOT_SECRET` взять из `docker inspect fatvpn-bff` → `Bot__Secret`
