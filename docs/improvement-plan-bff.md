# План доработок — BFF (.NET 10)

> **Назначение документа:** техзадание для исполнителя (Claude Opus). Аудит проведён
> 2026-07-27 по коду `master`. Каждый пункт — самостоятельная задача с местом в коде,
> объяснением и предлагаемым исправлением. Дополняет `docs/security-audit.md`
> (2026-07-25) — пункты оттуда здесь не дублируются, кроме случаев, где аудит нашёл
> новые детали (помечено).
>
> Смежные документы: `docs/improvement-plan-app-android.md`, `docs/improvement-plan-ios.md`.

## Сводка по критичности

| # | Sev | Кат | Проблема | Файл:строка |
|---|-----|-----|----------|-------------|
| B1 | 🔴 critical | БАГ | Race condition в `/pair/status`: «одноразовый» код выдаёт 2+ сессии | `PairController.cs:78-93` |
| B2 | 🔴 critical | БАГ | Race condition в `/auth/refresh`: две сессии из одного refresh, обход reuse-detection | `AuthController.cs:62-113` |
| B3 | 🔴 critical | БАГ | `DateTimeOffset` с ненулевым offset от бота → Npgsql бросает исключение → 500 | `InternalPairController.cs:53`, `InternalAccountController.cs:35`, `InternalTokensController.cs:46` |
| S1 | 🔴 critical | БЕЗОП | Полное отсутствие rate limiting на публичных эндпоинтах | `Program.cs` |
| S2 | 🔴 critical | БЕЗОП | `UseHttpsRedirection()` включён **только** в Development (условие инвертировано) | `Program.cs:61-65` |
| S3 | 🔴 critical | БЕЗОП | Пустой `attestationToken` = общая device-identity → выдача чужой trial-сессии | `TrialController.cs:25` |
| B4 | 🟠 high | БАГ | Утечка юзера в Remnawave при падении `SaveChanges` (нет компенсации) | `TrialController.cs:71-114` |
| B5 | 🟠 high | БАГ | Race в `/trial`: два запроса → нарушение unique-index → 500 | `TrialController.cs:28-88` |
| B6 | 🟠 high | БАГ | TOCTOU в привязке device-key: «один ключ = один телефон» обходится | `AuthController.cs:32-43` |
| B7 | 🟠 high | БАГ | Утечка исключений → 500 вместо 401/502 | `ClaimsPrincipalExtensions.cs:10-18`, `ServersController.cs:35` |
| P1 | 🟠 high | ПРОИЗВ | `/servers` дёргает панель на **каждый** запрос, нет кеша | `ServersController.cs:32` |
| P2 | 🟠 high | ПРОИЗВ | Нет индексов на `RefreshTokens.AccountId/TokenId`, `Trials.DeviceId`; seq scan в `RevokeFamilyAsync` | `FatVpnDbContext.cs:16-25` |
| P3 | 🟠 high | ПРОИЗВ | `RefreshTokens`/`PairingCodes` растут неограниченно, нет очистки | `RefreshTokenService.cs:30`, `PairController.cs:43-53` |
| S4 | 🟠 high | БЕЗОП | Dev-секреты в git + попадают в Docker-образ | `appsettings.Development.json`, `Dockerfile:13` |
| S5 | 🟠 high | БЕЗОП | Нет fail-fast валидации `Jwt:Secret` / `Bot:Secret` на старте | `Program.cs:36-50` |
| P4 | 🟡 medium | ПРОИЗВ | У `HttpClient` не задан `Timeout` (дефолт 100 с) → каскадный отказ при зависании панели | `Program.cs:30-34` |
| B8 | 🟡 medium | БАГ | `subscriptionId` не URL-экранируется → path traversal в панель | `RemnawaveClient.cs:43` |
| B9 | 🟡 medium | БАГ | Форматирование даты с `CurrentCulture` | `RemnawaveClient.cs:59` |
| S6 | 🟡 medium | БЕЗОП | `ClockSkew` по умолчанию 5 мин; алгоритм подписи не ограничен | `Program.cs:40-49` |
| S7 | 🟡 medium | БЕЗОП | `pollToken` в query-string GET → попадает в логи прокси | `PairController.cs:65` |
| S8 | 🟡 medium | БЕЗОП | Нет `ForwardedHeaders` → за reverse-proxy IP клиента = IP прокси | `Program.cs:67` |
| P5 | 🟡 medium | ПРОИЗВ | `InternalTrialPoolController` грузит всю таблицу в память | `InternalTrialPoolController.cs:23-26` |
| P6 | 🟡 medium | ПРОИЗВ | Нет `AsNoTracking()` на read-only путях | `SubscriptionResolver.cs:27,36` |
| B10 | 🟡 medium | БАГ | Race в `AccountUpsert` → unique violation на `TelegramUserId` → 500 | `AccountUpsert.cs:18-28` |
| B11 | 🟡 medium | БАГ | Тесты на InMemory не ловят race/unique/транзакционные баги | `TestHelpers.cs:19-22` |

