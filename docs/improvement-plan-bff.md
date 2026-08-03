# План доработок — BFF (.NET 10)

> **Назначение документа:** техзадание для исполнителя (Claude Opus). Аудит проведён
> 2026-07-27 по коду `master`. Каждый пункт — самостоятельная задача с местом в коде,
> объяснением и предлагаемым исправлением. Дополняет `docs/security-audit.md`
> (2026-07-25) — пункты оттуда здесь не дублируются, кроме случаев, где аудит нашёл
> новые детали (помечено).
>
> Смежные документы: `docs/improvement-plan-app-android.md`, `docs/improvement-plan-ios.md`.

## ✅ Статус на 2026-07-28: закрыто коммитом `820b1fe`

`820b1fe` («fix(bff): close the races and gaps the technical audit found») закрывает
**все 6 critical и все 9 high**, а также почти весь medium-хвост. Открытыми осознанно
оставлены три вещи:

| Что | Почему открыто |
|---|---|
| **S2 — HTTPS** | Условие `UseHttpsRedirection` исправлено, но включение спрятано за `Security:RequireHttps` (по умолчанию `false`). ⚠️ **Уточнение 2026-08-03:** домена этот флаг больше не ждёт — `https://api.fatklyuchi.space` живёт с 2026-07-30, приложение ходит туда, `AllowedHosts` выкачен на прод и проверен снаружи. Флаг ждёт **исчезновения старых сборок**: включённый, он ответит 307 и HSTS на `http://87.121.221.229:5030`, где сертификата нет, — то есть выключит ровно тех, ради кого этот порт оставлен открытым |
| **S9 — владение в `/internal/*`** | Проверка секрета вынесена в политику `[Authorize(Policy = "Bot")]`, но `/internal/account/subscription` по-прежнему позволяет выставить любой `ExpiresAt` любому `telegramUserId`. Единственный вызывающий — наш бот; менять контракт без правки бота нельзя |
| ~~**S10 — размер ответа панели**~~ | ✅ Закрыто 2026-08-02: ответ панели ограничен 4 МБ (`RemnawaveClient.MaxResponseBytes`), превышение — 502 |

**Что сделано иначе, чем предлагал план** (детали — в соответствующих пунктах):

- **B2:** grace-окно `Jwt:RefreshGraceWindow` = **30 с** (план предлагал ~10 с). В окно
  выдаётся **новый** токен той же семьи, а не повтор токена победителя гонки —
  refresh-токены хранятся только хешами, восстановить исходное значение неоткуда.
- **P1:** кеш добавлен только `/servers` (45 с, single-flight). `/config` намеренно
  **не** кешируется: ответ персональный, несёт креденшелы и запрашивается раз на коннект.
- **P4:** таймаут и `PooledConnectionLifetime` добавлены, а `AddStandardResilienceHandler` —
  **нет**: его дефолтная политика ретраит и POST'ы, а повторный `POST /api/users`
  оставляет в панели осиротевших триальных юзеров.
- **B4:** компенсирующий `DELETE /api/users/{uuid}` выполняется в ветке `DbUpdateException`
  (проигрыш гонки), outbox-паттерн не вводился.
- **Абсолютный срок жизни сессии** добавлен как **опция** `Jwt:AbsoluteSessionLifetime`
  (по умолчанию `00:00:00` = выключено): включение разлогинит всех, кто его перешагнул, —
  это продуктовое решение, а не техническое.

⛔ **Деплой этих изменений требует `TRIAL_DEVICE_KEY_SALT`** в env контейнера: startup-валидация
отказывается стартовать без него вне Development. Полный список обязательных и новых
необязательных настроек — `docs/api-contract.md`.

## Сводка по критичности

