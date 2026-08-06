# Ранбук переезда боевого BFF: 87.121.221.229 → 95.85.248.29

> Составлен 2026-08-06. **Ни один шаг переезда ещё не выполнен.**
>
> **Правка 2026-08-06 (после разведки).** Первая редакция писалась без доступа к
> `95.85.248.29` и исходила из «сервер пустой, кроме дефолтной заглушки nginx».
> Разведка (§3) это опровергла: доступ есть, сервер **не пустой** — на нём стоит
> **боевой Telegram-бот `@Fat_VPN_bot`**, а порт 80 держит системный nginx,
> обслуживающий **живой платёжный домен `pay.fatvnv.space`**. Поэтому переписаны:
> §1, §3, §4, §5 (Caddy на новом сервере **не поднимается вообще** — TLS и статику
> отдаёт nginx), §7.2, §13, §16, §17, §18; добавлен §13a (ufw). Всё, что помечено
> «2026-08-06», — это правки по фактам разведки.
>
> Стиль и уроки взяты из `docs/deploy-runbook-2026-07-29.md`: сначала проверки
> окружения, потом действия; «контейнер поднялся» ≠ «сервис работает»; после
> любого деплоя проверяется **эндпоинт с телом запроса**, а не только `/health`.
>
> Каждая команда помечена: `# ЧИТАЕТ` — ничего не меняет, безопасно выполнять
> когда угодно; `# МЕНЯЕТ` — меняет состояние сервера/DNS/базы.
>
> ⚠️ Секреты (пароли root, содержимое `.env`, токены) в этот файл **не вписывать**.
> Везде, где нужно что-то сверить, сверяются хеши и имена переменных, а не значения.

---

## 1. Зачем переезд и что именно едет

**Едет** из `backend/docker-compose.yml` — **два сервиса из трёх**:

| Компонент | Контейнер | Что держит | Едет? |
|---|---|---|---|
| BFF (.NET 10) | `fatvpn-bff` | API приложения, порт `5030` | **да** |
| PostgreSQL 16 | `fatvpn-postgres` | **живые данные**: аккаунты, ключи, сессии, refresh-цепочки, устройства с триалом | **да** |
| Caddy | `fatvpn-caddy` | TLS для `api.fatklyuchi.space`, статика `/privacy`, `/privacy/ru`, `/support` | **НЕТ** (2026-08-06) |

⛔ **Caddy на `95.85.248.29` не запускается ни разу.** Порты 80/443 там принадлежат
системному nginx, который обслуживает боевой платёжный домен `pay.fatvnv.space`
(§3). Поднять рядом Caddy — значит либо получить «port is already allocated» на 80,
либо, что хуже, тихо занять 443 и увести на себя TLS. Всё, что делал Caddy —
терминация TLS и три статические страницы — переносится в **отдельный vhost того же
nginx** (§5). Сервис `caddy` глушится профилем в локальном override (§4.5), чтобы
случайный `docker compose up -d` его не поднял.

**Не едет** (остаётся на 87.121.221.229): тестовый бот `@testfatvpnnbot` в `/opt/FatVPN`.

**Уже стоит на 95.85.248.29 и не трогается**: боевой бот `@Fat_VPN_bot`
(контейнер `fatvpn-bot`, `/opt/FatVPN`, вебхук платежей `0.0.0.0:4444`) и nginx
с `pay.fatvnv.space`.

Важное следствие правки 2026-08-06: **боевой бот и BFF окажутся на одной машине**.
Прежняя редакция §13 исходила из обратного и требовала переводить бота на домен —
это больше не нужно, см. §13.

### 1.1 Что известно достоверно