---

## 1. БАГИ / КОРРЕКТНОСТЬ

### 🔴 B1. Race condition в `/pair/status` — одноразовый код выдаёт несколько сессий
**Где:** `backend/src/FatVpn.Bff.Api/Controllers/PairController.cs:78-93`

Классический read-modify-write без блокировки и без concurrency token: чтение
`pairing.Status == Completed`, затем `pairing.Status = Consumed` + `SaveChangesAsync`.
Приложение полит эндпоинт в цикле; при двух одновременных запросах (retry по таймауту,
дубль от сетевого стека) обе транзакции в PostgreSQL Read Committed прочитают
`Completed`, обе создадут refresh-токен и обе запишут `Consumed`. Гарантия «single-use»
из `PairingCode.cs:8-11` **не выполняется**.

**Последствие:** две параллельные 90-дневные сессии на один pairing-код; ротация
refresh одной из них сработает как reuse-detection и убьёт вторую → пользователь
случайно разлогинивается.

**Фикс:** атомарный condition-update вместо read-then-write:

```csharp
var claimed = await db.PairingCodes
    .Where(p => p.PollToken == pollToken && p.Status == PairingStatus.Completed)
    .ExecuteUpdateAsync(s => s.SetProperty(p => p.Status, PairingStatus.Consumed), ct);
if (claimed != 1) { /* pending / expired ветки */ }
```

либо xmin-concurrency token (`UseXminAsConcurrencyToken()`) + обработка
`DbUpdateConcurrencyException`.

### 🔴 B2. Race condition в `/auth/refresh` — две активные сессии из одного токена
**Где:** `backend/src/FatVpn.Bff.Api/Controllers/AuthController.cs:62-113`

Тот же TOCTOU: чтение `stored` → проверка `IsActive` → `stored.RevokedAt = now` +
создание нового refresh → `SaveChanges`. Flutter-клиент при истечении access-токена
легко делает 2–3 параллельных `/auth/refresh` (несколько запросов упёрлись в 401
одновременно). Обе транзакции видят `RevokedAt == null` → в БД два живых refresh.

**Последствия:**
1. Клиент сохранит только последний → второй позже сработает как reuse-detection →
   `RevokeFamilyAsync` отзовёт всю семью → «случайные разлогины» и повторный пейринг.
2. Атакующий с украденным refresh может гонкой обойти reuse-detection.

**Фикс:** атомарный «claim» + транзакция:

```csharp
var rotated = await db.RefreshTokens
    .Where(r => r.TokenHash == hash && r.RevokedAt == null && r.ExpiresAt > now)
    .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, now), ct);
if (rotated != 1) { /* 401 + reuse-detection путь */ }
```

Дополнительно ввести **grace window** (~10 с): повторное предъявление только что
отротированного токена возвращает **тот же** новый токен, а не убивает семью —
стандартная защита от гонок мобильного клиента.

### 🔴 B3. `DateTimeOffset` с ненулевым offset от бота → 500
**Где:** `InternalPairController.cs:53`, `InternalAccountController.cs:35`,
`InternalTokensController.cs:46`; запись — `AccountUpsert.cs:38`, `InternalTokensController.cs:36`