| # | Sev | Кат | Проблема | Файл:строка | Статус |
|---|-----|-----|----------|-------------|--------|
| B1 | 🔴 critical | БАГ | Race condition в `/pair/status`: «одноразовый» код выдаёт 2+ сессии | `PairController.cs:78-93` | ✅ `820b1fe` |
| B2 | 🔴 critical | БАГ | Race condition в `/auth/refresh`: две сессии из одного refresh, обход reuse-detection | `AuthController.cs:62-113` | ✅ `820b1fe` |
| B3 | 🔴 critical | БАГ | `DateTimeOffset` с ненулевым offset от бота → Npgsql бросает исключение → 500 | `InternalPairController.cs:53`, `InternalAccountController.cs:35`, `InternalTokensController.cs:46` | ✅ `820b1fe` |
| S1 | 🔴 critical | БЕЗОП | Полное отсутствие rate limiting на публичных эндпоинтах | `Program.cs` | ✅ `820b1fe` |
| S2 | 🔴 critical | БЕЗОП | `UseHttpsRedirection()` включён **только** в Development (условие инвертировано) | `Program.cs:61-65` | 🟡 условие исправлено; домен и сертификат есть с 2026-07-30, флаг `Security:RequireHttps` ждёт исчезновения сборок, ходящих на голый IP |
| S3 | 🔴 critical | БЕЗОП | Пустой `attestationToken` = общая device-identity → выдача чужой trial-сессии | `TrialController.cs:25` | ✅ `820b1fe` |
| B4 | 🟠 high | БАГ | Утечка юзера в Remnawave при падении `SaveChanges` (нет компенсации) | `TrialController.cs:71-114` | ✅ `820b1fe` |
| B5 | 🟠 high | БАГ | Race в `/trial`: два запроса → нарушение unique-index → 500 | `TrialController.cs:28-88` | ✅ `820b1fe` |
| B6 | 🟠 high | БАГ | TOCTOU в привязке device-key: «один ключ = один телефон» обходится | `AuthController.cs:32-43` | ✅ `820b1fe` |
| B7 | 🟠 high | БАГ | Утечка исключений → 500 вместо 401/502 | `ClaimsPrincipalExtensions.cs:10-18`, `ServersController.cs:35` | ✅ `820b1fe` |
| P1 | 🟠 high | ПРОИЗВ | `/servers` дёргает панель на **каждый** запрос, нет кеша | `ServersController.cs:32` | ✅ `820b1fe` (только `/servers`) |
| P2 | 🟠 high | ПРОИЗВ | Нет индексов на `RefreshTokens.AccountId/TokenId`, `Trials.DeviceId`; seq scan в `RevokeFamilyAsync` | `FatVpnDbContext.cs:16-25` | ✅ `820b1fe` |
| P3 | 🟠 high | ПРОИЗВ | `RefreshTokens`/`PairingCodes` растут неограниченно, нет очистки | `RefreshTokenService.cs:30`, `PairController.cs:43-53` | ✅ `820b1fe` |
| S4 | 🟠 high | БЕЗОП | Dev-секреты в git + попадают в Docker-образ | `appsettings.Development.json`, `Dockerfile:13` | ✅ `820b1fe` (пароль Postgres остался) |
| S5 | 🟠 high | БЕЗОП | Нет fail-fast валидации `Jwt:Secret` / `Bot:Secret` на старте | `Program.cs:36-50` | ✅ `820b1fe` |
| P4 | 🟡 medium | ПРОИЗВ | У `HttpClient` не задан `Timeout` (дефолт 100 с) → каскадный отказ при зависании панели | `Program.cs:30-34` | ✅ `820b1fe` (без resilience-handler) |
| B8 | 🟡 medium | БАГ | `subscriptionId` не URL-экранируется → path traversal в панель | `RemnawaveClient.cs:43` | ✅ `820b1fe` |
| B9 | 🟡 medium | БАГ | Форматирование даты с `CurrentCulture` | `RemnawaveClient.cs:59` | ✅ `820b1fe` |
| S6 | 🟡 medium | БЕЗОП | `ClockSkew` по умолчанию 5 мин; алгоритм подписи не ограничен | `Program.cs:40-49` | ✅ `820b1fe` |
| S7 | 🟡 medium | БЕЗОП | `pollToken` в query-string GET → попадает в логи прокси | `PairController.cs:65` | ✅ `820b1fe` (заголовок; query оставлен) |
| S8 | 🟡 medium | БЕЗОП | Нет `ForwardedHeaders` → за reverse-proxy IP клиента = IP прокси | `Program.cs:67` | ✅ `820b1fe` |
| P5 | 🟡 medium | ПРОИЗВ | `InternalTrialPoolController` грузит всю таблицу в память | `InternalTrialPoolController.cs:23-26` | ✅ `820b1fe` |
| P6 | 🟡 medium | ПРОИЗВ | Нет `AsNoTracking()` на read-only путях | `SubscriptionResolver.cs:27,36` | ✅ `820b1fe` |
| B10 | 🟡 medium | БАГ | Race в `AccountUpsert` → unique violation на `TelegramUserId` → 500 | `AccountUpsert.cs:18-28` | ✅ `820b1fe` |
| B11 | 🟡 medium | БАГ | Тесты на InMemory не ловят race/unique/транзакционные баги | `TestHelpers.cs:19-22` | ✅ `820b1fe` (SQLite + Testcontainers) |
| S9 | 🟡 medium | БЕЗОП | `Bot:Secret` — единый статический ключ ко всем `/internal/*` | `Internal*Controller.cs` | 🟡 политика есть, проверки владения нет |
| S10 | 🟡 medium | БЕЗОП | DoS-векторы по размеру пейлоада | `InternalTrialPoolController.cs:64`, `RemnawaveClient.cs:46` | 🟡 вход ограничен, ответ панели — нет |

---

## 1. БАГИ / КОРРЕКТНОСТЬ

