# Ранбук деплоя BFF (2026-07-29)

> ✅ **Прогнан 2026-08-03** — по нему сервер обновлён с `3b21cac` до `af69690`
> (`git pull` fast-forward, `build --no-cache bff`, `up -d bff`): контейнер поднялся,
> миграции — no-op, в логе `Hosting environment: Production`. Тем же деплоем приехали
> `AllowedHosts` (точный список имён вместо `*`) и потолок 4 МБ на ответ панели.
> ✏️ **Две оговорки ниже устарели.** Компоуз на сервере больше **не** расходится с
> репозиторием — прод-правки закоммичены, локальным остался только `.env`, поэтому
> `git pull` чистый и сверять `git status` на предмет «modified compose» не нужно.
> И номер коммита в шапке — исторический: деплоить всегда текущий `master`.
> ⚠️ Что этот прогон **не** сделал: не тронул `Security:RequireHttps` (он ждёт
> исчезновения сборок, ходящих на `http://87.121.221.229:5030`) и не ротировал пароль
> Postgres. Порядок шагов ниже верен и годится для следующего раза.

Что деплоим: `master` = `54a1e8a` (включает `6eeaa1f` — фикс V17, серверную часть не меняет;
последний коммит, трогающий BFF, — `43e1a8d`/`26dfae4`, фикс 500-х на body-эндпоинтах).
Все команды — на сервере `87.121.221.229` под root. Порядок важен: **сначала проверки env,
потом деплой** — стартовая валидация уронит контейнер в crash-loop, если чего-то нет.

## 0. Перед деплоем: env (N6, N2, N7)

```bash
cd /opt/fatvpn-bff/backend

# N6 — все четыре обязательных секрета должны быть непустыми:
#   TRIAL_DEVICE_KEY_SALT, JWT_SECRET (≥32 байт), BOT_SECRET (≥16), REMNAWAVE_API_TOKEN
grep -E 'TRIAL_DEVICE_KEY_SALT|JWT_SECRET|BOT_SECRET|REMNAWAVE_API_TOKEN' .env | sed 's/=.*/=<есть>/'

# N2 — убрать переопределение, иначе дефолт AugmentHysteria=true не сработает
# и Hysteria2-нод в /config не будет. Проверяем и .env, и compose, и живой контейнер:
grep -n 'AugmentHysteria' .env docker-compose.yml || echo "N2 ok в файлах"
docker inspect fatvpn-bff --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i hysteria || echo "N2 ok в контейнере"
# Если нашлась Remnawave__AugmentHysteria=false — удалить строку из .env/compose.

# Заодно: окружение должно быть Production (SA-2)
docker inspect fatvpn-bff --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ASPNETCORE_ENVIRONMENT
```

⚠️ Помним: `docker-compose.yml` на сервере имеет незакоммиченные прод-правки (Caddy,
публичный `0.0.0.0:5030`, localhost-бинд Postgres, сеть `fatvpn_default`). `git pull` их не
тронет (файл в конфликте не участвует, правки локальные), но **перед pull сверить**:
`git status` — если compose в modified, так и должно быть, не сбрасывать.

## 1. Деплой (N1)

```bash
cd /opt/fatvpn-bff/backend
git fetch && git log --oneline HEAD..origin/master   # глазами: что приедет
git pull
docker compose build --no-cache bff
docker compose up -d bff
```

## 2. Сразу после: контейнер жив, а не в crash-loop

```bash
docker ps --filter name=fatvpn-bff        # STATUS должен быть Up, не Restarting
docker logs fatvpn-bff --tail 30          # нет FATAL про отсутствующие секреты
```

## 3. Smoke (урок деплоя 2026-07-28: «поднялся» ≠ «работает»)

Тогда все body-эндпоинты отвечали 500 при живом /health — поэтому проверяем
**именно эндпоинт с телом запроса**, а не только health:

```bash
# health — ok/degraded (degraded = не видит БД)
curl -s http://127.0.0.1:5030/health

# body-эндпоинт: /pair/start без тела должен ответить 200 с pairCode (не 500!)
curl -s -X POST http://127.0.0.1:5030/pair/start -H 'Content-Length: 0' | head -c 300; echo

# /auth/token с мусорным ключом: ожидаем 404 (не 500)
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:5030/auth/token \
  -H 'Content-Type: application/json' -d '{"shortToken":"smoke-test-nonexistent","deviceKey":"0123456789abcdef"}'

# N7 — rate limit не в одном бакете: /servers без токена = 401 (не 429 с первого раза)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5030/servers

# N2 — Hysteria2 в конфиге: у живого пользователя в /config должны быть hysteria2:// строки.
# Проще проверить из приложения после деплоя (список серверов содержит H2-ноды FR/US/FI).
```

## 4. Бот не отвалился

```bash
docker logs fatvpn-bot --tail 10   # нет ошибок соединения с fatvpn-bff
# Сеть общая на месте:
docker network inspect fatvpn_default --format '{{range .Containers}}{{println .Name}}{{end}}'
```

## 5. Отметить в чек-листе

`docs/release-test-checklist.md` §3: N1 ✅, N2 ✅, N3 ✅ (локально 2026-07-29: 121/121 с Docker),
N6 ✅, N7 ✅ — и дата.

## Если что-то пошло не так

- Контейнер в Restarting → `docker logs fatvpn-bff` — почти наверняка отсутствующий секрет
  (валидация перечисляет, какой именно). Добавить в `.env`, `docker compose up -d bff`.
- 500 на body-эндпоинтах → это профиль бага `26dfae4`; убедиться, что собрался именно
  свежий образ: `docker compose build --no-cache bff` (без кеша!) и пересоздать.
- Откат: `git log` → `git checkout <прежний коммит> -- .` не нужен; проще
  `git reset --hard <прежний коммит> && docker compose build --no-cache bff && docker compose up -d bff`.