Npgsql для `timestamp with time zone` принимает `DateTimeOffset` **только с
`Offset == TimeSpan.Zero`**. Python-бот, отдающий ISO-строку вида
`"2026-08-01T00:00:00+03:00"` (Москва — вероятная TZ бота), десериализуется с
Offset=+3 → `SaveChangesAsync` бросает исключение → 500, пейринг не завершается,
подписка не обновляется. Тестами не покрыто (там всегда `UtcNow`).

**Фикс:** нормализовать на входе во всех трёх контроллерах
(`request.ExpiresAt.ToUniversalTime()`) и как страховка — глобальный
`ValueConverter<DateTimeOffset, DateTimeOffset>(v => v.ToUniversalTime(), v => v)`
в `OnModelCreating`.

### 🟠 B4. Утечка пользователя в Remnawave при сбое БД
**Где:** `TrialController.cs:71-114`

`CreateTrialUserAsync` создаёт реального пользователя в панели, и только потом идёт
`SaveChangesAsync`. Если `SaveChanges` упадёт (unique violation — см. B5, обрыв
соединения, отмена запроса), созданный `trial_xxx` останется в панели навсегда —
без ссылки в БД и без возможности удалить.

**Фикс:** try/catch вокруг `SaveChangesAsync` с компенсирующим
`DELETE /api/users/{uuid}` (добавить метод в `IRemnawaveClient`); либо outbox-паттерн:
сначала `Device`+`Token` со статусом `Provisioning`, потом создание юзера, потом commit.

### 🟠 B5. Race в `/trial` → нарушение unique-index → 500
**Где:** `TrialController.cs:28` и `:79-88`

Два одновременных `POST /trial` с одним `attestationToken` → оба не находят `Device` →
оба создают → второй `SaveChanges` падает на `IX_Devices_DeviceKeyHash` → 500. И оба
уже создали по юзеру в панели (двойная выдача + B4).

Отдельно: на `Trials.DeviceId` **нет уникального индекса**, поэтому при появлении
пары строк `SingleOrDefaultAsync` (`TrialController.cs:31`) начнёт бросать
`InvalidOperationException` → вечный 500 для этого устройства.

**Фикс:** уникальный индекс `Trials.DeviceId`; ловить `DbUpdateException` с
`PostgresException.SqlState == "23505"` и переигрывать как «resume»-ветку;
advisory lock по `deviceKeyHash`.

### 🟠 B6. TOCTOU в привязке device-key
**Где:** `AuthController.cs:32-43`

Два устройства, одновременно вводящие один свежий ключ, оба увидят
`BoundDeviceKeyHash == null`, оба «привяжутся» и оба получат рабочие 90-дневные
сессии. Ограничение «один ключ = один телефон» нарушается.

**Фикс:** атомарно:

```csharp
var bound = await db.Tokens
    .Where(t => t.Id == token.Id && (t.BoundDeviceKeyHash == null || t.BoundDeviceKeyHash == deviceHash))
    .ExecuteUpdateAsync(s => s.SetProperty(t => t.BoundDeviceKeyHash, deviceHash), ct);
if (bound != 1) return Conflict();
```

Мелочь там же (`:39`): сравнение хэшей `string.Equals(Ordinal)` — заменить на
`CryptographicOperations.FixedTimeEquals` для однородности.

### 🟠 B7. Утечки исключений → 500 вместо корректных кодов
1. `ClaimsPrincipalExtensions.cs:10-18` — `Guid.Parse` бросает `FormatException`,
   `GetTokenId` бросает `InvalidOperationException`, а `TryGetAccountId` вопреки
   имени тоже бросает. JWT, валидный по подписи, но без нужного claim → 500 вместо 401.
   **Фикс:** `Guid.TryParse` → `Guid?`; в `SubscriptionResolver` вернуть `null` → 401.