### 🔴 B1. Race condition в `/pair/status` — одноразовый код выдаёт несколько сессий — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** ровно предложенный `ExecuteUpdateAsync`, дополнительно обёрнутый в
> явную транзакцию — вставка refresh-токена привязана к флипу статуса, чтобы сбой не
> «сжигал» код впустую. Проигравший гонку получает `{"status":"expired"}`.
> Покрыто `ConcurrencyIntegrationTests` (8 параллельных вызовов → ровно одна сессия).

### 🔴 B2. Race condition в `/auth/refresh` — две активные сессии из одного токена — ✅ Сделано (`820b1fe`)
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

> **Как сделано (важно для приложения):** claim атомарный, но проверка срока вынесена
> **из** `WHERE` в отдельную ветку — так UPDATE остаётся транслируемым на всех
> провайдерах, на которых крутятся тесты. Grace-окно — **30 с**, настраивается
> (`Jwt:RefreshGraceWindow`). В пределах окна семья **не** отзывается, но выдаётся
> **новый** токен той же семьи, а не повтор токена победителя: хранятся только хеши,
> исходное значение восстановить неоткуда. Клиенту достаточно сохранять последний
> полученный refresh. Срабатывание reuse-detection теперь логируется (`LogWarning`
> с задержкой от момента ротации).

### 🔴 B3. `DateTimeOffset` с ненулевым offset от бота → 500 — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** обе половины — нормализация в точках входа **и** конвертер на все
> свойства `DateTimeOffset`/`DateTimeOffset?` всех сущностей
> (`FatVpnDbContext.OnModelCreating`), чтобы будущий путь записи не мог вернуть баг.

### 🟠 B4. Утечка пользователя в Remnawave при сбое БД — ✅ Сделано (`820b1fe`)
**Где:** `TrialController.cs:71-114`

`CreateTrialUserAsync` создаёт реального пользователя в панели, и только потом идёт
`SaveChangesAsync`. Если `SaveChanges` упадёт (unique violation — см. B5, обрыв
соединения, отмена запроса), созданный `trial_xxx` останется в панели навсегда —
без ссылки в БД и без возможности удалить.

**Фикс:** try/catch вокруг `SaveChangesAsync` с компенсирующим
`DELETE /api/users/{uuid}` (добавить метод в `IRemnawaveClient`); либо outbox-паттерн:
сначала `Device`+`Token` со статусом `Provisioning`, потом создание юзера, потом commit.

> **Как сделано:** `IRemnawaveClient.DeleteUserAsync` добавлен, компенсация вызывается в
> ветке `DbUpdateException` (проигравший гонку B5), некансельруемо (`CancellationToken.None`):
> отвалившийся клиент — не повод оставить юзера в панели. Outbox не вводился.
> **Остаточный риск:** если ответ панели на создание не принёс `uuid`, удалять нечего —
> это пишется в лог как `Orphaned trial user ... in the panel`.

### 🟠 B5. Race в `/trial` → нарушение unique-index → 500 — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** уникальный индекс `Trials.DeviceId` добавлен миграцией
> `20260727231711_AddPerformanceIndexes`. Проигравший ловит `DbUpdateException`
> (без разбора `SqlState` — на SQLite в тестах его нет), возвращает свой юзер в панель
> и «усыновляет» триал победителя через ту же resume-ветку. Advisory lock не понадобился.

### 🟠 B6. TOCTOU в привязке device-key — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** ровно предложенный `ExecuteUpdateAsync` + 409. Сравнение хешей
> уехало в SQL, отдельного `FixedTimeEquals` не потребовалось. Отказ логируется.

### 🟠 B7. Утечки исключений → 500 вместо корректных кодов — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** все три. `TryGetTokenId`/`TryGetAccountId` возвращают `Guid?` и не
> бросают; все обращения к панели завёрнуты в `RemnawaveClient.CallAsync`, который
> переводит `HttpRequestException`/`JsonException`/таймаут в `RemnawaveException`, а
> `UpstreamExceptionHandler` отвечает **502 + ProblemDetails**; отвалившийся клиент
> обрабатывается отдельным `ClientDisconnectExceptionHandler` и больше не пишется как ERROR.

### 🟡 B8. `subscriptionId` подставляется в URL без экранирования — ✅ Сделано (`820b1fe`)
**Где:** `RemnawaveClient.cs:43` — `GetAsync($"/sub/{subscriptionId}")`.
Значение приходит от бота без валидации; `../api/users` меняет целевой путь запроса.
**Фикс:** `Uri.EscapeDataString` + валидация формата (`^[A-Za-z0-9_-]{8,64}$`)
при приёме от бота.

> **Как сделано:** `Uri.EscapeDataString` + `IsWellFormedSubscriptionId` (4–64 символа,
> ASCII-алфавит с `-`/`_`); нарушение — `RemnawaveException` → 502, а не поход в панель.