| Факт | Источник |
|---|---|
| Старый сервер: чекаут `master` в `/opt/fatvpn-bff/backend`, локальным остался только `.env` | `docs/deploy-runbook-2026-07-29.md` |
| Публичный `0.0.0.0:5030` **намеренно открыт** — на нём сидят уже разошедшиеся сборки | `backend/docker-compose.yml:29-33` |
| Каноничный адрес приложения — `https://api.fatklyuchi.space` | `app/lib/config/api_config.dart:8` |
| Приложение пинит **корни ISRG** (Let's Encrypt), а не ключ сервера | `app/lib/config/ca_pins.dart`, `docs/api-contract.md` §«Базовый адрес и TLS» |
| `AllowedHosts` — точный список, имя вне списка получает **400 на всё, включая `/health`** | `backend/docker-compose.yml:45`, тест `DeploymentConfigTests` |
| Обязательные переменные, без которых контейнер уходит в crash-loop: `Jwt__Secret` (≥32 байт), `Bot__Secret` (≥16), `Remnawave__ApiToken`, `Trial__DeviceKeySalt` | `docs/api-contract.md` §«Обязательные переменные окружения» |
| Зона `fatklyuchi.space` — в Cloudflare, аккаунт есть; `api.` — **серое облако**, оранжевое не включать никогда | `docs/panel-ha-failover-plan.md` §0.1 |
| Бэкап BFF: `/opt/fatvpn-ops/backup_bff.sh`, cron `:17`, дампы в `/opt/fatvpn-backups`, ретеншен 48 ч | `docs/panel-backup-audit-runbook.md` |
| Сторож бэкапов BFF живёт **на сервере панели**: `/opt/remnawave/check_bff_backup.sh`, ходит по SSH на `87.121.221.229`, cron `:50` | там же |
| Сторож бэкапов панели живёт **на сервере BFF**: `/opt/fatvpn-ops/check_panel_backup.sh`, cron `:43` | там же |
| Оба сервера того провайдера оплачены до **16.08.2026** | `docs/panel-ha-failover-plan.md` §0.2 |
| **`95.85.248.29` — боевой сервер бота, не пустая машина** (2026-08-06) | §3, разведка по SSH |

### 1.2 Что закрыла разведка (2026-08-06)

Прежний список «что неизвестно» закрыт целиком, кроме одного пункта:

- ✅ Доступ есть: наш ed25519-ключ установлен, `ssh -o BatchMode=yes root@95.85.248.29` работает.
- ✅ На сервере живёт **боевой бот**. План переезда пересмотрен, см. §1 и §13.
- ✅ Порт 80 держит **системный nginx** с боевым `pay.fatvnv.space` — нужен, не гасится.
- ✅ 443 снаружи закрыт **потому что его никто не слушает**; провайдерского фильтра нет
  (80 отвечает снаружи), `ufw` **выключен** (`Status: inactive`).
- ✅ DNS-01 и токен Cloudflare **необязательны**: certbot 2.9.0 с плагином nginx уже
  установлен, сертификат берётся HTTP-01 (§5).
- ✅ Прод-бот: `@Fat_VPN_bot`, стоит **здесь же**, в BFF **не ходит вообще** (§13).
- ❓ Осталось непроверенным: достаёт ли новый сервер до панели `https://z.fatvdsnvv.space`.
  Проверяется первой же командой §4 — без этого `/config` и `/servers` будут отвечать 502.

---

## 2. Точка невозврата и откат

### 2.1 Где проходит граница

```
§3–§9  ─────────────────────────────────────►  откат БЕСПЛАТНЫЙ
(разведка, подготовка, vhost+серт, репетиция переноса базы, проверки по --resolve)
   старый сервер всё это время работает и обслуживает всех

шаг 10.1  ── остановка bff на старом сервере ──►  откат = «поднять обратно»
   цена: простой в минуты, данные не теряются

§11       ── ПЕРЕКЛЮЧЕНИЕ A-ЗАПИСИ ───────────►  ⛔ ТОЧКА НЕВОЗВРАТА
   с этого момента записи идут в НОВУЮ базу
```

**Точка невозврата — §11 (смена A-записи `api.fatklyuchi.space`).** Всё до неё
обратимо простым «ничего не делать»: новый BFF стоит рядом и никем не
используется, старый работает.

### 2.2 Что теряется при откате ПОСЛЕ переключения DNS

В новую базу за время работы успевают попасть:

- новые сессии (`RefreshTokens`) — по замеру владельца **30–250 новых сессий в день**;
- ротации refresh-токенов у всех активных клиентов (приложение обновляет access
  каждые 30 минут — `Jwt:AccessTokenLifetime`);
- новые пейринги (`PairingCodes`, `Accounts`), новые триалы (`Devices`, `Trials`),
  занятые слоты устройств (`TokenDevices`).

Простой откат A-записи **без переноса данных назад** означает: каждый клиент,
успевший отротировать refresh на новом сервере, предъявляет старой базе токен,
которого она не знает → **401 → разлогин и повторный пейринг**. Это самый дорогой
исход, и его не надо допускать.

### 2.3 Процедура отката (правильная: с переносом данных назад)

```bash
# 1. МЕНЯЕТ (Cloudflare, вручную в дашборде): A api.fatklyuchi.space → 87.121.221.229
#    TTL оставить 60. Проверять распространение:
dig +short api.fatklyuchi.space @1.1.1.1      # ЧИТАЕТ — ждём 87.121.221.229

# 2. МЕНЯЕТ (на НОВОМ сервере): погасить приём записей, снять финальный дамп
cd /opt/fatvpn-bff/backend && docker compose stop bff
docker exec fatvpn-postgres pg_dump -U fatvpn -d fatvpn -Fp \
  | gzip > /root/rollback-$(date +%Y%m%d-%H%M).sql.gz

# 3. МЕНЯЕТ (со СТАРОГО сервера): забрать дамп
scp root@95.85.248.29:/root/rollback-*.sql.gz /root/

# 4. МЕНЯЕТ (на СТАРОМ сервере): остановить прокси-заглушку, залить данные обратно
cd /opt/fatvpn-legacy-proxy && docker compose down
cd /opt/fatvpn-bff/backend && docker compose up -d postgres
docker exec fatvpn-postgres psql -U fatvpn -d postgres \
  -c "DROP DATABASE IF EXISTS fatvpn;" -c "CREATE DATABASE fatvpn OWNER fatvpn;"
gunzip -c /root/rollback-*.sql.gz | docker exec -i fatvpn-postgres psql -U fatvpn -d fatvpn

# 5. МЕНЯЕТ: поднять старый стек целиком (там Caddy на месте и остаётся)
docker compose up -d

# 6. ЧИТАЕТ: проверки
curl -s http://127.0.0.1:5030/health
curl -s https://api.fatklyuchi.space/health
curl -s http://87.121.221.229:5030/health          # путь старых сборок
```

**Быстрый (аварийный) откат**, если новый сервер недоступен и дамп с него не снять:
шаг 1 (вернуть A-запись) + шаг 4-без-восстановления + шаг 5. Цена — разлогин тех, кто
успел отротироваться на новом сервере. Делать только если альтернатива — полный
простой.

Правка 2026-08-06: откат **не требует** трогать nginx и бота на `95.85.248.29` —
платежи и бот там работают независимо от BFF и после отката продолжают работать.
Vhost `api.fatklyuchi.space` можно оставить: без DNS на него никто не придёт.

### 2.4 Что делает откат дешёвым и что его удорожает

- **Дешевле:** TTL 60 с, выставленный **заранее** (§9); старый стек не удалён, тома
  на месте; финальный дамп со старого сервера лежит в двух местах.
- **Дороже с каждым часом:** объём данных, записанных в новую базу. Практическое
  правило — **решение об откате принимается в первые 2 часа**; дальше откат
  превращается в отдельную операцию слияния, которой в этом ранбуке нет.

---

## 3. Шаг 1 — Разведка `95.85.248.29` (только чтение) — ✅ ВЫПОЛНЕНО 2026-08-06

```bash
# ЧИТАЕТ. Ключ установлен, пароль не нужен:
ssh -o BatchMode=yes root@95.85.248.29
```

### 3.1 Результат разведки (2026-08-06, только чтение)

| Что | Факт |
|---|---|
| Доступ | ed25519-ключ установлен, `BatchMode=yes` проходит |
| Хост / ОС | `tiny-williams.1cent.network`, Ubuntu 24.04 |
| Ресурсы | 4 vCPU, 7.8 GiB RAM (свободно ~7 GiB), диск 99 GB (занято 12, свободно 83), uptime 28 дней |
| Docker | 29.5.1, Compose **v5.1.3** — ставить ничего не надо |
| Контейнеры | ровно один: `fatvpn-bot` (образ `fatvpn-bot`, локальная сборка), публикует `0.0.0.0:4444` — **вебхук платежей** |
| Каталог бота | `/opt/FatVPN` (git-репозиторий `github.com/pose1don113/fatvpn-bot`) |
| Секреты бота | переменных окружения у контейнера **нет вообще**: `TOKEN`, `PAYMENTS_TOKEN`, `REMNAWAVE_TOKEN`, `LOGIN_DATA` зашиты в `bot/core/config.py` |
| Какой это бот | **боевой `@Fat_VPN_bot`** — его токен совпадает с токеном бота, которым уходят бэкапы в Telegram |
| BFF / Postgres / Caddy | **отсутствуют полностью** |
| `/opt` | `containerd`, `FatVPN`, `fatvpn-test.tar.gz`, `fatvpn-bff` (клон репозитория, разложен как `repo/` + симлинк `backend → repo/backend`) |
| Порт 80 | **системный nginx 1.24.0 (не в docker)**, `sites-enabled`: `default` + **`pay.fatvnv.space`** |
| `pay.fatvnv.space` | живой платёжный vhost, `listen 80` (TLS **нет**), `proxy_pass http://127.0.0.1:4444`, в `access.log` реальные запросы |
| Порт 443 | **никто не слушает**; снаружи «закрыт» именно поэтому, провайдерского фильтра нет (80 отвечает снаружи) |
| certbot | `certbot 2.9.0` + `python3-certbot-nginx` **уже установлены**; `/etc/letsencrypt/live` не существует — серты никогда не выпускались |
| `ufw` | **Status: inactive** |
| Docker-сети | `bridge` (172.17.0.0/16) и **`fatvpn_default` (172.18.0.0/16) — уже существует**, её создал compose бота (project `fatvpn` из имени каталога `/opt/FatVPN`) |
| Сеть бота | `fatvpn-bot` подключён к `fatvpn_default`, IP 172.18.0.2, алиасы `fatvpn-bot`, `bot` |

Ссылки на этот результат дальше по тексту — «§3.1».

### 3.2 Команды разведки (для повторного прогона)

```bash
# --- всё ниже ЧИТАЕТ ---
hostnamectl; uptime; nproc; free -h; df -h
docker ps -a; docker compose ls; docker network ls
ls -la /opt /root /srv
ss -tlnp
systemctl status nginx --no-pager
ls -la /etc/nginx/sites-enabled/
ufw status verbose 2>/dev/null || iptables -S | head -40
crontab -l; ls -la /etc/cron.d/; systemctl list-timers --all
```

---

## 4. Шаг 2 — Подготовка нового сервера

**Правка 2026-08-06.** Подготовка стала короче: docker уже стоит, сеть уже есть,
nginx не гасим. Осталось: связность до панели, репозиторий, `.env`, override.

### 4.1 nginx остаётся владельцем 80/443 — ⛔ НЕ ГАСИТЬ

Прежняя редакция требовала `systemctl disable --now nginx`. **Эта команда запрещена:**
на 80 висит `pay.fatvnv.space`, через который принимаются платежи (§3.1). Погасив
nginx, мы обрываем приём денег и узнаем об этом от заказчика.

Схема после правки:

```
клиент ──443/TLS──► nginx (хост, vhost api.fatklyuchi.space) ──http──► 127.0.0.1:5030 ──► контейнер fatvpn-bff
клиент ──80───────► nginx (хост, vhost pay.fatvnv.space)     ──http──► 127.0.0.1:4444 ──► контейнер fatvpn-bot
```

Единственная проверка на этом шаге:

```bash
# ЧИТАЕТ — 80 занят nginx, 443 свободен, 4444 держит docker-proxy бота
ss -tlnp | grep -E ':80|:443|:4444'
nginx -t && nginx -v          # конфиг валиден, версия 1.24.x
```

### 4.2 Фаервол — на этом шаге НЕ включаем

`ufw` на сервере **выключен** (§3.1), и включать его здесь нельзя: правила надо
писать вместе с портом **4444**, иначе включение оборвёт платёжный вебхук. Включение
вынесено в отдельный шаг **после** переезда — §13a.

⚠️ Docker публикует порты **в обход ufw**. Поэтому единственная реальная защита
порта `5030` — бинд на `127.0.0.1`, он в §4.5 и он обязателен: наружу plain-HTTP API
на новом адресе не нужен, старые сборки приходят через прокси на старом IP (§12).

### 4.3 Docker — уже установлен, только проверить

```bash
# ЧИТАЕТ — ожидаем Docker 29.5.1 и Compose v5.1.3 (§3.1)
docker --version && docker compose version
```

Compose v5 ≫ 2.24, так что весь современный синтаксис (`profiles`, `!reset`)
доступен. Ставить docker по инструкции из прежней редакции не нужно.

Заодно — исходящая связность, без неё BFF бесполезен:

```bash
# ЧИТАЕТ
curl -sS -o /dev/null -w 'panel=%{http_code}\n' https://z.fatvdsnvv.space/
curl -sS -o /dev/null -w 'github=%{http_code}\n' https://github.com/
getent hosts api.fatklyuchi.space
```

### 4.4 Репозиторий и секреты

Клон уже есть: `/opt/fatvpn-bff/repo` + симлинк `/opt/fatvpn-bff/backend →
/opt/fatvpn-bff/repo/backend` (§3.1). Раскладка отличается от старого сервера
симлинком, но путь `/opt/fatvpn-bff/backend` резолвится одинаково, поэтому все
команды ранбуков совпадают.

```bash
# ЧИТАЕТ — что именно приехало
cd /opt/fatvpn-bff/repo && git log --oneline -1 && git status --short
# МЕНЯЕТ — если отстал:
git pull
```

`.env` в git нет. Копируем его со старого сервера **как есть, побайтно** — от этого
зависит, переживут ли переезд уже выданные сессии и уже потраченные триалы:

```bash
# МЕНЯЕТ. Выполнять с рабочей машины (или со старого сервера).
scp root@87.121.221.229:/opt/fatvpn-bff/backend/.env /tmp/fatvpn.env
scp /tmp/fatvpn.env root@95.85.248.29:/opt/fatvpn-bff/backend/.env
shred -u /tmp/fatvpn.env
```

Проверка идентичности **без вывода значений** — на обоих серверах одна и та же
команда, хеши обязаны совпасть:

```bash
# ЧИТАЕТ (выполнить и на 87.121.221.229, и на 95.85.248.29)
grep -E '^(JWT_SECRET|BOT_SECRET|REMNAWAVE_API_TOKEN|TRIAL_DEVICE_KEY_SALT|POSTGRES_PASSWORD)=' \
  /opt/fatvpn-bff/backend/.env | sort | sha256sum
# И отдельно — имена всех переменных, чтобы увидеть, не потерялась ли какая-то:
grep -o '^[A-Z_0-9]*' /opt/fatvpn-bff/backend/.env | sort
```

Почему это критично:

| Переменная | Что сломается, если она другая |
|---|---|
| `JWT_SECRET` | **все** выданные access-токены становятся невалидны → 401 у всех до следующего refresh, а refresh тоже пойдёт через новый секрет |
| `TRIAL_DEVICE_KEY_SALT` | хеши 77 устройств с потраченным триалом перестают совпадать → **все получают триал заново** |
| `BOT_SECRET` | бот получает 401 на `/internal/*` → пейринг и выдача ключей мертвы |
| `REMNAWAVE_API_TOKEN` | `/config` и `/servers` отвечают 502 |
| `POSTGRES_PASSWORD` | новая база создастся с этим паролем, BFF подключится — но при откате/восстановлении пароли разойдутся |

### 4.5 Локальный override для нового сервера

Compose из репозитория трогать нельзя: он под тестом `DeploymentConfigTests` и общий
для обоих серверов. Особенности новой машины кладём в **нетрекаемый**
`docker-compose.override.yml`.

```bash
# МЕНЯЕТ
cat > /opt/fatvpn-bff/backend/docker-compose.override.yml <<'YAML'
# Локальный файл нового сервера 95.85.248.29 (в git его нет и быть не должно).
services:
  bff:
    ports:
      # Наружу plain-HTTP API на новом адресе не нужен: старые сборки приходят
      # через прокси на 87.121.221.229:5030, а он ходит сюда по HTTPS.
      # Docker публикует порты в обход ufw, поэтому бинд — единственная защита.
      # Слушает только localhost, потому что клиент у него один: nginx на хосте.
      - "127.0.0.1:5030:5030"

  caddy:
    # ⛔ На этом сервере Caddy не запускается НИКОГДА: 80 и 443 принадлежат
    # системному nginx, который обслуживает боевой pay.fatvnv.space. Профиль
    # выключает сервис из `docker compose up -d` по умолчанию — так случайная
    # команда без списка сервисов не уведёт 443 у платежей.
    profiles: ["disabled"]
YAML
```

```bash
# ЧИТАЕТ — проверка, что caddy действительно выключен профилем:
cd /opt/fatvpn-bff/backend && docker compose config --services
# ожидаем ровно: postgres, bff  (caddy отсутствовать)
```

Даже с профилем **везде дальше сервисы перечисляются явно**: `docker compose up -d
postgres bff`. Профиль — страховка, а не разрешение писать `up -d` не глядя.

⚠️ **Сеть `fatvpn_default` уже существует** (§3.1, подсеть 172.18.0.0/16). Прежняя
редакция требовала `docker network create fatvpn_default` — **этого делать не надо**,
команда просто упадёт с «already exists». Сеть создал compose бота, у BFF она
объявлена `external: true`, что здесь ровно то, что нужно.

```bash
# ЧИТАЕТ — сеть на месте и бот в ней
docker network inspect fatvpn_default --format '{{json .IPAM.Config}}'
docker inspect fatvpn-bot --format '{{json .NetworkSettings.Networks}}'
```

⚠️ Имя `fatvpn_default` сейчас держится на совпадении: compose бота **не объявляет
сеть явно**, имя выводится из каталога `/opt/FatVPN` → project `fatvpn` → сеть
`fatvpn_default`. Переименуют каталог или зададут `COMPOSE_PROJECT_NAME` — имя
поменяется, и BFF перестанет подниматься («network declared as external, but could
not be found»). Закрепить явно — §13.

---

## 5. Шаг 3 — vhost nginx для `api.fatklyuchi.space` и сертификат

**Переписан 2026-08-06.** Прежняя редакция поднимала Caddy с DNS-01 через
`caddy-dns/cloudflare` и требовала токен Cloudflare. Ничего этого не нужно:
TLS терминирует **тот же системный nginx**, а сертификат берётся HTTP-01 через
установленный `certbot 2.9.0` с плагином nginx. **Открытый вопрос №4 (токен
Cloudflare) закрыт: токен не требуется.**

Ограничение, которое из этого следует и которое надо принять сознательно: HTTP-01
проверяет владение по A-записи, то есть выпустить серт **до** переключения DNS им
нельзя. Поэтому порядок такой: до переключения nginx получает **действующий
сертификат со старого сервера** (он валиден и лежит в томе Caddy), а certbot берёт
продления на себя **сразу после** переключения. Окно, в котором клиенты видят ошибку
TLS, при этом равно нулю.

### 5.1 Статику `/privacy`, `/privacy/ru`, `/support` обязан отдавать этот vhost

Сейчас три страницы отдаёт Caddy из `backend/legal/` (`privacy.html`,
`privacy.ru.html`, `support.html`). Ссылки на них стоят **в листингах магазинов**:
Apple открывает privacy при ревью, Google Play отклоняет листинг с 404 на политике.
Если после переезда эти URL начнут 404-ить, узнаем об этом из отказа в сторе.
Поэтому location-блоки ниже — не украшение, а обязательная часть vhost.

### 5.2 Конфиг vhost целиком

```bash
# МЕНЯЕТ
cat > /etc/nginx/sites-available/api.fatklyuchi.space <<'NGINX'
# api.fatklyuchi.space — BFF FatVPN.
# Хост-nginx владеет 80/443 (на 80 живёт платёжный pay.fatvnv.space), поэтому
# Caddy из backend/docker-compose.yml на этой машине не запускается: его работу
# делает этот файл.

server {
    listen 80;
    listen [::]:80;
    server_name api.fatklyuchi.space;

    # ACME HTTP-01: должен остаться доступным по plain HTTP, иначе certbot
    # не сможет продлить сертификат.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # nginx 1.24: http2 задаётся параметром listen. Директива `http2 on;`
    # появилась только в 1.25.1 и здесь будет ошибкой конфигурации.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name api.fatklyuchi.space;

    # До переключения DNS здесь лежит сертификат, перенесённый со старого
    # сервера (§5.3). После переключения — certbot (§5.4), пути станут:
    #   /etc/letsencrypt/live/api.fatklyuchi.space/{fullchain,privkey}.pem
    ssl_certificate     /etc/ssl/fatvpn/api.fatklyuchi.space.fullchain.pem;
    ssl_certificate_key /etc/ssl/fatvpn/api.fatklyuchi.space.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/api.fatklyuchi.space.access.log;
    error_log  /var/log/nginx/api.fatklyuchi.space.error.log;

    # --- Статика для магазинов ---------------------------------------------
    # Точные совпадения (`location =`) вместо префиксов: префиксный /privacy
    # съел бы /privacy/ru и ответил бы по-английски — ровно та ошибка, ради
    # которой в Caddyfile русский блок стоял первым. С `=` порядок неважен,
    # но оба варианта пути (со слешем и без) обязаны быть перечислены явно,
    # иначе ссылка с хвостовым слешем даст 404.
    # Пути ведут через симлинк /opt/fatvpn-bff/backend → repo/backend, так что
    # `git pull` публикует правку страницы без правки nginx.
    location = /privacy/ru  { alias /opt/fatvpn-bff/backend/legal/privacy.ru.html; default_type text/html; }
    location = /privacy/ru/ { alias /opt/fatvpn-bff/backend/legal/privacy.ru.html; default_type text/html; }
    location = /privacy     { alias /opt/fatvpn-bff/backend/legal/privacy.html;    default_type text/html; }
    location = /privacy/    { alias /opt/fatvpn-bff/backend/legal/privacy.html;    default_type text/html; }
    location = /support     { alias /opt/fatvpn-bff/backend/legal/support.html;    default_type text/html; }
    location = /support/    { alias /opt/fatvpn-bff/backend/legal/support.html;    default_type text/html; }

    # --- API ----------------------------------------------------------------
    location / {
        proxy_pass http://127.0.0.1:5030;
        proxy_http_version 1.1;

        # Host не подменяем: BFF фильтрует его по AllowedHosts, и в списке
        # стоит именно api.fatklyuchi.space. Любая подмена = 400 на всё.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        # Ключ рейт-лимита. Без него все запросы придут от адреса прокси и
        # улягутся в один бакет — см. §7.2.
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 5s;
        proxy_read_timeout    60s;
        client_max_body_size  1m;
    }
}
NGINX

ln -sfn /etc/nginx/sites-available/api.fatklyuchi.space \
        /etc/nginx/sites-enabled/api.fatklyuchi.space
```

```bash
# ЧИТАЕТ — конфиг валиден. Пока сертификата нет, `nginx -t` упадёт на
# отсутствующем файле: сначала §5.3, потом эта проверка.
nginx -t
# ЧИТАЕТ — nginx умеет читать файлы политики (каталог должен быть 0755 по пути)
sudo -u www-data test -r /opt/fatvpn-bff/backend/legal/privacy.html && echo "legal readable"
```

⚠️ Блок на 443 будет **единственным** на этом порту, а значит станет для него
default-сервером: запрос с любым `Host` доедет до BFF и получит **400** от
`AllowedHosts`. Это ожидаемое поведение и оно проверяется пунктом 8 в §7.1.

⚠️ `pay.fatvnv.space` этим файлом не затрагивается: у него свой `server_name` и он
остаётся на 80 без TLS, как и был. Проверить после каждого `reload`.

### 5.3 До переключения DNS — перенести действующий сертификат со старого сервера

Старый сервер владеет валидным сертификатом Let's Encrypt для того же имени. Файл
Caddy `.crt` — это уже полная цепочка, ровно то, что нужно `ssl_certificate`.

```bash
# ЧИТАЕТ (на 87.121.221.229) — имя тома и путь внутри него
docker volume ls | grep caddy                      # ожидаем backend_caddy-data
docker exec fatvpn-caddy sh -c 'find /data -path "*api.fatklyuchi.space*" -name "*.crt" -o -path "*api.fatklyuchi.space*" -name "*.key"'

# МЕНЯЕТ (на 87.121.221.229) — вынуть пару в файлы
docker exec fatvpn-caddy sh -c 'cat /data/caddy/certificates/*/api.fatklyuchi.space/api.fatklyuchi.space.crt' > /root/api.fullchain.pem
docker exec fatvpn-caddy sh -c 'cat /data/caddy/certificates/*/api.fatklyuchi.space/api.fatklyuchi.space.key' > /root/api.key
chmod 600 /root/api.key
```

```bash
# МЕНЯЕТ (на 95.85.248.29)
mkdir -p /etc/ssl/fatvpn && chmod 700 /etc/ssl/fatvpn
scp root@87.121.221.229:/root/api.fullchain.pem /etc/ssl/fatvpn/api.fatklyuchi.space.fullchain.pem
scp root@87.121.221.229:/root/api.key           /etc/ssl/fatvpn/api.fatklyuchi.space.key
chmod 600 /etc/ssl/fatvpn/api.fatklyuchi.space.key

# ЧИТАЕТ — издатель обязан содержать Let's Encrypt, notAfter в будущем,
# а модуль ключа обязан совпасть с сертификатом (иначе nginx не стартует)
openssl x509 -in /etc/ssl/fatvpn/api.fatklyuchi.space.fullchain.pem -noout -issuer -subject -dates
diff <(openssl x509 -in /etc/ssl/fatvpn/api.fatklyuchi.space.fullchain.pem -noout -modulus) \
     <(openssl rsa  -in /etc/ssl/fatvpn/api.fatklyuchi.space.key -noout -modulus) 2>/dev/null \
  || openssl ec -in /etc/ssl/fatvpn/api.fatklyuchi.space.key -noout -text | head -3

# МЕНЯЕТ — применить
nginx -t && systemctl reload nginx
ss -tlnp | grep ':443'          # ЧИТАЕТ — теперь слушает nginx
```

⛔ **Издатель обязан быть Let's Encrypt (ISRG).** Приложение пинит только четыре
корня ISRG (`app/lib/config/ca_pins.dart`); ZeroSSL, origin-серт Cloudflare или
самоподписанный выключают **все** установленные сборки, а починка — релиз в сторах.

⚠️ Пока действует старый сертификат, **старый сервер не должен его перевыпустить**
под себя (он и не будет: Caddy продлевает за 30 дней до конца). После переключения
DNS старый сервер продлить его уже не сможет — этим и займётся §5.4.

### 5.4 Сразу после переключения DNS — certbot забирает продления себе

Выполняется **после** §11, когда `api.fatklyuchi.space` уже указывает на новый сервер.

```bash
# ЧИТАЕТ — имя действительно указывает сюда
getent hosts api.fatklyuchi.space
curl -s -o /dev/null -w '%{http_code}\n' http://api.fatklyuchi.space/.well-known/acme-challenge/probe   # 404 от nginx — путь жив

# МЕНЯЕТ — только выпуск, БЕЗ правки нашего vhost.
# `certonly` вместо `--nginx`-инсталлятора: иначе certbot перепишет server-блок
# по-своему и потеряет location-блоки со статикой.
certbot certonly --nginx -d api.fatklyuchi.space \
  --agree-tos -m <e-mail владельца> --no-eff-email \
  --deploy-hook "systemctl reload nginx"

# МЕНЯЕТ — перевести vhost на пути certbot
sed -i 's#/etc/ssl/fatvpn/api.fatklyuchi.space.fullchain.pem#/etc/letsencrypt/live/api.fatklyuchi.space/fullchain.pem#; \
        s#/etc/ssl/fatvpn/api.fatklyuchi.space.key#/etc/letsencrypt/live/api.fatklyuchi.space/privkey.pem#' \
  /etc/nginx/sites-available/api.fatklyuchi.space
nginx -t && systemctl reload nginx

# ЧИТАЕТ — сухой прогон продления и таймер
certbot renew --dry-run
systemctl list-timers certbot.timer --all
```

⚠️ `certbot certonly --nginx` на время проверки сам поднимает временный
location — платёжный vhost при этом не трогается. Если по какой-то причине плагин
nginx откажет, запасной путь: `certbot certonly --webroot -w /var/www/html -d
api.fatklyuchi.space` — блок `^~ /.well-known/acme-challenge/` в §5.2 написан
именно под него.

⚠️ После успешного выпуска **удалить** перенесённую пару из `/etc/ssl/fatvpn/`
(там лежит приватный ключ, который больше не используется), но **не раньше**, чем
`nginx -t` пройдёт на новых путях.

---

## 6. Шаг 4 — Репетиция переноса базы (старый сервер не останавливаем)

Цель репетиции — доказать, что дамп разворачивается и что стек на новом сервере
работает **до** того, как кто-то что-то остановит. Данные этой репетиции потом
затираются финальным дампом, поэтому в них можно спокойно писать тестовые записи.

### 6.1 Снять счётчики строк на старом сервере

```bash
# ЧИТАЕТ (на 87.121.221.229) — точные count(*) по всем таблицам одной командой
docker exec fatvpn-postgres psql -U fatvpn -d fatvpn -Atc "
SELECT table_name || '=' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema='public' AND table_type='BASE TABLE'
ORDER BY table_name;" | tee /root/rows-old-rehearsal.txt
```

Ожидаемые таблицы (из `FatVpnDbContext`): `Accounts`, `Devices`, `PairingCodes`,
`RefreshTokens`, `TokenDevices`, `Tokens`, `Trials`, `TrialSubscriptionSlots`,
плюс `__EFMigrationsHistory`.

### 6.2 Снять дамп

```bash
# ЧИТАЕТ (pg_dump не меняет базу) — на 87.121.221.229
docker exec fatvpn-postgres pg_dump -U fatvpn -d fatvpn -Fp \
  | gzip > /root/fatvpn-rehearsal-$(date +%Y%m%d-%H%M).sql.gz
ls -lh /root/fatvpn-rehearsal-*.sql.gz
sha256sum /root/fatvpn-rehearsal-*.sql.gz
```

```bash
# МЕНЯЕТ (создаёт файл на новом сервере) — забрать дамп
scp root@87.121.221.229:/root/fatvpn-rehearsal-*.sql.gz /root/
sha256sum /root/fatvpn-rehearsal-*.sql.gz    # ЧИТАЕТ — сверить с исходным
```

### 6.3 Развернуть на новом сервере

```bash
# МЕНЯЕТ — поднимаем ТОЛЬКО базу; bff трогать рано (он на старте гонит миграции)
cd /opt/fatvpn-bff/backend
docker compose up -d postgres
sleep 5
docker exec fatvpn-postgres pg_isready -U fatvpn     # ЧИТАЕТ

# МЕНЯЕТ — залить дамп в пустую базу
gunzip -c /root/fatvpn-rehearsal-*.sql.gz \
  | docker exec -i fatvpn-postgres psql -U fatvpn -d fatvpn -v ON_ERROR_STOP=1
echo "exit=$?"     # 0 обязателен; любая ошибка — разбираться, а не идти дальше
```

### 6.4 Сверить строки

```bash
# ЧИТАЕТ (на 95.85.248.29) — та же команда, что в 6.1
docker exec fatvpn-postgres psql -U fatvpn -d fatvpn -Atc "
SELECT table_name || '=' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema='public' AND table_type='BASE TABLE'
ORDER BY table_name;" | tee /root/rows-new-rehearsal.txt

# Сравнение — со старого сервера или с рабочей машины:
diff <(ssh root@87.121.221.229 cat /root/rows-old-rehearsal.txt) /root/rows-new-rehearsal.txt \
  && echo "СТРОКИ СОВПАЛИ"
```

Ориентиры владельца на момент составления ранбука: ~147 ключей, ~886 сессий,
~77 устройств с триалом. Это **ориентир, а не критерий** — критерий один: `diff`
пустой. Строки в старой базе продолжают появляться (30–250 сессий/день), поэтому
на репетиции допустим расход в новых строках, если дамп снимался не одномоментно
со счётчиком; на финальном переносе (§10) расхождение недопустимо, потому что там
BFF уже остановлен.

### 6.5 Поднять стек

```bash
# МЕНЯЕТ. ⛔ Сервисы перечисляются ЯВНО: `up -d` без списка не должен пытаться
# поднять caddy (он выключен профилем в §4.5, но привычка важнее профиля).
cd /opt/fatvpn-bff/backend
docker compose up -d --build postgres bff
docker ps                          # ЧИТАЕТ — два Up, ни одного Restarting,
                                   # fatvpn-caddy отсутствует, fatvpn-bot цел
docker logs fatvpn-bff --tail 40   # ЧИТАЕТ — нет FATAL про секреты;
                                   # "Hosting environment: Production";
                                   # миграции — no-op
ss -tlnp | grep 5030               # ЧИТАЕТ — ТОЛЬКО 127.0.0.1:5030, не 0.0.0.0
```

Если контейнер в `Restarting` — почти наверняка не хватает переменной из §4.4;
валидация на старте называет, какой именно.

```bash
# ЧИТАЕТ — nginx достаёт до BFF (это и есть весь путь запроса)
curl -s -H 'Host: api.fatklyuchi.space' http://127.0.0.1:5030/health
curl -sk -H 'Host: api.fatklyuchi.space' https://127.0.0.1/health
```

---

## 7. Шаг 5 — Проверки нового сервера ДО переключения DNS

Ключевой приём: **`curl --resolve`** — заставляет curl идти на новый IP, но
разговаривать с ним как с `api.fatklyuchi.space`. Так проверяются и TLS, и SNI, и
`AllowedHosts`, и маршруты — без единого изменения в DNS.

Именно поэтому новый IP **не нужно** добавлять в `AllowedHosts`: обращение по голому
`95.85.248.29` получило бы 400, а обращение через `--resolve` проходит как домен.
(Если всё же захочется ходить по голому IP — это правка `backend/docker-compose.yml:45`
**и** `backend/tests/FatVpn.Bff.Tests/DeploymentConfigTests.cs`; без второй половины
упадут тесты.)

### 7.1 Чек-лист «что проверить перед переключением»

Каждый пункт — команда и однозначный ожидаемый ответ. Выполнять с рабочей машины.

```bash
NEW=95.85.248.29
R="--resolve api.fatklyuchi.space:443:$NEW"
```

| # | Что проверяем | Команда | Годится только |
|---|---|---|---|
| 1 | Сертификат от Let's Encrypt | `echo \| openssl s_client -connect $NEW:443 -servername api.fatklyuchi.space 2>/dev/null \| openssl x509 -noout -issuer -subject -dates` | `Issuer` содержит `Let's Encrypt`; `Subject`/SAN = `api.fatklyuchi.space`; `notAfter` в будущем |
| 2 | Цепочка ведёт к ISRG (то, что пинит приложение) | `openssl s_client -connect $NEW:443 -servername api.fatklyuchi.space -showcerts </dev/null 2>/dev/null \| grep -E '^\s*[is]:'` | в цепочке присутствует `O = Let's Encrypt`, корень — ISRG. Промежуточный обязан быть: nginx не достраивает цепочку сам, в отличие от Caddy |
| 3 | Живость и БД | `curl -s $R https://api.fatklyuchi.space/health` | ровно `{"status":"ok"}`; `degraded` = не видит базу |
| 4 | Эндпоинт **с телом** (профиль бага 2026-07-28) | `curl -s $R -X POST https://api.fatklyuchi.space/pair/start -H 'Content-Length: 0'` | 200 и JSON с `pairCode` + `pollToken`, **не** 500 |
| 5 | `/auth/token` с мусорным ключом | `curl -s -o /dev/null -w '%{http_code}\n' $R -X POST https://api.fatklyuchi.space/auth/token -H 'Content-Type: application/json' -d '{"shortToken":"smoke-nonexistent","deviceKey":"0123456789abcdef"}'` | `404` (не 500) |
| 6 | `/servers` без токена | `curl -s -o /dev/null -w '%{http_code}\n' $R https://api.fatklyuchi.space/servers` | `401` (не 429 с первого раза — значит лимиты не свалены в один бакет) |
| 7 | `/config` без токена | `curl -s -o /dev/null -w '%{http_code}\n' $R https://api.fatklyuchi.space/config` | `401` |
| 8 | `AllowedHosts` действительно включён | `curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: evil.example' https://$NEW/health -k` | `400`. Блок на 443 единственный и потому default — запрос доедет до BFF и обязан получить 400. Без этой проверки все предыдущие 200 одинаково означают «работает» и «фильтр ни на что не влияет» |
| 9 | Приватность EN | `curl -s -o /dev/null -w '%{http_code} %{content_type}\n' $R https://api.fatklyuchi.space/privacy` | `200 text/html` |
| 10 | Приватность RU (не съедена английским блоком) | `curl -s $R https://api.fatklyuchi.space/privacy/ru \| grep -ci 'конфиденц'` | > 0 |
| 11 | Слеш-варианты не 404 | `for p in /privacy/ /privacy/ru/ /support/; do curl -s -o /dev/null -w "$p %{http_code}\n" $R https://api.fatklyuchi.space$p; done` | все `200` |
| 12 | Support | `curl -s -o /dev/null -w '%{http_code}\n' $R https://api.fatklyuchi.space/support` | `200` |
| 13 | `BOT_SECRET` доехал (неверный секрет) | `curl -s -o /dev/null -w '%{http_code}\n' $R -X POST https://api.fatklyuchi.space/internal/tokens -H 'X-Bot-Secret: wrong' -H 'Content-Type: application/json' -d '{}'` | `401` |
| 14 | `BOT_SECRET` доехал (верный секрет) — **только на репетиции**, пишет строку в базу | `curl -s -o /dev/null -w '%{http_code}\n' $R -X POST https://api.fatklyuchi.space/internal/tokens -H "X-Bot-Secret: $(grep '^BOT_SECRET=' .env \| cut -d= -f2-)" -H 'Content-Type: application/json' -d '{"shortToken":"MIGRATIONSMOKE0000000000000000AA","remnawaveSubscriptionId":"smoke","expiresAt":"2020-01-01T00:00:00Z","telegramUserId":1}'` | `200`/`201`. Строка исчезнет при финальном восстановлении базы |
| 15 | Панель достижима с нового сервера | на сервере: `docker exec fatvpn-bff curl -s -o /dev/null -w '%{http_code}\n' https://z.fatvdsnvv.space/` | не таймаут; иначе `/config` и `/servers` будут 502 |
| 16 | Строки сошлись | `diff rows-old.txt rows-new.txt` | пусто |
| 17 | Секреты идентичны | sha256 из §4.4 на обоих серверах | хеши совпадают |
| 18 | Стек переживает перезагрузку | `reboot`, затем `docker ps` + `systemctl status nginx` | `fatvpn-postgres`, `fatvpn-bff`, `fatvpn-bot` снова `Up` (`restart: unless-stopped`), nginx поднялся, `pay.fatvnv.space` отвечает |
| 19 | **Рейт-лимит видит реальный IP клиента, а не адрес прокси** (2026-08-06) | см. §7.2 | второй IP не получает 429 за компанию с первым |
| 20 | **Платежи не задеты** (2026-08-06) | `curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: pay.fatvnv.space' http://$NEW/` + `docker logs fatvpn-bot --tail 20` | ответ такой же, как до правок nginx; бот жив |

Пункт 18 стоит отдельного упоминания: он ловит «работает, пока никто не перезагружал»
— ровно тот класс отказа, который в этом проекте уже случался с панелью. Пункт 20
добавлен 2026-08-06: каждый `systemctl reload nginx` на этом сервере трогает файл,
рядом с которым идут деньги.

### 7.2 Рейт-лимит и реальный IP клиента

Правка 2026-08-06: схема прокси изменилась, и вместе с ней — этот раздел.

**(а) Новый путь: клиент → nginx (хост) → `127.0.0.1:5030` → контейнер.**
`ReverseProxy__KnownNetworks__0` в `backend/docker-compose.yml` равен `172.16.0.0/12`
и писался под Caddy, стоявший в docker-сети. Теперь прокси стоит **на хосте**, но
запрос всё равно входит в контейнер через docker-proxy, то есть BFF увидит
отправителем шлюз docker-сети (`172.17.0.1` / `172.18.0.1` / шлюз `backend_default`) —
все они внутри `172.16.0.0/12`, так что заголовки, скорее всего, будут приняты и
`X-Forwarded-For` развернётся в настоящий адрес клиента. **«Скорее всего» — не
критерий**, поэтому проверка обязательна:

```bash
# ЧИТАЕТ (на 95.85.248.29) — какой адрес BFF увидит отправителем
docker network inspect backend_default --format '{{json .IPAM.Config}}'
docker inspect fatvpn-bff --format '{{json .NetworkSettings.Networks}}'
# все шлюзы обязаны попадать в 172.16.0.0/12
```

Настоящая проверка — **с двух разных публичных IP**. Бакет `/auth/*` — 20 запросов
в минуту, и мусорный ключ безвреден (отвечает 404):

```bash
# ЧИТАЕТ (с рабочей машины) — выбрать бакет до конца
for i in $(seq 1 25); do
  curl -s -o /dev/null -w '%{http_code} ' $R -X POST https://api.fatklyuchi.space/auth/token \
    -H 'Content-Type: application/json' -d '{"shortToken":"rl-probe","deviceKey":"0123456789abcdef"}'
done; echo

# ЧИТАЕТ (сразу же, СО СТАРОГО СЕРВЕРА — другой публичный IP)
ssh root@87.121.221.229 "curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve api.fatklyuchi.space:443:95.85.248.29 \
  -X POST https://api.fatklyuchi.space/auth/token \
  -H 'Content-Type: application/json' -d '{\"shortToken\":\"rl-probe\",\"deviceKey\":\"0123456789abcdef\"}'"
```

Годится только так: первая серия дошла до `429`, а **второй IP получил `404`**.
Если второй IP тоже `429` — BFF партиционирует по адресу прокси, а не по клиенту.
Тогда: добавить в override `ReverseProxy__KnownProxies__0` с фактическим адресом
шлюза (или сузить `KnownNetworks` до его подсети) и повторить. Пока проверка не
пройдена, **DNS не переключать**: в этом состоянии первые же 300 запросов в минуту
на весь мир дадут 429 всем.

**(б) Старый путь: старые сборки → прокси на 87.121.221.229:5030 → сюда.**
Для BFF источником всех этих запросов будет один адрес — `87.121.221.229`.
`ForwardedHeadersOptions.ForwardLimit` в `backend/src/FatVpn.Bff.Api/Program.cs`
(секция `Configure<ForwardedHeadersOptions>`) не задан, то есть равен 1: разбирается
только один хоп (nginx нового сервера), и цепочка `X-Forwarded-For` дальше не
раскручивается. Следствие: **все пользователи старых сборок попадают в один per-IP
бакет** (`RateLimiting:GlobalPerMinute`, 300/мин).

Варианты:
- **Ничего не делать и наблюдать** — считать 429 в логах BFF (§15). Если старых
  сборок мало, порог не достигается.
- **Поднять порог** только для переходного периода: добавить в override
  `RateLimiting__GlobalPerMinute: "3000"`. Дёшево, но ослабляет защиту для всех.
- **Правка кода** (аккуратный вариант): сделать `ForwardLimit` настраиваемым и
  добавить `87.121.221.229` в `ReverseProxy:KnownProxies`. Это сборка и деплой —
  делать **до** переезда, не во время.

Решение зафиксировать здесь до начала работ (§17, вопрос 1).

---

## 8. Шаг 6 — Бэкап на старом сервере непосредственно перед окном

```bash
# ЧИТАЕТ/МЕНЯЕТ (создаёт файл) — на 87.121.221.229 прогнать штатный бэкап руками,
# чтобы иметь свежую точку восстановления, не зависящую от расписания cron :17
/opt/fatvpn-ops/backup_bff.sh
ls -lht /opt/fatvpn-backups | head       # ЧИТАЕТ
```

Копию последнего архива забрать на рабочую машину — это страховка на случай, если
что-то пойдёт не так с обоими серверами одновременно.

---

## 9. Шаг 7 — TTL 60 секунд заранее

Делать **минимум за сутки** до переезда (старый TTL должен успеть истечь у
резолверов, иначе новое значение до них не доедет вовремя).

1. Cloudflare → зона `fatklyuchi.space` → DNS → запись `api`.
2. TTL: `Auto` → **60 seconds**. `# МЕНЯЕТ`
3. Proxy status — **DNS only (серое облако)**, не трогать. Оранжевое облако убивает
   VLESS и Hysteria2 и уже один раз клало ноды.
4. Значение A-записи пока **не менять**.

```bash
# ЧИТАЕТ — убедиться, что TTL действительно 60 и адрес прежний
dig api.fatklyuchi.space @1.1.1.1 | grep -E '^api'
dig api.fatklyuchi.space @8.8.8.8 | grep -E '^api'
```

---

## 10. Шаг 8 — Окно переезда: финальный перенос базы

С этого момента идёт простой. Ориентир для базы такого размера — **5–10 минут**.

```bash
# --- на 87.121.221.229 ---

# 10.1 МЕНЯЕТ: остановить приём записей. Postgres оставляем живым.
cd /opt/fatvpn-bff/backend && docker compose stop bff
docker ps --filter name=fatvpn-bff        # ЧИТАЕТ — Exited

# 10.2 ЧИТАЕТ: счётчики финальные (база уже не меняется)
docker exec fatvpn-postgres psql -U fatvpn -d fatvpn -Atc "
SELECT table_name || '=' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema='public' AND table_type='BASE TABLE'
ORDER BY table_name;" > /root/rows-old-final.txt
cat /root/rows-old-final.txt

# 10.3 ЧИТАЕТ (создаёт файл): финальный дамп
docker exec fatvpn-postgres pg_dump -U fatvpn -d fatvpn -Fp \
  | gzip > /root/fatvpn-final.sql.gz
sha256sum /root/fatvpn-final.sql.gz
```

```bash
# --- на 95.85.248.29 ---

# 10.4 МЕНЯЕТ: забрать дамп и сверить хеш
scp root@87.121.221.229:/root/fatvpn-final.sql.gz /root/
scp root@87.121.221.229:/root/rows-old-final.txt /root/
sha256sum /root/fatvpn-final.sql.gz      # ЧИТАЕТ — сверить с 10.3

# 10.5 МЕНЯЕТ: остановить bff, снести репетиционную базу, залить финальную
cd /opt/fatvpn-bff/backend && docker compose stop bff
docker exec fatvpn-postgres psql -U fatvpn -d postgres \
  -c "DROP DATABASE IF EXISTS fatvpn;" -c "CREATE DATABASE fatvpn OWNER fatvpn;"
gunzip -c /root/fatvpn-final.sql.gz \
  | docker exec -i fatvpn-postgres psql -U fatvpn -d fatvpn -v ON_ERROR_STOP=1
echo "exit=$?"      # обязан быть 0

# 10.6 ЧИТАЕТ: строки обязаны совпасть ТОЧНО — старый bff остановлен, расти нечему
docker exec fatvpn-postgres psql -U fatvpn -d fatvpn -Atc "
SELECT table_name || '=' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema='public' AND table_type='BASE TABLE'
ORDER BY table_name;" > /root/rows-new-final.txt
diff /root/rows-old-final.txt /root/rows-new-final.txt && echo "СТРОКИ СОВПАЛИ — можно дальше"
```

⛔ **Если `diff` не пустой — не переключать DNS.** Разобраться или откатиться
(§2.3, откат на этом шаге ещё бесплатный: достаточно `docker compose start bff` на
старом сервере).

```bash
# 10.7 МЕНЯЕТ: поднять BFF на новом сервере
docker compose up -d bff
docker logs fatvpn-bff --tail 40         # ЧИТАЕТ — миграции no-op, нет FATAL

# 10.8 ЧИТАЕТ: прогнать чек-лист §7.1, пункты 3–12, ещё раз — уже на боевых данных
```

---

## 11. Шаг 9 — ⛔ Переключение DNS (точка невозврата)

1. Cloudflare → `fatklyuchi.space` → DNS → `api` → значение **`95.85.248.29`**.
   Proxy status остаётся **DNS only**, TTL остаётся **60**. `# МЕНЯЕТ`

```bash
# ЧИТАЕТ — ждать, пока публичные резолверы отдадут новый адрес
watch -n 5 'dig +short api.fatklyuchi.space @1.1.1.1; dig +short api.fatklyuchi.space @8.8.8.8'
```

Зафиксировать точное время переключения — от него отсчитываются 2 часа «дешёвого
отката» (§2.4).

**Сразу после того, как резолверы отдали новый адрес — выполнить §5.4** (certbot
забирает продление сертификата на новый сервер). Отложить это «на потом» нельзя:
старый сервер продлить серт больше не может, а до истечения остаётся конечное число
дней.

---

## 12. Шаг 10 — Прокси на старом сервере для старых сборок

**Это не опция.** В сборках, уже стоящих на телефонах, зашит прямой
`http://87.121.221.229:5030`. Погасить старый сервер — значит убить эти установки
навсегда: адрес зашит в бинарник, обновить его может только новый релиз в сторах.

Порт 5030 на старом сервере держит контейнер `fatvpn-bff`, поэтому сначала он
останавливается (уже сделано в 10.1), а на его место встаёт отдельный маленький
стек — отдельный, чтобы не править файлы, лежащие в git.

```bash
# --- на 87.121.221.229 ---

# 12.1 МЕНЯЕТ: освободить порты. Тома НЕ удалять — они нужны для отката.
cd /opt/fatvpn-bff/backend
docker compose stop bff caddy
# postgres можно оставить работающим: он слушает только 127.0.0.1 и держит
# данные, к которым мы вернёмся при откате.

# 12.2 МЕНЯЕТ: прокси-заглушка
mkdir -p /opt/fatvpn-legacy-proxy && cd /opt/fatvpn-legacy-proxy

cat > Caddyfile <<'CADDY'
{
	# Ни одного имени, для которого нужен серт: 5030 — plain HTTP.
	auto_https off
}

# Единственный смысл этого сервера после переезда: старые сборки.
:5030 {
	reverse_proxy https://95.85.248.29 {
		# BFF на той стороне фильтрует Host по AllowedHosts. Домен в списке есть,
		# и он же нужен для SNI, иначе сертификат не сойдётся.
		header_up Host api.fatklyuchi.space
		transport http {
			tls
			tls_server_name api.fatklyuchi.space
		}
	}
}
CADDY

cat > docker-compose.yml <<'YAML'
services:
  legacy-proxy:
    image: caddy:2-alpine
    container_name: fatvpn-legacy-proxy
    restart: unless-stopped
    ports:
      - "5030:5030"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
YAML

docker compose up -d
docker logs fatvpn-legacy-proxy --tail 20     # ЧИТАЕТ
```

```bash
# 12.3 ЧИТАЕТ — путь старой сборки должен работать сквозь прокси
curl -s http://87.121.221.229:5030/health
curl -s -X POST http://87.121.221.229:5030/pair/start -H 'Content-Length: 0' | head -c 200; echo
```

Правка 2026-08-06: на принимающей стороне этот трафик приходит на **nginx** нового
сервера, а не на Caddy. Ничего дополнительно настраивать не надо — `Host` подменён
на домен, SNI задан, vhost §5.2 его принимает. Единственное следствие — рейт-лимит,
см. §7.2(б).

### 12.4 Опционально, на первый час — 443 для застрявших резолверов

Пока не истёк TTL (и у резолверов, которые его не уважают), часть клиентов ещё
стучится на `87.121.221.229:443` по имени `api.fatklyuchi.space`. Чтобы они не
получили ошибку, тот же прокси можно поднять и на 443 — сертификат у старого сервера
ещё валиден и лежит в томе Caddy.

```bash
# ЧИТАЕТ — имя тома
docker volume ls | grep caddy

# МЕНЯЕТ — добавить в /opt/fatvpn-legacy-proxy/docker-compose.yml портам "443:443"
# и подключить существующий том:
#   volumes:
#     - ./Caddyfile:/etc/caddy/Caddyfile:ro
#     - caddy-data:/data
#   ...
#   volumes:
#     caddy-data:
#       external: true
#       name: backend_caddy-data      # имя из команды выше
#
# и в Caddyfile снять `auto_https off`, добавив блок:
#   api.fatklyuchi.space {
#       reverse_proxy https://95.85.248.29 {
#           header_up Host api.fatklyuchi.space
#           transport http { tls tls_server_name api.fatklyuchi.space }
#       }
#   }
```

⚠️ Двум процессам Caddy нельзя одновременно писать в один и тот же `/data` — старый
compose-стек к этому моменту должен быть остановлен (12.1). И помнить: продлевать
этот серт по HTTP-01 старый сервер больше не сможет (DNS уводит запрос на новый
адрес), так что блок 443 живёт до истечения серта и снимается раньше — через
неделю-две, когда стало ясно, что застрявших резолверов не осталось.

---

## 13. Шаг 11 — Бот

**Переписан 2026-08-06.** Прежняя редакция исходила из «бот и BFF окажутся на разных
машинах» и требовала перевести бота на `https://api.fatklyuchi.space`. Разведка
показала обратное.

### 13.1 Что есть на самом деле

| | Тестовый бот | Боевой бот |
|---|---|---|
| Кто | `@testfatvpnnbot` | **`@Fat_VPN_bot`** |
| Где | `87.121.221.229`, `/opt/FatVPN` | **`95.85.248.29`**, `/opt/FatVPN` |
| Интеграция с приложением | **есть** | **отсутствует целиком** |
| Секреты | в окружении/`.env` | **зашиты в `bot/core/config.py`**, переменных окружения у контейнера нет |

Сравнение исходников (2026-08-06) показало: в боевом боте **нет двух файлов целиком** —
`bot/api/fatvpn_bff_api.py` (клиент BFF; там же захардкожен `BOT_SECRET` как fallback
и `BFF_URL = "http://fatvpn-bff:5030"`) и `bot/services/pairing_state.py` — и не
хватает вставок в пяти файлах: `main_refactored.py` (297 различающихся строк),
`handlers/trial_handler.py` (279), `handlers/key_handlers.py` (99),
`database/db_remnawave.py` (62), `handlers/callback_handlers.py` (58),
`core/config.py` (6).

⛔ **Коды разошлись В ОБЕ СТОРОНЫ.** В боевом боте есть функциональность, которой нет
в тестовом: реферальные коды (`main_refactored.py`), выдача ссылки на подписку в
сообщениях (`callback_handlers.py`, `key_handlers.py`). Поэтому **«скопировать файлы
из тестового поверх боевого» = уничтожить боевую функциональность**, включая приём
рефералов. Перенос обязан быть **хирургическим**: по документу
`docs/bot-prod-migration-brief.md` — там контракт из трёх вызовов BFF и чек-лист
приёмки из 11 пунктов. Здесь он не дублируется намеренно: две копии контракта
разойдутся так же, как разошлись два бота.

⚠️ **В `/opt/FatVPN` лежат два дерева кода.** Исполняется только подкаталог `bot/`
(`Dockerfile`: `COPY bot/ ./bot/`, `WORKDIR /app/bot`, `CMD python main_refactored.py`).
В корне каталога лежит **устаревший дубликат**: `core/`, `handlers/`, `database/`,
`services/`, `main_refactored.py`, `db.db` (2.2 MB). Правка не того файла проходит
молча: контейнер пересоберётся, поведение не изменится, и полдня уйдёт на «почему
не работает». Перед каждой правкой — проверять путь:

```bash
# ЧИТАЕТ — какой файл реально исполняется
docker exec fatvpn-bot sh -c 'pwd && ls -la /app/bot/main_refactored.py'
md5sum /opt/FatVPN/bot/main_refactored.py /opt/FatVPN/main_refactored.py
```

### 13.2 Адрес BFF для боевого бота править НЕ нужно

Бот и BFF окажутся на одной машине и в одной docker-сети `fatvpn_default`
(172.18.0.0/16, §3.1), поэтому `BFF_URL = "http://fatvpn-bff:5030"` из брифа
работает как есть. Публиковать BFF наружу для бота не требуется — этим и оправдан
бинд `127.0.0.1:5030` из §4.5.

### 13.3 Что обязательно добавить в compose бота

Сейчас `/opt/FatVPN/docker-compose.yml` выглядит так (полностью):

```yaml
version: '3'
services:
  bot:
    build: .
    container_name: fatvpn-bot
    restart: unless-stopped
    volumes:
      - ./bot/db.db:/app/bot/db.db
    ports:
      - "4444:4444"
```

Сети **не объявлены вообще**. Имя `fatvpn_default` возникает случайно: compose берёт
имя проекта из каталога (`/opt/FatVPN` → `fatvpn`) и называет свою сеть по умолчанию
`fatvpn_default`. Это совпадение, на которое у BFF стоит `external: true`. Переименуют
каталог, зададут `COMPOSE_PROJECT_NAME`, поднимут бота из другого пути — имя сети
изменится, и BFF перестанет стартовать вовсе.

```bash
# МЕНЯЕТ (на 95.85.248.29) — закрепить имя сети явно
cp /opt/FatVPN/docker-compose.yml /opt/FatVPN/docker-compose.yml.pre-migration
```

Дописать в конец файла (и заодно убрать устаревший `version: '3'` — compose v5 его
игнорирует с предупреждением):

```yaml
networks:
  default:
    name: fatvpn_default
```

```bash
# МЕНЯЕТ — применить БЕЗ пересборки образа
cd /opt/FatVPN && docker compose up -d
# ЧИТАЕТ — сеть та же самая, бот в ней, контейнер не пересоздан впустую
docker network inspect fatvpn_default --format '{{json .IPAM.Config}}'
docker inspect fatvpn-bot --format '{{json .NetworkSettings.Networks}}'
docker logs fatvpn-bot --tail 30
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: pay.fatvnv.space' http://127.0.0.1/   # платежи живы
```

⚠️ Порядок подъёма: сеть создаёт compose бота, у BFF она `external`. Значит бот
поднимается **первым**. И `docker compose down` в `/opt/FatVPN` при живом BFF выдаст
предупреждение «network in use» — это ожидаемо и безвредно, сеть не удалится.

### 13.4 Тестовый бот на старом сервере

После переезда `@testfatvpnnbot` теряет `fatvpn-bff` в общей сети (контейнер там
остановлен). Варианты: перевести его `BFF_URL` на `https://api.fatklyuchi.space`
(код бота читает адрес из окружения: `os.environ.get("BFF_URL", "http://fatvpn-bff:5030")`)
или сознательно оставить его нерабочим до переноса. Решение — владельца; на боевых
пользователей это не влияет.

**`AllowedHosts` не трогаем**: `fatvpn-bff` в списке остаётся и теперь снова
используется — уже боевым ботом. Удаление имени прибито тестом `DeploymentConfigTests`.

---

## 13a. Шаг 12 — Фаервол: включить `ufw` (новый шаг, 2026-08-06)

Выполняется **после** того, как переезд отработал и §7.1 прошёл на боевых данных.
Раньше — нельзя: правила надо писать сразу с платёжным портом.

На `95.85.248.29` `ufw` **выключен** (`Status: inactive`), в отличие от старого
сервера. Включать его надо аккуратно: сервер держит деньги.

```bash
# ЧИТАЕТ — что сейчас
ufw status verbose
ss -tlnp | grep -E ':22|:80|:443|:4444'

# МЕНЯЕТ — правила ДО включения. 22 первым: заперев себя, чинить будет нечем.
ufw allow 22/tcp
ufw allow 80/tcp      # nginx: pay.fatvnv.space + ACME HTTP-01
ufw allow 443/tcp     # nginx: api.fatklyuchi.space
ufw allow 4444/tcp    # ⛔ ПЛАТЁЖНЫЙ ВЕБХУК. Забыть = оборвать приём платежей.
ufw --force enable
ufw status verbose    # ЧИТАЕТ — четыре правила, ничего лишнего
```

Две честные оговорки:

1. **`ufw` не фильтрует docker-опубликованные порты** — они прошиваются в `DOCKER`
   цепочку iptables мимо правил `ufw`. Порт `4444` опубликован именно докером, то
   есть он остался бы доступен и без правила выше. Правило написано всё равно: чтобы
   намерение было зафиксировано и чтобы будущий переезд вебхука на хостовый процесс
   не убил платежи молча.
2. Из той же особенности следует, что **`ufw` не защищает `5030`**. Единственная
   защита этого порта — бинд `127.0.0.1` из §4.5. Проверить после включения:

```bash
# ЧИТАЕТ — с рабочей машины. Ожидаем отказ/таймаут, НЕ ответ BFF.
nc -vz 95.85.248.29 5030
nc -vz 95.85.248.29 5433     # Postgres — тоже обязан быть недоступен
nc -vz 95.85.248.29 4444     # а этот — доступен, так и задумано
```

После включения — обязательно **не закрывая текущую SSH-сессию** открыть вторую и
убедиться, что вход работает; и прогнать пункт 20 из §7.1.

---

## 14. Шаг 13 — Бэкапы и сторожа: перенастроить на новый адрес

Бэкап, оставшийся смотреть на старый сервер, — это не «бэкап с задержкой», а
**отсутствие бэкапа при полной видимости зелёного статуса**. Перенести обязательно
в тот же день.

| Файл | Где сейчас | Что сделать |
|---|---|---|
| `/opt/fatvpn-ops/backup_bff.sh` | 87.121.221.229 | скопировать на 95.85.248.29 (тот же путь), проверить пути к контейнеру/каталогу, cron `:17`; на старом сервере — **выключить** (базу он больше не бэкапит, а мусор в TG создаёт) |
| `/opt/fatvpn-backups/` | 87.121.221.229 | каталог назначения создать на новом сервере; старые архивы оставить на месте минимум на неделю. Место есть: свободно 83 GB (§3.1) |
| `/opt/fatvpn-ops/check_panel_backup.sh` | 87.121.221.229 | перенести на новый сервер вместе с cron `:43` и SSH-ключом до `95.85.248.65` |
| `/opt/remnawave/check_bff_backup.sh` | **сервер панели** 95.85.248.65 | внутри зашит хост `87.121.221.229` — **заменить на `95.85.248.29`**; порог 2 ч; cron `:50` |
| SSH-ключи крест-накрест | оба сервера | завести пару 95.85.248.29 ↔ 95.85.248.65; ключ рабочей машины на новый сервер **уже стоит** (§3.1) |
| `docs/panel-backup-audit-runbook.md` | репозиторий | обновить таблицу «Развёрнуто по итогам аудита»: адрес BFF-сервера в строках про `backup_bff.sh`, `check_bff_backup.sh`, `check_panel_backup.sh` |

⚠️ Новое с 2026-08-06: на `95.85.248.29` бэкапы BFF будут соседствовать с боевым
ботом. Проверить, что `backup_bff.sh` не конфликтует по имени контейнера и по
Telegram-топику с тем, что уже шлёт бот, и что cron root на этой машине не пустой
(на момент разведки — пустой, чужих задач нет).

```bash
# ЧИТАЕТ — где именно зашит старый адрес (выполнить на обоих серверах)
grep -rn '87\.121\.221\.229' /opt/fatvpn-ops /opt/remnawave /etc/cron.d 2>/dev/null
crontab -l
```

Проверка, что перенос состоялся: прогнать каждый скрипт руками (`exit 0`), убедиться,
что архив создан и что тестовый алерт доехал в Telegram-топик.

Обновить в репозитории также:
- `CLAUDE.md`, раздел **Production Server** — таблица компонентов и IP; там же
  появляется факт «BFF и боевой бот на одной машине, TLS терминирует nginx, а не Caddy»;
- `docs/api-contract.md` — упоминания `87.121.221.229` (адрес остаётся как
  прокси-адрес старых сборок, но перестаёт быть адресом BFF);
- `docs/panel-ha-failover-plan.md` §0.1/§0.2/§11 — там `87.121.221.229` назван сервером
  BFF, а `95.85.248.29` — сервером без названной роли.

---

## 15. Шаг 14 — Наблюдение

Первые 2 часа (окно дешёвого отката), затем сутки, затем неделя.

```bash
# ЧИТАЕТ — на 95.85.248.29
docker logs fatvpn-bff --since 15m 2>&1 | grep -Ei 'error|fatal|exception|502|429' | tail -40
tail -100 /var/log/nginx/api.fatklyuchi.space.error.log
awk '{print $9}' /var/log/nginx/api.fatklyuchi.space.access.log | sort | uniq -c | sort -rn | head
docker stats --no-stream
df -h

# ЧИТАЕТ — оба пути живы
curl -s https://api.fatklyuchi.space/health
curl -s http://87.121.221.229:5030/health

# ЧИТАЕТ — платежи и бот не задеты
curl -s -o /dev/null -w '%{http_code}\n' http://pay.fatvnv.space/
docker logs fatvpn-bot --since 15m | tail -20

# ЧИТАЕТ — база растёт (значит, записи идут именно сюда)
docker exec fatvpn-postgres psql -U fatvpn -d fatvpn -Atc \
  'SELECT count(*) FROM "RefreshTokens";'
```

За чем следить целенаправленно:

1. **429 в логах** — материализовался ли риск из §7.2(б) (все старые сборки в одном
   бакете), и не сломалась ли передача реального IP из §7.2(а).
2. **502 на `/config` и `/servers`** — новый сервер не достаёт до панели.
3. **Рост `RefreshTokens`** — сверить с ожидаемыми 30–250 сессий в день. Ноль
   означает, что клиенты не пришли, то есть DNS или TLS не сошлись.
4. **Продление сертификата** — `certbot renew --dry-run` уже прогнан в §5.4, но
   первое реальное продление случится через ~60 дней. Поставить напоминание и
   проверить, что `certbot.timer` активен.
5. **`pay.fatvnv.space`** — первые сутки после каждого `systemctl reload nginx`.
6. **Живой пейринг end-to-end** — не curl-ом: в боте нажать «Код для FatVPN App»,
   вставить его в приложение, дойти до списка серверов и подключиться. Это
   единственная проверка, которая покрывает всю цепочку бот → BFF → панель → приложение.
   ⚠️ До хирургического переноса кода по `bot-prod-migration-brief.md` (§13) боевой
   бот этой кнопки не имеет — прогонять на тестовом.

---

## 16. Что НЕ трогаем

- ⛔ **Системный nginx на `95.85.248.29` не гасим и не переписываем** (2026-08-06).
  На нём боевой `pay.fatvnv.space` → `127.0.0.1:4444` → приём платежей. Наш vhost —
  **отдельный файл** в `sites-available`; чужие файлы не редактируются, `nginx -t`
  перед каждым `reload`.
- ⛔ **Порт 4444 не закрываем** — ни правилом `ufw`, ни правкой compose бота.
- ⛔ **Caddy на новом сервере не поднимаем** (2026-08-06). Сервис выключен профилем
  в override (§4.5); `docker compose up -d` всегда со списком сервисов.
- ⛔ **Боевого бота не «обновляем целиком»** (2026-08-06). Тестовый и боевой коды
  разошлись в обе стороны; перенос — только хирургический, по
  `docs/bot-prod-migration-brief.md`.
- ⛔ **Старый сервер `87.121.221.229` не гасим минимум неделю**, а прокси на `:5030`
  — до тех пор, пока не исчезнут сборки, зашитые на этот адрес. Это не «неделя», это
  «пока в сторах не разойдётся новый релиз и старые установки не вымрут». Отдельным
  решением владельца, не по календарю.
- ⛔ **Тома старого сервера не удаляем** (`docker compose down -v` — запрещённая
  команда на 87.121.221.229 до конца наблюдения). В них лежит база, к которой
  возвращает откат.
- ⛔ **Оранжевое облако Cloudflare не включаем никогда** — ни на `api.`, ни на чём
  ещё в зоне: бесплатный прокси не пропускает UDP и нестандартные порты, то есть
  убивает Hysteria2 и VLESS.
- ⛔ **CA не меняем.** Сертификат нового сервера обязан быть от Let's Encrypt (ISRG).
  ZeroSSL, origin-серт Cloudflare, самоподписанный — любой из них выключает **все**
  установленные сборки, и починка это релиз в сторах, то есть дни на iOS.
- ⛔ **`AllowedHosts` не сокращаем.** `87.121.221.229` остаётся в списке — через
  прокси Host подменяется на домен, но подстраховка стоит ноль, а её отсутствие
  даёт 400 на всё. `fatvpn-bff` тем более: по нему теперь ходит боевой бот.
- ⛔ **`Security:RequireHttps` не включаем** — он даст 307 на `https://87.121.221.229:5030`,
  где сертификата нет, то есть убьёт ровно тех, ради кого оставлен прокси.
- ⛔ **`backend/docker-compose.yml` и `backend/Caddyfile` не правим под новый сервер**
  — они общие для обеих машин и под тестом. Всё специфичное для новой машины живёт
  в нетрекаемом `docker-compose.override.yml` и в `/etc/nginx/sites-available/`.
- ⚠️ **Продление серверов у провайдера** — оба оплачены до 16.08.2026
  (`panel-ha-failover-plan.md` §0.2). Переезжать на сервер, который через неделю
  выключат за неуплату, бессмысленно: подтвердить оплату **до** начала работ.

---

## 17. Открытые вопросы

Пять из девяти вопросов прежней редакции закрыты разведкой 2026-08-06 (доступ,
роль сервера, прод-бот, токен Cloudflare, фаервол/443, нужен ли nginx) — см. §1.2.
Осталось:

| # | Вопрос | Что блокирует | Кому |
|---|---|---|---|
| 1 | **Решение по рейт-лимиту** (§7.2): наблюдать / поднять порог / править `ForwardLimit` в коде. Правка кода делается **до** переезда. Отдельно — обязательная проверка §7.2(а): видит ли BFF реальный IP клиента через nginx | §7.2, и §11 не начинать, пока (а) не пройдена | команда |
| 2 | **Окно переезда** — во сколько и кто дежурит первые 2 часа (окно дешёвого отката) | §10–§11 | владелец |
| 3 | **Оплата обоих серверов после 16.08.2026** подтверждена? | всё | владелец |
| 4 | **Ротация секретов бота** (новый, 2026-08-06). В боевом боте `TOKEN`, `PAYMENTS_TOKEN`, `REMNAWAVE_TOKEN`, `LOGIN_DATA` зашиты в `bot/core/config.py` и лежат в git-репозитории бота; в `git remote` того же репозитория прописан **GitHub-токен доступа в открытом виде**. Это не блокирует переезд, но переезд — удобный момент вынести секреты в `.env`/окружение и отозвать засвеченный токен | не блокирует §3–§15 | владелец + команда |

---

## 18. Сводка шагов

| # | Шаг | Меняет состояние | Откат |
|---|---|---|---|
| 1 | Разведка `95.85.248.29` (§3) — ✅ **выполнена 2026-08-06** | нет | — |
| 2 | Подготовка: связность, репозиторий, `.env`, override (nginx и docker уже на месте, сеть уже есть) (§4) | новый сервер | бесплатно |
| 3 | vhost nginx для `api.fatklyuchi.space` + перенос действующего сертификата (§5.1–5.3) | новый сервер | бесплатно |
| 4 | Репетиция переноса базы + сверка строк (§6) | новый сервер | бесплатно |
| 5 | Чек-лист из 20 проверок по `--resolve`, включая реальный IP клиента (§7) | нет | — |
| 6 | Ручной бэкап старого сервера (§8) | файл на старом сервере | — |
| 7 | TTL 60 c, за сутки (§9) | Cloudflare | бесплатно |
| 8 | Окно: стоп bff → финальный дамп → restore → сверка → старт (§10) | оба сервера | «поднять bff обратно» |
| 9 | ⛔ **Переключение A-записи (§11)** | Cloudflare | **точка невозврата** |
| 9a | certbot забирает продление серта себе (§5.4) — выполняется сразу после §11, отдельным шагом не нумеруется, потому что живёт в §5 | новый сервер | бесплатно |
| 10 | Прокси `:5030` на старом сервере (§12) | старый сервер | бесплатно |
| 11 | Бот: сеть в compose + хирургический перенос по брифу (§13) | новый сервер | бесплатно |
| 12 | Включить `ufw` — 22/80/443/**4444** (§13a) | новый сервер | `ufw disable` |
| 13 | Бэкапы и сторожа на новый адрес (§14) | оба сервера + панель | бесплатно |
| 14 | Наблюдение 2 ч / сутки / неделя (§15) | нет | — |

Итого **14 шагов** (было 13). Шаг 1 выполнен. Первое невыполненное действие —
шаг 2 (§4): проверить связность до панели и разложить `.env` с override.