2. `ServersController.cs:35` ловит только `HttpRequestException`, но
   `GetNodesAsync` может бросить `TaskCanceledException` (таймаут) и `JsonException`
   (панель вернула HTML/страницу Cloudflare) → 500 вместо 502. То же в
   `ConfigController.cs:48`. **Фикс:** глобальный `IExceptionHandler` с маппингом.
3. `TrialController.cs:74` — `catch (Exception)` поглощает и `OperationCanceledException`
   (нормальный disconnect клиента) → ERROR в лог + 502. **Фикс:**
   `catch (Exception ex) when (ex is not OperationCanceledException)`.

### 🟡 B8. `subscriptionId` подставляется в URL без экранирования
**Где:** `RemnawaveClient.cs:43` — `GetAsync($"/sub/{subscriptionId}")`.
Значение приходит от бота без валидации; `../api/users` меняет целевой путь запроса.
**Фикс:** `Uri.EscapeDataString` + валидация формата (`^[A-Za-z0-9_-]{8,64}$`)
при приёме от бота.

### 🟡 B9. Форматирование даты зависит от CurrentCulture
**Где:** `RemnawaveClient.cs:59` — `ToString("yyyy-MM-ddTHH:mm:ss.fffZ")` без
`IFormatProvider`; `:` — культурный разделитель, в контейнере с не-инвариантной
локалью получится `00.00.00`. **Фикс:** `ToString("O")` или явный формат с
`CultureInfo.InvariantCulture`. Смежно: при десериализации `RemnawaveUserDto.ExpireAt`
без суффикса зоны подставится локальный offset — парсить явно и `.ToUniversalTime()`.

### 🟡 B10. Race в `AccountUpsert`
**Где:** `AccountUpsert.cs:18-28` — `SingleOrDefaultAsync` + `Add` без блокировки;
параллельные `/internal/pair/complete` и `/internal/account/subscription` (реальный
сценарий «купил ключ и сразу спарился») → unique violation на `TelegramUserId` → 500.
**Фикс:** `ON CONFLICT (TelegramUserId) DO UPDATE` или retry на SqlState `23505`.

### 🟡 B11. Тесты не способны поймать перечисленные баги
**Где:** `TestHelpers.cs:19-22` — `UseInMemoryDatabase`. InMemory не поддерживает
транзакции, unique-индексы, параллелизм и поведение Npgsql с `DateTimeOffset` —
B1, B2, B3, B5, B10 проходят зелёными. **Фикс:** интеграционный слой на
`Testcontainers.PostgreSql` для auth/pair/trial + тесты на параллельные вызовы
(`Task.WhenAll`).

### 🟢 Мелкие баги (low)
- `InternalTokensController.cs:42` — всегда `201 Created`, даже при апдейте (должно быть 200).
- `PairController.cs:80-84` — при «висящем» `AccountId` возвращается `expired`, но код
  не переводится в `Consumed` → клиент может поллить бесконечно.
- `PairController.cs:28-41` — проверка коллизии не исключает истёкшие коды; до 5
  round-trip'ов в БД на `/pair/start`. Достаточно unique-индекса + retry на `23505`.
- `AuthController.cs:50,115` — поле `expiresAt` в ответе — срок **подписки**, не
  access-токена; отдавать оба (`accessTokenExpiresAt` + `subscriptionExpiresAt`).
- `AuthController.cs:111` — refresh при ротации получает полные 90 дней → сессия
  вечная при активном использовании. Добавить absolute lifetime семьи.
- `Migrations/20260721084011_AddTokenIdToTrial.cs:25-33` — бэкфилл по равенству
  timestamp; несматчившиеся строки получают `Guid.Empty` → вечный 409 в
  `TrialController.cs:39-42` без пути восстановления.
- `SubscriptionAugmenter.cs:24-29` — хосты/порты Hysteria2 захардкожены; вынести в конфиг.

---

## 2. БЕЗОПАСНОСТЬ

### 🔴 S1. Полное отсутствие rate limiting
**Где:** `Program.cs` — нет ни `AddRateLimiter`, ни `UseRateLimiter`; пакета в
`FatVpn.Bff.Api.csproj` тоже нет (вопреки `docs/security-audit.md:73`).