### 🟡 B9. Форматирование даты зависит от CurrentCulture — ✅ Сделано (`820b1fe`)
**Где:** `RemnawaveClient.cs:59` — `ToString("yyyy-MM-ddTHH:mm:ss.fffZ")` без
`IFormatProvider`; `:` — культурный разделитель, в контейнере с не-инвариантной
локалью получится `00.00.00`. **Фикс:** `ToString("O")` или явный формат с
`CultureInfo.InvariantCulture`. Смежно: при десериализации `RemnawaveUserDto.ExpireAt`
без суффикса зоны подставится локальный offset — парсить явно и `.ToUniversalTime()`.

> **Как сделано:** `CultureInfo.InvariantCulture` в запросе, `.ToUniversalTime()` на
> `ExpireAt` из ответа.

### 🟡 B10. Race в `AccountUpsert` — ✅ Сделано (`820b1fe`)
**Где:** `AccountUpsert.cs:18-28` — `SingleOrDefaultAsync` + `Add` без блокировки;
параллельные `/internal/pair/complete` и `/internal/account/subscription` (реальный
сценарий «купил ключ и сразу спарился») → unique violation на `TelegramUserId` → 500.
**Фикс:** `ON CONFLICT (TelegramUserId) DO UPDATE` или retry на SqlState `23505`.

> **Как сделано:** создание строки коммитится отдельно; на `DbUpdateException` проигравший
> отцепляет свою сущность, перечитывает победителя и работает с ним. Если победителя нет —
> исключение пробрасывается (значит это был не race, а другой сбой записи).

### 🟡 B11. Тесты не способны поймать перечисленные баги — ✅ Сделано (`820b1fe`)
**Где:** `TestHelpers.cs:19-22` — `UseInMemoryDatabase`. InMemory не поддерживает
транзакции, unique-индексы, параллелизм и поведение Npgsql с `DateTimeOffset` —
B1, B2, B3, B5, B10 проходят зелёными. **Фикс:** интеграционный слой на
`Testcontainers.PostgreSql` для auth/pair/trial + тесты на параллельные вызовы
(`Task.WhenAll`).

> **Как сделано:** unit/controller-тесты переехали на **SQLite in-memory** (InMemory не
> умеет unique-индексы и `ExecuteUpdate`), а `ConcurrencyIntegrationTests` поднимают
> **реальный PostgreSQL через Testcontainers** и бьют 8 параллельных вызовов в
> `/pair/status`, `/auth/refresh`, `/trial`, `/auth/token` и account-upsert. Без Docker
> тесты **скипаются**, а не падают. Всего 102 теста.

### 🟢 Мелкие баги (low)
- `InternalTokensController.cs:42` — всегда `201 Created`, даже при апдейте (должно быть 200).
  **⬜ Оставлено намеренно:** Python-бот живёт вне репозитория и вполне может проверять
  именно 201; ломать перевыпуск ключа ради косметики не стали (комментарий в коде).
- `PairController.cs:80-84` — при «висящем» `AccountId` возвращается `expired`, но код
  не переводится в `Consumed` → клиент может поллить бесконечно. **✅ `820b1fe`:** код
  теперь коммитится как `Consumed` и в этой ветке.
- `PairController.cs:28-41` — проверка коллизии не исключает истёкшие коды; до 5
  round-trip'ов в БД на `/pair/start`. Достаточно unique-индекса + retry на `23505`.
  **✅ `820b1fe`:** предпроверка убрана, коллизию ловит unique-индекс, до 2 ретраев.
- `AuthController.cs:50,115` — поле `expiresAt` в ответе — срок **подписки**, не
  access-токена; отдавать оба (`accessTokenExpiresAt` + `subscriptionExpiresAt`).
  **✅ `820b1fe`:** оба поля добавлены в ответы `/auth/token` и `/auth/refresh`, старое
  `expiresAt` оставлено ради уже выпущенных сборок. `/pair/status` и `/trial` их
  **не** отдают — приложению надо это учитывать (см. `docs/api-contract.md`).
- `AuthController.cs:111` — refresh при ротации получает полные 90 дней → сессия
  вечная при активном использовании. Добавить absolute lifetime семьи.
  **✅ `820b1fe`, опционально:** `RefreshToken.SessionStartedAt` переносится сквозь
  ротации, потолок задаётся `Jwt:AbsoluteSessionLifetime`; по умолчанию **выключен**,
  потому что включение разлогинит всех, кто его перешагнул.
- `Migrations/20260721084011_AddTokenIdToTrial.cs:25-33` — бэкфилл по равенству
  timestamp; несматчившиеся строки получают `Guid.Empty` → вечный 409 в
  `TrialController.cs:39-42` без пути восстановления. **🟡 частично:** случай теперь
  логируется отдельным warn'ом («points at token …, which does not exist»), чтобы
  поддержка отличала его от честной второй попытки триала; пути восстановления
  по-прежнему нет.