| Эндпоинт | Вектор |
|---|---|
| `POST /trial` | каждый вызов создаёт реального пользователя в панели → исчерпание квот, DoS |
| `POST /auth/token` | brute-force коротких keyCode |
| `POST /auth/refresh` | brute-force + рост `RefreshTokens` |
| `POST /pair/start` | безлимитная запись в `PairingCodes` |
| `GET /pair/status` | polling-спам |

**Фикс:** `AddRateLimiter` c per-IP fixed window: `/trial` — 3/час, auth/pair — 20/мин,
глобально ~100/мин; `RejectionStatusCode = 429`; `[EnableRateLimiting]` на
контроллерах. Обязательно вместе с S8, иначе за прокси все клиенты в одном бакете.

### 🔴 S2. `UseHttpsRedirection()` только в Development — условие инвертировано
**Где:** `Program.cs:61-65` — редирект внутри `if (app.Environment.IsDevelopment())`.
Работает там, где не нужен, и отключён в проде (который слушает HTTP на
`0.0.0.0:5030`). Дополняет `docs/security-audit.md#1` — там не отмечена инверсия.
**Фикс:** TLS-терминация на Caddy + `UseHttpsRedirection()` и `UseHsts()` вне
Development; `AllowedHosts` = реальный домен; приложение на `https://`.

### 🔴 S3. Пустой `attestationToken` даёт общую device-identity
**Где:** `TrialController.cs:25` — валидации нет вообще (`[ApiController]` отсекает
только `null`, но не `""`). При `{"attestationToken":""}` хэш = `SHA256(salt)` —
одинаковый для всех. Первый клиент создаёт Device+Trial, любой последующий попадает
в resume-ветку (`:39-56`) и **получает валидную сессию к чужому триалу**.
В `AuthController.cs:32` аналогичная проверка есть — в `TrialController` забыта.

Отдельно: `Trial__DeviceKeySalt` не пробрасывается в `docker-compose.yml:21-29` →
в проде соль пустая (несолёный хэш).

**Фикс:** валидация `IsNullOrWhiteSpace` + длина 16–512; проброс
`Trial__DeviceKeySalt` в compose; fail-fast при пустой соли в Production.
Долгосрочно — Play Integrity / App Attest (известный TODO).

### 🟠 S4. Dev-секреты в git и в Docker-образе
**Где:** `appsettings.Development.json:9,12,15` отслеживается git
(`Jwt:Secret`, `Bot:Secret`); `Dockerfile:13` (`COPY . .`) кладёт его в runtime-образ.
Одна переменная `ASPNETCORE_ENVIRONMENT=Development` на сервере — и BFF подхватит
публично известный HMAC-ключ → подделка JWT → полный обход авторизации.
**Фикс:** `git rm --cached`, dev-секреты в user-secrets, `.dockerignore`;
hard fail в `Program.cs`, если Development слушает не-localhost. Смежно: пароль
Postgres захардкожен в `docker-compose.yml:8,22` и `appsettings.json:10`.

### 🟠 S5. Нет fail-fast валидации секретов на старте
**Где:** `Program.cs:36-50`. Пустой `Jwt:Secret` → невнятное падение; короткий
(<32 байт) → старт пройдёт, а `JwtTokenService.CreateToken` упадёт в рантайме →
500 на каждый логин. **Фикс:**
`AddOptions<JwtOptions>().Bind(...).Validate(o => o.Secret.Length >= 32).ValidateOnStart()`;
то же для `BotOptions.Secret` и `TrialOptions.DeviceKeySalt` (в non-Development).

### 🟡 S6. Настройки JWT-валидации
**Где:** `Program.cs:40-49`.
- `ClockSkew` не задан → 5 мин по умолчанию, access фактически живёт 35 мин.
  Фикс: `ClockSkew = TimeSpan.FromSeconds(30)`.
- Не ограничен алгоритм: добавить `ValidAlgorithms = [HmacSha256]`.
- Нет `AddProblemDetails()` / `UseExceptionHandler` → в Development 500 отдаёт стек-трейс.

### 🟡 S7. `pollToken` в query-string
**Где:** `PairController.cs:64-65`. Полноценный bearer-секрет в URL попадает в
access-логи прокси, APM-трейсы. **Фикс:** заголовок `X-Pair-Poll-Token` или
`POST /pair/status` с телом (согласовать с приложением).

### 🟡 S8. Нет обработки Forwarded-заголовков
**Где:** `Program.cs:67`. За Caddy `RemoteIpAddress` = IP прокси → per-IP rate limiter
(S1) схлопнет всех в один бакет, а `UseHttpsRedirection` даст редирект-цикл.
**Фикс:** `UseForwardedHeaders(XForwardedFor | XForwardedProto, KnownProxies=...)`
до остального middleware.

### 🟡 S9. `Bot:Secret` — единый статический ключ ко всем `/internal/*`
**Где:** `InternalPairController.cs:19`, `InternalAccountController.cs:21`,
`InternalTokensController.cs:18`, `InternalTrialPoolController.cs:18,53`.
Сравнение корректное (constant-time), но: `/internal/account/subscription` не
проверяет владение (можно выставить любой `ExpiresAt` любому `TelegramUserId`);
`/internal/tokens` сбрасывает `BoundDeviceKeyHash`; проверка секрета скопипащена
в 4 контроллерах. **Фикс:** вынести в `AuthorizationHandler` +
`[Authorize(Policy = "Bot")]`, чтобы «забыть» в новом эндпоинте было нельзя.

### 🟡 S10. DoS-векторы по размеру пейлоада
- `InternalTrialPoolController.cs:64` — список идентификаторов без лимита количества.
- `TrialController.cs:120` — `AttestationToken` без ограничения длины (см. S3).
- `RemnawaveClient.cs:46` — `ReadAsStringAsync` без `MaxResponseContentBufferSize`.
**Фикс:** `[RequestSizeLimit]`, `MaxLength` в DTO, лимит размера ответа панели.

### 🟢 Низкий риск / принять как есть
- CORS не настроен — для мобильного BFF это правильно (зафиксировать как решение).
- SQL-инъекций не найдено (везде параметризованный LINQ).
- Логирования секретов не найдено; обратная проблема — **аудита нет вообще**:
  неудачные `/auth/token`, срабатывания reuse-detection нигде не логируются.
  Добавить структурированные warn-логи.

---

## 3. ПРОИЗВОДИТЕЛЬНОСТЬ

### 🟠 P1. `/servers` бьёт в панель на каждый запрос
**Где:** `ServersController.cs:32` → `RemnawaveClient.cs:13-38`. Ответ идентичен для
всех пользователей, но каждый pull-to-refresh = запрос к панели.
**Фикс:** `IMemoryCache`/`HybridCache` с TTL 30–60 с и защитой от stampede
(`GetOrCreateAsync`); `Cache-Control: private, max-age=60` в ответе.
`/config` — per-user, но тоже заслуживает короткого кеша по `subscriptionId` (10–30 с).

### 🟠 P2. Отсутствующие индексы
**Где:** `FatVpnDbContext.cs:16-25` — только unique-индексы. Добавить миграцией:

```csharp
modelBuilder.Entity<RefreshToken>().HasIndex(r => new { r.AccountId, r.RevokedAt });
modelBuilder.Entity<RefreshToken>().HasIndex(r => new { r.TokenId, r.RevokedAt });
modelBuilder.Entity<RefreshToken>().HasIndex(r => r.ExpiresAt);
modelBuilder.Entity<Trial>().HasIndex(t => t.DeviceId).IsUnique();   // + фикс B5
modelBuilder.Entity<PairingCode>().HasIndex(p => p.ExpiresAt);
```

Сейчас `RevokeFamilyAsync` (`AuthController.cs:139-143`) делает seq scan по самой
быстрорастущей таблице.