- `SubscriptionAugmenter.cs:24-29` — хосты/порты Hysteria2 захардкожены; вынести в конфиг.
  **✅ `820b1fe`:** `Remnawave:HysteriaHosts` (дефолты сохраняют прежнее поведение).

---

## 2. БЕЗОПАСНОСТЬ

### 🔴 S1. Полное отсутствие rate limiting — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** per-IP fixed window, значения вынесены в конфиг (`RateLimiting:*`),
> потому что за carrier-NAT правильные числа зависят от площадки. Дефолты: глобально
> **300/мин**, auth (`/auth/*`, `/pair/start`) — **20/мин**, `/pair/status` — **60/мин**
> (приложение полит раз в 2 с = 30/мин, двойной запас), `/trial` — **5/час**.
> 429 + заголовок `Retry-After`. `RateLimiting:Enabled=false` выключает целиком.
> S8 сделан в том же коммите.

### 🔴 S2. `UseHttpsRedirection()` только в Development — условие инвертировано — 🟡 Частично (`820b1fe`)
**Где:** `Program.cs:61-65` — редирект внутри `if (app.Environment.IsDevelopment())`.
Работает там, где не нужен, и отключён в проде (который слушает HTTP на
`0.0.0.0:5030`). Дополняет `docs/security-audit.md#1` — там не отмечена инверсия.
**Фикс:** TLS-терминация на Caddy + `UseHttpsRedirection()` и `UseHsts()` вне
Development; `AllowedHosts` = реальный домен; приложение на `https://`.

> **Что сделано:** инверсия исправлена, `UseHsts()` + `UseHttpsRedirection()` теперь
> живут за флагом `Security:RequireHttps` (по умолчанию **выключен**). Старт падает,
> если флаг включён, а `ReverseProxy:*` пуст — иначе Caddy и BFF будут редиректить
> друг друга по кругу.
> **Что осталось (обновлено 2026-08-02):** `bffBaseUrl` уже на `https://`
> (2026-07-30), `AllowedHosts` выставлен в `backend/docker-compose.yml` —
> `api.fatklyuchi.space;87.121.221.229;fatvpn-bff;bff;localhost;127.0.0.1`, под
> тестом `DeploymentConfigTests`. ✅ **Деплой состоялся 2026-08-03** и проверен снаружи:
> имя из списка отвечает штатно, имя вне списка — **400 на всё**, чем этот список и
> опасен (`fatvpn-bff` — это как до BFF дотягивается бот, голый IP — как это делают уже
> установленные сборки; выпавшее из списка имя выключает своих). Остаётся **один**
> флаг `Security:RequireHttps`, и он ждёт не домена, а исчезновения старых сборок:
> включённый, он даёт 307 и HSTS на `http://87.121.221.229:5030`, где сертификата
> нет, — то есть выключит ровно тех, ради кого этот порт оставлен открытым. См.
> `docs/open-bugs.md` 2.2 и 2.4.

### 🔴 S3. Пустой `attestationToken` даёт общую device-identity — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** все три части. Длина 16–512 (400 при нарушении), соль проброшена в
> compose как `${TRIAL_DEVICE_KEY_SALT}`, старт вне Development падает при пустой соли.
> ⛔ Значит перед деплоем переменную **обязательно** задать, иначе контейнер уйдёт в
> crash-loop. Play Integrity / App Attest по-прежнему TODO.

### 🟠 S4. Dev-секреты в git и в Docker-образе — ✅ Сделано (`820b1fe`)
**Где:** `appsettings.Development.json:9,12,15` отслеживается git
(`Jwt:Secret`, `Bot:Secret`); `Dockerfile:13` (`COPY . .`) кладёт его в runtime-образ.
Одна переменная `ASPNETCORE_ENVIRONMENT=Development` на сервере — и BFF подхватит
публично известный HMAC-ключ → подделка JWT → полный обход авторизации.
**Фикс:** `git rm --cached`, dev-секреты в user-secrets, `.dockerignore`;
hard fail в `Program.cs`, если Development слушает не-localhost. Смежно: пароль
Postgres захардкожен в `docker-compose.yml:8,22` и `appsettings.json:10`.

> **Как сделано:** файл удалён из git и добавлен в `.gitignore` (шаблон —
> `appsettings.Development.example.json`), появился `backend/.dockerignore`, старт
> Development-конфигурации на не-loopback адресе падает с внятным сообщением.
> **Значения, которые лежали в файле, надо считать публичными.**
> **Остаётся:** пароль Postgres по-прежнему захардкожен (`fatvpn_dev`) — ротировать
> перед настоящим продом.