### 🟠 P3. Неограниченный рост таблиц, нет очистки
**Где:** `RefreshTokenService.cs:20-34`, `PairController.cs:43-53`.
Ротация добавляет строку на каждый `/auth/refresh` (~48 строк/устройство/сутки при
30-минутном access): 10 000 устройств ≈ 480 тыс. строк/день. `PairingCodes` растёт
на каждый `/pair/start` навсегда.
**Фикс:** `BackgroundService` с ежесуточным `ExecuteDeleteAsync`:
удалять refresh с `ExpiresAt < now - 30d` или `RevokedAt < now - 7d`;
pairing-коды с `ExpiresAt < now - 1d`. Требует индексов из P2.

### 🟡 P4. `HttpClient` без таймаута и resilience
**Где:** `Program.cs:30-34`. `Timeout` = 100 с по умолчанию: зависшая панель держит
соединения/потоки → каскадный отказ BFF. **Фикс:**

```csharp
.ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(10))
.ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler {
    PooledConnectionLifetime = TimeSpan.FromMinutes(2) })
.AddStandardResilienceHandler();
```

`PooledConnectionLifetime` важен и для смены IP панели за Cloudflare
(см. `docs/subscription-cloudflare-fix.md`).

### 🟡 P5. Загрузка всей таблицы в память
**Где:** `InternalTrialPoolController.cs:23-26` — `ToListAsync()` всей
`TrialSubscriptionSlots` ради проверки нескольких id. **Фикс:** `Where(s =>
requested.Contains(s.RemnawaveSubscriptionId))`.

### 🟡 P6. Нет `AsNoTracking()` на read-only путях
**Где:** `SubscriptionResolver.cs:27,36` (`FindAsync` всегда tracked),
`MeController`, `ServersController`, `ConfigController`. `/me` и `/servers` — самые
частые эндпоинты. **Фикс:** `.AsNoTracking().FirstOrDefaultAsync(...)` в read-only
ветках.

### 🟢 Прочее
- `JwtTokenService.cs:28,38` — новый `SymmetricSecurityKey` и `JwtSecurityTokenHandler`
  на каждый выпуск; закешировать ключ в поле, перейти на `JsonWebTokenHandler`.
- `AuthController.cs:139-143` — `RevokeFamilyAsync` материализует семью и обновляет
  по одной; заменить одним `ExecuteUpdateAsync`.
- `SubscriptionAugmenter.cs:44-64` — лишние аллокации (char[] размером с конфиг,
  StringBuilder, повторный Base64) на каждый `/config`.
- `/health` (`Program.cs:72`) — безусловный `ok`; добавить
  `AddHealthChecks().AddDbContextCheck<FatVpnDbContext>()`.
- Нет `AddResponseCompression` — gzip/brotli для `/servers` и `/config` сэкономит
  мобильный трафик.

---

## Рекомендуемый порядок работ

1. **Сейчас (дёшево, без изменения архитектуры):** S3 (валидация `attestationToken`),
   S5 (fail-fast секретов), B7 (`Guid.TryParse` + глобальный exception handler),
   P4 (таймаут HttpClient), S1 (rate limiter), P2 (миграция с индексами).
2. **Атомарность (одна итерация):** B1, B2, B6, B10 — везде заменить
   read-modify-write на `ExecuteUpdateAsync` с проверкой числа затронутых строк;
   B2 дополнительно — grace window для refresh (согласовать с retry-логикой приложения).
3. **Перед продом (блокеры):** S2 (HTTPS + HSTS + ForwardedHeaders), S4 (секреты из
   git и из образа), B3 (нормализация `DateTimeOffset` от бота).
4. **Долг:** P1/P3 (кеш + фоновая очистка), B4 (компенсация в Remnawave),
   B11 (Testcontainers + тесты на параллелизм).

**Критерий приёмки:** `dotnet build` + все тесты зелёные; новые интеграционные тесты
на B1/B2/B5 (параллельные вызовы) проходят; ручная проверка через
`FatVpn.Bff.Api.http` — коды ответов не изменились для happy-path.