### 🟠 S5. Нет fail-fast валидации секретов на старте — ✅ Сделано (`820b1fe`)
**Где:** `Program.cs:36-50`. Пустой `Jwt:Secret` → невнятное падение; короткий
(<32 байт) → старт пройдёт, а `JwtTokenService.CreateToken` упадёт в рантайме →
500 на каждый логин. **Фикс:**
`AddOptions<JwtOptions>().Bind(...).Validate(o => o.Secret.Length >= 32).ValidateOnStart()`;
то же для `BotOptions.Secret` и `TrialOptions.DeviceKeySalt` (в non-Development).

> **Как сделано:** `ValidateOnStart` для `Jwt` (секрет ≥32 байт, issuer/audience,
> положительные времена жизни), `Remnawave` (абсолютный BaseUrl, непустой токен вне
> Development), `Bot` (≥16 символов вне Development), `Trial` (непустая соль вне
> Development, положительная длительность). Проверки выполняются **до** обращения к БД,
> чтобы отсутствующий секрет не прятался за таймаутом соединения.

### 🟡 S6. Настройки JWT-валидации — ✅ Сделано (`820b1fe`)
**Где:** `Program.cs:40-49`.
- `ClockSkew` не задан → 5 мин по умолчанию, access фактически живёт 35 мин.
  Фикс: `ClockSkew = TimeSpan.FromSeconds(30)`.
- Не ограничен алгоритм: добавить `ValidAlgorithms = [HmacSha256]`.
- Нет `AddProblemDetails()` / `UseExceptionHandler` → в Development 500 отдаёт стек-трейс.

> **Как сделано:** все три пункта (`ClockSkew` 30 с, `ValidAlgorithms = [HmacSha256]`,
> `AddProblemDetails()` + `UseExceptionHandler()`).

### 🟡 S7. `pollToken` в query-string — ✅ Сделано (`820b1fe`)
**Где:** `PairController.cs:64-65`. Полноценный bearer-секрет в URL попадает в
access-логи прокси, APM-трейсы. **Фикс:** заголовок `X-Pair-Poll-Token` или
`POST /pair/status` с телом (согласовать с приложением).

> **Как сделано:** поддержан заголовок `X-Pair-Poll-Token`; query-форма оставлена ради
> уже выпущенных сборок приложения. Если ни того, ни другого нет — **400**.
> Приложению стоит перейти на заголовок.

### 🟡 S8. Нет обработки Forwarded-заголовков — ✅ Сделано (`820b1fe`)
**Где:** `Program.cs:67`. За Caddy `RemoteIpAddress` = IP прокси → per-IP rate limiter
(S1) схлопнет всех в один бакет, а `UseHttpsRedirection` даст редирект-цикл.
**Фикс:** `UseForwardedHeaders(XForwardedFor | XForwardedProto, KnownProxies=...)`
до остального middleware.

> **Как сделано:** `UseForwardedHeaders` первым в конвейере, список доверенных задаётся
> `ReverseProxy:KnownProxies`/`KnownNetworks` (дефолты «только loopback» **очищаются**,
> т. к. контейнерный прокси никогда не приходит с 127.0.0.1). В compose проставлено
> `172.16.0.0/12` (docker-мост). Если вне Development список пуст — в лог уходит warn.

### 🟡 S9. `Bot:Secret` — единый статический ключ ко всем `/internal/*` — 🟡 Частично (`820b1fe`)
**Где:** `InternalPairController.cs:19`, `InternalAccountController.cs:21`,
`InternalTokensController.cs:18`, `InternalTrialPoolController.cs:18,53`.
Сравнение корректное (constant-time), но: `/internal/account/subscription` не
проверяет владение (можно выставить любой `ExpiresAt` любому `TelegramUserId`);
`/internal/tokens` сбрасывает `BoundDeviceKeyHash`; проверка секрета скопипащена
в 4 контроллерах. **Фикс:** вынести в `AuthorizationHandler` +
`[Authorize(Policy = "Bot")]`, чтобы «забыть» в новом эндпоинте было нельзя.

> **Что сделано:** проверка вынесена в `BotSecretAuthorizationHandler` и применяется как
> `[Authorize(Policy = "Bot")]` на всех четырёх контроллерах; отказ логируется.
> **Что осталось:** владение по-прежнему не проверяется — обладатель `Bot:Secret` может
> выставить любую подписку любому `telegramUserId`, а `/internal/tokens` так же
> сбрасывает `BoundDeviceKeyHash` (это нужно для «Поменять ключ»). Менять контракт
> в одиночку нельзя — потребуется правка бота (`/opt/FatVPN`, вне репозитория).

### ✅ S10. DoS-векторы по размеру пейлоада — ✅ Закрыто (`820b1fe` + 2026-08-02)
- `InternalTrialPoolController.cs:64` — список идентификаторов без лимита количества.
- `TrialController.cs:120` — `AttestationToken` без ограничения длины (см. S3).
- `RemnawaveClient.cs:46` — `ReadAsStringAsync` без `MaxResponseContentBufferSize`.
**Фикс:** `[RequestSizeLimit]`, `MaxLength` в DTO, лимит размера ответа панели.

> **Что сделано:** `Kestrel.Limits.MaxRequestBodySize = 64 КБ` глобально, `StringLength`
> на всех DTO, лимит 500 id на вызов `/internal/trial-pool`.
> **Закрыто 2026-08-02:** ответ панели ограничен `RemnawaveClient.MaxResponseBytes`
> (4 МБ), выставляется на инжектируемый `HttpClient` рядом с таймаутом
> (`Program.cs`). Превышение прилетает как `HttpRequestException`, а его `CallAsync`
> уже переводит в `RemnawaveException` — то есть **502, а не 500** и не OOM.
> Тесты в `RemnawaveClientTests`: бесконечное тело без `Content-Length` обрывается
> (с проверкой счётчика прочитанного), подписка на 500 ссылок проходит.
> ⚠️ Проводка в DI тестом не покрыта — тест строит `HttpClient` с тем же потолком
> сам; выставление в `Program.cs` держится только на константе с общим именем.

### 🟢 Низкий риск / принять как есть
- CORS не настроен — для мобильного BFF это правильно (зафиксировать как решение).
- SQL-инъекций не найдено (везде параметризованный LINQ).
- Логирования секретов не найдено; обратная проблема — **аудита нет вообще**:
  неудачные `/auth/token`, срабатывания reuse-detection нигде не логируются.
  Добавить структурированные warn-логи. **✅ `820b1fe`:** добавлены warn-логи на
  отклонённый `/auth/token` (неизвестный/просроченный ключ, конфликт привязки),
  срабатывание reuse-detection, отказ бот-секрета и потерю гонки в `/trial`.

---

## 3. ПРОИЗВОДИТЕЛЬНОСТЬ

### 🟠 P1. `/servers` бьёт в панель на каждый запрос — ✅ Сделано (`820b1fe`)
**Где:** `ServersController.cs:32` → `RemnawaveClient.cs:13-38`. Ответ идентичен для
всех пользователей, но каждый pull-to-refresh = запрос к панели.
**Фикс:** `IMemoryCache`/`HybridCache` с TTL 30–60 с и защитой от stampede
(`GetOrCreateAsync`); `Cache-Control: private, max-age=60` в ответе.
`/config` — per-user, но тоже заслуживает короткого кеша по `subscriptionId` (10–30 с).

> **Как сделано:** `IMemoryCache`, TTL **45 с**, защита от stampede — `SemaphoreSlim`
> (single-flight), в ответе `Cache-Control: private, max-age=45`.
> **Иначе, чем предлагалось:** `/config` намеренно **не** кешируется — ответ
> персональный, несёт креденшелы подписки и запрашивается раз на коннект, а не на
> каждую перерисовку экрана.

### 🟠 P2. Отсутствующие индексы — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** ровно этот набор, миграция `20260727231711_AddPerformanceIndexes`.
> Плюс `20260727234554_AddRefreshTokenSessionStart` (колонка `SessionStartedAt` для
> абсолютного срока жизни сессии).

### 🟠 P3. Неограниченный рост таблиц, нет очистки — ✅ Сделано (`820b1fe`)
**Где:** `RefreshTokenService.cs:20-34`, `PairController.cs:43-53`.
Ротация добавляет строку на каждый `/auth/refresh` (~48 строк/устройство/сутки при
30-минутном access): 10 000 устройств ≈ 480 тыс. строк/день. `PairingCodes` растёт
на каждый `/pair/start` навсегда.
**Фикс:** `BackgroundService` с ежесуточным `ExecuteDeleteAsync`:
удалять refresh с `ExpiresAt < now - 30d` или `RevokedAt < now - 7d`;
pairing-коды с `ExpiresAt < now - 1d`. Требует индексов из P2.

> **Как сделано:** `ExpiredCredentialSweeper` (`BackgroundService`), интервал 24 ч,
> ровно предложенные сроки хранения (30 д / 7 д / 1 д). Первый прогон **не** на старте —
> иначе раскатка нескольких инстансов подметает одновременно. Сбой уборки не роняет API.

### 🟡 P4. `HttpClient` без таймаута и resilience — ✅ Сделано (`820b1fe`)
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

> **Как сделано:** таймаут 10 с и `PooledConnectionLifetime = 2 мин` — да.
> **`AddStandardResilienceHandler` намеренно НЕ добавлен:** его дефолтная политика
> ретраит в том числе POST'ы, а повторный `POST /api/users` оставит в панели
> осиротевшего триального юзера. Таймаут + переработка соединений — безопасная половина.

### 🟡 P5. Загрузка всей таблицы в память — ✅ Сделано (`820b1fe`)
**Где:** `InternalTrialPoolController.cs:23-26` — `ToListAsync()` всей
`TrialSubscriptionSlots` ради проверки нескольких id. **Фикс:** `Where(s =>
requested.Contains(s.RemnawaveSubscriptionId))`.

> **Как сделано:** предложенный `Where(... Contains ...)` + лимит 500 id на вызов (см. S10).

### 🟡 P6. Нет `AsNoTracking()` на read-only путях — ✅ Сделано (`820b1fe`)
**Где:** `SubscriptionResolver.cs:27,36` (`FindAsync` всегда tracked),
`MeController`, `ServersController`, `ConfigController`. `/me` и `/servers` — самые
частые эндпоинты. **Фикс:** `.AsNoTracking().FirstOrDefaultAsync(...)` в read-only
ветках.

> **Как сделано:** `SubscriptionResolver` полностью на `AsNoTracking().FirstOrDefaultAsync`
> (обе ветки), чем закрываются и `/me`, и `/servers`, и `/config`.

### 🟢 Прочее
- `JwtTokenService.cs:28,38` — новый `SymmetricSecurityKey` и `JwtSecurityTokenHandler`
  на каждый выпуск; закешировать ключ в поле, перейти на `JsonWebTokenHandler`.
  **✅ `820b1fe` частично:** `SigningCredentials` и `JwtSecurityTokenHandler` теперь
  создаются один раз; на `JsonWebTokenHandler` не переходили.
- `AuthController.cs:139-143` — `RevokeFamilyAsync` материализует семью и обновляет
  по одной; заменить одним `ExecuteUpdateAsync`. **✅ `820b1fe`.**
- `SubscriptionAugmenter.cs:44-64` — лишние аллокации (char[] размером с конфиг,
  StringBuilder, повторный Base64) на каждый `/config`. **⬜ Открыто:** в `820b1fe`
  трогали только источник хостов (вынос в конфиг), аллокации остались.
- `/health` (`Program.cs:72`) — безусловный `ok`; добавить
  `AddHealthChecks().AddDbContextCheck<FatVpnDbContext>()`. **✅ `820b1fe`:** форма ответа
  сохранена (`{"status":"ok"}`), при недоступной БД отдаётся `degraded`.
- Нет `AddResponseCompression` — gzip/brotli для `/servers` и `/config` сэкономит
  мобильный трафик. **✅ `820b1fe`.**

---

## Рекомендуемый порядок работ

> **Выполнено 2026-07-28 коммитом `820b1fe`:** пункты 1, 2 и 4 целиком, из пункта 3 —
> S4 и B3. Осталось только то, что упирается в инфраструктуру (см. ниже).

1. **Сейчас (дёшево, без изменения архитектуры):** S3 (валидация `attestationToken`),
   S5 (fail-fast секретов), B7 (`Guid.TryParse` + глобальный exception handler),
   P4 (таймаут HttpClient), S1 (rate limiter), P2 (миграция с индексами). — ✅
2. **Атомарность (одна итерация):** B1, B2, B6, B10 — везде заменить
   read-modify-write на `ExecuteUpdateAsync` с проверкой числа затронутых строк;
   B2 дополнительно — grace window для refresh (согласовать с retry-логикой приложения). — ✅
3. **Перед продом (блокеры):** S2 (HTTPS + HSTS + ForwardedHeaders), S4 (секреты из
   git и из образа), B3 (нормализация `DateTimeOffset` от бота). — 🟡 S4 и B3 сделаны;
   **HTTPS остаётся открытым** и упирается в домен.
4. **Долг:** P1/P3 (кеш + фоновая очистка), B4 (компенсация в Remnawave),
   B11 (Testcontainers + тесты на параллелизм). — ✅

**Осталось на BFF:**
1. **Домен + HTTPS** → включить `Security:RequireHttps`, выставить `AllowedHosts`,
   синхронно поменять `bffBaseUrl` в приложении (§1.1) — блокер релиза.
2. Задать `TRIAL_DEVICE_KEY_SALT` в env контейнера **до** деплоя `820b1fe`.
3. Ротировать пароль Postgres (S4, остаток).
4. Решить S9 (проверка владения в `/internal/*`) вместе с правкой бота.
5. ~~`MaxResponseContentBufferSize` на ответы панели (S10, остаток).~~ — ✅ 2026-08-02.
6. Аллокации в `SubscriptionAugmenter`.

**Критерий приёмки:** `dotnet build` + все тесты зелёные; новые интеграционные тесты
на B1/B2/B5 (параллельные вызовы) проходят; ручная проверка через
`FatVpn.Bff.Api.http` — коды ответов не изменились для happy-path.

> Приёмка `820b1fe`: 102 теста. `ConcurrencyIntegrationTests` требуют Docker и
> **скипаются** без него — на машине без Docker зелёный прогон **не** доказывает,
> что гонки закрыты. Проверять с поднятым Docker.
