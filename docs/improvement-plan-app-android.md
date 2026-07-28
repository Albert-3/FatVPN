# План доработок — Flutter-приложение и Android

> **Назначение документа:** техзадание для исполнителя (Claude Opus). Аудит проведён
> 2026-07-27 по коду `master`. Охват: `app/lib/`, `app/packages/singbox_mm/` (Dart +
> Kotlin), `app/android/` (manifest, gradle, proguard).
>
> Смежные документы: `docs/improvement-plan-bff.md`, `docs/improvement-plan-ios.md`.
> Часть находок в Dart-коде общая с iOS (файлы `singbox_config_builder.dart`,
> `singbox_inbound_builder.dart`) — помечено значком 🔗.

## Сводка по критичности

| Крит. | Кол-во | Ключевые темы |
|---|---|---|
| **Critical** | 5 | HTTP вместо HTTPS, release подписан debug-ключом, потеря ротированного refresh-токена → reuse detection, APK ~236 МБ, `usesCleartextTraffic=true` |
| **High** | 12 | Гонка в `_ensureInitialized` (утечка подписки), VPN не выключается при sign-out, `allowBackup` по умолчанию, устаревшее допущение о self-bypass в PingService, clash_api без секрета, `setState` после dispose |
| **Medium** | 20 | Последовательные пинги, лишние запросы к BFF, polling 2 с, тик уведомления 1 с, base64 edge-cases, локализация, exact-alarm на старте, утечки `http.Client` |
| **Low** | 8 | Незакодированный query-параметр, MethodChannel без cleanup и т. п. |

## Статус на 2026-07-28

Сверено **по диффу** рабочего дерева ветки `fix/bff-audit-remediation`, а не по списку
задач. Пометка «рабочее дерево» = правка есть, но **ещё не закоммичена**.

**Измерено (не заявлено):** `flutter analyze` чисто и в `app/`, и в
`app/packages/singbox_mm/`. Тесты — **107 passed / 1 skipped / 0 failed** в `app/` (было
69 passed / 1 failed) и **168 passed** в плагине, итого **275**, зелено в обычном
параллельном режиме три прогона подряд, без флаков. Единственный skip намеренный и
подписан: в `audit_usable_servers_test.dart` он фиксирует **открытый вопрос** — должен ли
5xx от `/config` откатываться на `/servers` (§2.9 требует только 401/402).
`flutter build appbundle --release` собирается и подписывается настоящим ключом.

⚠️ **На устройстве не проверено ничего.** Всё, что ниже, — статический результат;
приёмка отдельным разделом **2a** в `docs/release-test-checklist.md`.

| § | Статус | Комментарий |
|---|---|---|
| 1.1 HTTPS | 🟡 частично | `usesCleartextTraffic="true"` убран, добавлен `res/xml/network_security_config.xml`: база `cleartextTrafficPermitted="false"`, два явных исключения — тестовый BFF `87.121.221.229` и loopback (clash-probe). **Самого HTTPS нет — нет домена** (общий блокер, см. `-bff.md` S2). ⚠️ В `app/ios/Runner/Info.plist` `NSAppTransportSecurity` по-прежнему отсутствует |
| 1.2 Certificate pinning | ⬜ отложено | Пинить нечего до перехода на HTTPS |
| 1.3 Release keystore | ✅ `cfe1f2b` | Креды в `android/key.properties` (в `.gitignore`); без файла сборка **осознанно** откатывается на debug-ключ и пишет об этом — перед публикацией проверять `signingReport` |
| 1.4 `allowBackup` | ✅ `901ea73` | Было закрыто **до** начала этих работ: `android:allowBackup="false"` + полный `data_extraction_rules.xml` (закрывает и device-to-device перенос на Android 12+). К моменту доработок делать было нечего — см. правку текста находки |
| 1.5 secure storage | ✅ `901ea73` + рабочее дерево | Обе половины: `AndroidOptions(encryptedSharedPreferences: true)` включён, и `SecureStore` **затирает** недешифруемое хранилище вместо падения (реальный симптом на Redmi Note 7 — вечный сплэш). ⚠️ Смена бэкенда требует проверки **обновлением поверх старой установки**, а не чистой — см. «Открытые вопросы» ниже |
| 1.6 Clash API без секрета | ✅ рабочее дерево | 128-битный секрет из `Random.secure()` на **каждый** старт туннеля, кладётся в `experimental.clash_api.secret` и читается обратно всеми тремя потребителями: `VpnTunnelHealthProbe.kt`, `TunnelHealthWatchdog.swift`, `vpn_controller._singboxApiGet`. Секрет сохраняется в secure storage — приложение, перезапущенное поверх живого туннеля, продолжает его опрашивать. Закрывает и iOS 2.2. Порт остался фиксированным `16756` |
| 1.7 `stderr.log` на внешнем хранилище | ✅ рабочее дерево | `workingPath` переехал с `getExternalFilesDir(null)` на `context.filesDir` — вместе с ним ушли с `/sdcard` и `stderr.log`, и рабочая директория libbox. Ротация лога по размеру и «писать только в диагностическом режиме» **не** сделаны |
| 1.8 `attestationToken` | ⬜ не бралось | Rate-limit на BFF готов (`820b1fe`, 5/час на IP) + валидация длины; Play Integrity / App Attest не пробовали |
| 1.9 Санитайзер диагностики | ✅ рабочее дерево | Новый `app/lib/utils/sanitize.dart` (`sanitizeDiagnostics`): UUID, `password=`/`pbk=`/`sid=`/`auth=`, `credential@host`, `ip:port`. Прогоняется в `vpn_controller` перед `log.e` и перед показом в UI — то есть до попадания в support-bundle |
| 1.10 Подтверждение deep-link | ✅ рабочее дерево | Ключ из `fatvpn://` больше не обменивается молча: `pendingDeepLinkToken` + `confirmPendingDeepLinkToken`/`dismissPendingDeepLinkToken`, строки `deepLinkKeyTitle`/`deepLinkKeyBody` |
| 2.1 Потеря ротированного refresh | ✅ рабочее дерево | `await _tokenStorage.save(fresh)` **до** смены состояния в памяти, ошибка записи больше не глотается. Парная правка на BFF сделана (`820b1fe`, grace-окно 30 с) |
| 2.2 Захват `accessToken` аргументом | ✅ рабочее дерево | `ApiClient` получает провайдер `readAccessToken`, аргумент-токен убран из всех методов; провайдер — `AuthController.currentAccessToken` |
| 2.3 Гонка `_ensureInitialized` | ✅ рабочее дерево | `_initFuture ??= _doInitialize()` + `await _stateSubscription?.cancel()` перед новым `listen` |
| 2.4 Sign-out не выключает туннель | ✅ рабочее дерево | Коллбэк `AuthController.onSessionDropped`, вызывается **первым** в `signOut()`; `HomeScreen` его подписывает и снимает в `dispose()`. Покрывает и автоматический sign-out по 401 |
| 2.5 Пинг на Android | ✅ рабочее дерево | ⚠️ Аудит недооценил объём: `pingServerOutsideTunnel` на Android **не существовал вовсе**, был только объявлен — предложенный «убрать ветвление в `ping_service.dart:32`» уронил бы всё в `MissingPluginException`. Нативную часть написали с нуля: `bind(0)` → `VpnServiceLiveness.active?.protect(socket)` → `connect`. Комментарии, противоречившие `VpnTunBuilderConfigurator`, переписаны |
| 2.6 `setState` без `mounted` | ✅ рабочее дерево | Гарды после каждого `await` и безопасное чтение сессии — и в `home_screen.dart`, и в `choose_location_screen.dart`; force unwrap `session!` убран |
| 2.7 Парсер `/config` | ✅ рабочее дерево | `base64.normalize` + вычистка пробелов/переносов, фолбэк на plain text, лог `config parse: N raw → M supported`. ⚠️ Пункт аудита про **URL-safe алфавит оказался неверным** — см. правку текста находки. `Content-Type` по-прежнему игнорируется, но фолбэк делает это безвредным |
| 2.8 `findUriForNode` по хосту | ✅ рабочее дерево | Приоритет схем `vless > trojan > hysteria2/hy2`, остальные — в хвост; выбор стал детерминированным |
| 2.9 `getUsableServers` глотает 402 | ✅ рабочее дерево | `on ApiException` с `rethrow` для 401/402; сетевой фолбэк на «сырой» `/servers` сохранён. Открытый вопрос (единственный skip в тестах): что делать с **5xx** от `/config` — откатываться на `/servers` или пробрасывать |
| 2.10 Локализация | ✅ в основном (рабочее дерево) | `ApiException` больше не носит прозу — только машинный `code` + `statusCode`; `exchangeShortToken`/`startPairing` принимают локализованные сообщения обязательными параметрами. Проверить точечно, не остался ли сырой `StateError` из `vpn_controller` |
| 2.11 Flush логов | ✅ рабочее дерево | Периодический flush (2 с) + обязательный flush на `LogLevel.error`; обещание «краш не теряет след» наконец соответствует коду |
| 2.12 Exact alarms на старте | ✅ рабочее дерево | `requestExactAlarmsPermission` убран вместе с `SCHEDULE_EXACT_ALARM` из манифеста, минутные напоминания стали inexact; `POST_NOTIFICATIONS` теперь спрашивается **только когда подписка активна**, а не на сплэше. Закрывает находку №3 прогона |
| 2.13 `_pollOnce` без счётчика | ✅ рабочее дерево | `_maxPollFailures = 5`, жёсткий стоп по `PairingStart.expiresAt` (поле наконец используется), `_failPairing(expired:)` разводит «код истёк» и «не отвечает» |
| 2.14 Кеш `_lastGoodConfig` | ✅ рабочее дерево | Один `ApiClient` на приложение (`AuthController.api`), кеш в `_Cached<T>` с привязкой к `sessionMintedAt` — при смене ключа сбрасывается |
| 2.15 `_waitForDisconnected` | ✅ рабочее дерево | Ожидание события из `stateStream` (`firstWhere(...).timeout(10 s)`) вместо busy-wait; дубликат в `home_screen` заменён вызовом общего `VpnController.waitForDisconnected()`; истечение дедлайна логируется |
| 2.17 Мелочи | ✅ рабочее дерево | `pollToken` кодируется (`Uri.replace(queryParameters:)`); в `MainActivity.kt` обработчик снимается в `cleanUpFlutterEngine`, поток на вызов заменён одним daemon-executor'ом |
| 3.1 Размер APK | ✅ рабочее дерево, **измерено** | AAB **138.6 МБ** на диске, из них 70.3 МБ — debug-символы, которые Play не раздаёт; скачивание на устройство **35.0 МБ** (arm64) / **34.6 МБ** (arm32), сплиты x86/x86_64 — 0 байт. Лимит base-модуля 200 МБ закрыт с запасом. ⚠️ **Способ, предложенный аудитом, не работает** — см. правку текста находки. `with_tailscale`/`with_grpc`/… из libbox не выпиливали (нужен Go-тулчейн) — это отложенный резерв ещё в 30-50 % |
| 3.2 Последовательный `_pickBestNode` | ✅ рабочее дерево (со второго захода) | `mapConcurrently` (общий пул, 6 одновременных) вместо `await` в цикле. ⚠️ Первая версия правки была **регрессией** — подробности в находке **N1** ниже |
| 3.3 Пинги на экране локаций | ✅ рабочее дерево | Тот же `mapConcurrently` + один `setState` на пачку вместо перерисовки на каждую ноду |
| 3.4 Лишние запросы к BFF | 🟡 в основном (рабочее дерево) | Единый `ApiClient` с кешем `/servers` и `/config` (TTL 5 мин, сброс по `sessionMintedAt`) + рефреш **по сроку токена**: `AuthSession.accessTokenExpiresAt`, а если сервер его не прислал (`/pair/status`, `/trial`) — `exp` из самого JWT; запас 2 мин. Срок JWT теперь и хранится отдельно (`access_jwt_expires_at`), так что холодный старт не рефрешит вслепую. **Рефреш на старте и на resume оставлен сознательно** — см. «Открытые вопросы» |
| 3.5 Тик уведомления 1 с | ✅ рабочее дерево | `NOTIFICATION_STATS_INTERVAL_MS` 1000 → **3000** мс (8-часовая сессия: 9 600 пересборок вместо 28 800) + `notifyIfChanged` — `notify()` пропускается, если заголовок/текст/подзаголовок не изменились. Остановку тикера по `ACTION_SCREEN_OFF` не делали |
| 3.6 Секундный `setState` главного экрана | ✅ рабочее дерево | Таймер в `ValueNotifier<Duration>` + `ValueListenableBuilder` вокруг одного `Text`; `_rankedServers` кешируется, а не сортируется на каждом кадре |
| 3.7 15 последовательных чтений storage | ✅ рабочее дерево | Все три места переведены на `Future.wait`: `connection_settings_controller.load()` (11 чтений одной пачкой), `TokenStorage.read()`/`save()` (4 значения), `vpn_controller._doInitialize` (2). Перенос несекретных значений в `SharedPreferences` не делали — цепочки ожидания больше нет и без этого |
| 3.8 Опрос `/pair/status` без бэк-оффа | ✅ рабочее дерево | Бэк-офф 2 → 3 → 5 с, пауза/возобновление через `setPairingPaused` (с немедленным `_pollOnce` на возврате), `AwaitingAuthScreen.dispose()` останавливает опрос |
| 3.9 Всплеск параллельных TCP | ✅ рабочее дерево | Декартово произведение «страна × нода» разворачивается в один плоский список и идёт через общий бюджет в 6 соединений |
| 3.10 `http.Client` не закрывается | ✅ рабочее дерево | `ApiClient.close()` добавлен, клиент теперь один на приложение — экраны больше не заводят свои пулы |
| 3.11 Иконки приложений одним сообщением | 🟡 частично | Иконки идут WEBP q80 вместо PNG q100, в `Image.memory` добавлены `cacheWidth/cacheHeight: 72` и `filterQuality: low` (было 7 МБ декодированных битмапов на 200 приложений). **Ленивая догрузка иконок вторым каналом по `packageName` отложена сознательно** — это переписывание экрана, а не точечная правка |
| 3.12 Интервал watchdog'а | ✅ рабочее дерево | Адаптивная каденция: 60 с после старта, **180 с** после 5 здоровых проверок (`SETTLED_INTERVAL_MS`, `HEALTHY_CHECKS_BEFORE_SETTLING`), любой провал возвращает к тесному интервалу. Backoff 300 с после серии неудачных восстановлений сохранён |
| 3.13 Дублирующий health-контур в Dart | ⬜ отложено | Прокинуть вердикт нативного watchdog'а через `stateDetailsStream` — это **новая нативная поверхность на обеих платформах**, и проверить её без устройства нельзя. `_sessionHealthInterval` остался 3 мин |

**Блокеры релиза из §5, оставшиеся открытыми:** только п. 1 (HTTPS — нет домена).
Пункты 2–5 закрыты и проверены: подпись (`cfe1f2b`), `allowBackup` (`901ea73`),
`await` на refresh и размер AAB — последний **измерен**, а не «сделан».

### Найдено при доработке — этого в аудите не было

Обе находки поймал прогон тестов, а не чтение кода; обе исправлены вторым заходом.

#### 🔴 N1. Параллельные пинги на Android оказались **медленнее** последовательных
Первая версия фикса §3.2 была чистой регрессией. `pingServerOutsideTunnel` блокировался
на `Future.get` (~4.2 с на недоступную ноду), сидя при этом на **общем**
`Executors.newSingleThreadExecutor()` плагина. Шесть «параллельных» пингов
`mapConcurrently` сериализовались на одном потоке: **~25 с на шесть недоступных нод
против ~18 с** у старого последовательного кода. Хуже того, за очередью пингов вставали
`connectManualConfigLink` и `stop()` — то есть **каждое нажатие «Подключить»**.

**Фикс:** оба ping-метода уехали на `pingExecutor`, дедлайн вынесен в колбэк
daemon-планировщика с `AtomicBoolean settled`, `PING_EXECUTOR_THREADS` 4 → **8**, чтобы
перекрыть шестиместный лимит `mapConcurrently`. Проверено, что других блокирующих
ожиданий на общем executor'е не осталось.

**Мораль для будущих правок:** «сделать параллельно» на Dart-стороне ничего не значит,
пока нативная сторона исполняет вызовы на одном потоке.

#### 🟠 N2. `_liveUserCounts` тихо перестал быть «live» из-за кеша §3.4
Кеш `/servers` на 5 минут из §3.4 длиннее, чем интервал раундов авто-переключения
(3 мин), поэтому `_liveUserCounts` начал раз за разом перечитывать ответ предыдущего
раунда — при том что его собственный докблок обещал свежий запрос. Загрузка нод,
на которую опирается вся политика crowding, стала фикцией.

**Фикс:** `getServers(force: true)` — кеш при этом **заполняется**, так что экономия
запросов из §3.4 сохраняется, — и честный докблок.

### Открытые вопросы (это не баги, решать продуктово)

1. **Рефреш на холодном старте и на resume оставлен намеренно**, хотя §3.4 предлагала его
   убрать. Именно он подтягивает срок **подписки**: без него пользователь, продливший
   ключ в Telegram, останется заперт на экране продления. Убирать можно только после
   того, как появится более дешёвый способ узнавать статус подписки. Дорогая часть §3.4
   (лишние `/servers` + `/config` на каждом экране, ротация по расписанию) закрыта и без
   этого.
2. **`encryptedSharedPreferences: true` меняет бэкенд secure storage.** Плагин мигрирует
   значения сам, но неудачная миграция выбрасывает пользователя в онбординг. Значит
   проверять это надо **обновлением поверх старой установки**, а не чистой установкой —
   вынесено отдельным пунктом в `docs/release-test-checklist.md`.
3. **5xx от `/config`** (§2.9): откатываться на `/servers` или пробрасывать наверх?
   Сейчас откатываемся. Вопрос зафиксирован единственным `skip`-тестом в
   `app/test/audit_usable_servers_test.dart`, чтобы не потерялся.

---

## 1. БЕЗОПАСНОСТЬ

### 🔴 1.1 BFF работает по HTTP — токены и конфиги идут в открытом виде — 🟡 Частично
**Где:** `app/lib/config/api_config.dart:4` (`http://87.121.221.229:5030`),
`app/android/app/src/main/AndroidManifest.xml:16` (`android:usesCleartextTraffic="true"`)

По этому каналу передаётся всё самое чувствительное:
- `POST /auth/token`, `/auth/refresh`, `/trial`, `/pair/status` → **access + refresh JWT
  в plaintext**;
- `GET /config` → **вся подписка Remnawave** (vless:// с UUID, trojan-пароли,
  hysteria2 obfs) в base64 — это кодирование, а не шифрование;
- `attestationToken` устройства.

Любой на пути (Wi-Fi точка, провайдер, DPI) читает это и **полностью угоняет подписку и
сессию**. Для VPN-приложения это разрушает всю модель угроз продукта. Усугубляет то, что
до подключения туннеля (а именно тогда идут `/auth/*`, `/trial`, `/servers`, первый
`/config`) трафик идёт по реальной сети пользователя без защиты. Флаг
`usesCleartextTraffic="true"` глобальный — снимает защиту для любых http-запросов.

⚠️ **Скрытый блокер для iOS:** в `app/ios/Runner/Info.plist` нет `NSAppTransportSecurity`
— значит iOS-сборка вообще не сможет достучаться до BFF по HTTP.

**Фикс:** поднять HTTPS-домен (см. `docs/improvement-plan-bff.md` S2), поменять
`bffBaseUrl`; убрать `usesCleartextTraffic`, добавить
`res/xml/network_security_config.xml` с `cleartextTrafficPermitted="false"` и явным
`<domain-config>` только для `127.0.0.1` (нужен для clash-api probe).

> **Сделано:** манифест переведён на `networkSecurityConfig` с базой
> `cleartextTrafficPermitted="false"`; исключений ровно два — тестовый BFF
> `87.121.221.229` и loopback. Смысл в том, что новый endpoint, добавленный по ошибке,
> теперь **падает громко**, а не шлёт токены открытым текстом.
> **Осталось:** сам HTTPS — нужен домен с сертификатом; тогда исчезают обе записи разом,
> меняется `bffBaseUrl` и включается `Security:RequireHttps` на BFF.
> ⚠️ Скрытый блокер iOS **не закрыт**: `NSAppTransportSecurity` в `Info.plist` так и нет.

### 🟠 1.2 Полностью отсутствует certificate pinning — ⬜ Отложено (нечего пинить до HTTPS)
**Где:** `app/lib/services/api_client.dart:29` — обычный `http.Client()`.
Даже после перехода на HTTPS клиент доверяет системному trust store: корпоративный/MDM
профиль или root-устройство ставят CA в system store; скомпрометированный публичный CA
выдаёт валидный сертификат. Для VPN-клиента, где перехват `/config` = кража платной
подписки, это неприемлемо.
**Фикс:** `HttpClient` с `badCertificateCallback` + сверка SPKI-пина (SHA-256 публичного
ключа) либо `certificate_pinning_interceptor`. Пинить два ключа (текущий + backup) и
предусмотреть механизм обновления.

### 🔴 1.3 Release-сборка подписана debug-ключом — ✅ Сделано (`cfe1f2b`)
**Где:** `app/android/app/build.gradle.kts:31-34`

```kotlin
release {
    // TODO: Add your own signing config for the release build.
    signingConfig = signingConfigs.getByName("debug")
```

Debug-keystore публично известен (`~/.android/debug.keystore`, пароль `android`). Любой
может собрать APK с той же подписью и **подменить приложение через sideload**, унаследовав
`signature`-уровневый permission `${applicationId}.permission.SIGNBOX_STATE`
(`packages/singbox_mm/android/src/main/AndroidManifest.xml:3-5`) — то есть получить доступ
к broadcast'ам состояния VPN. Загрузка в Google Play невозможна.
**Фикс:** release keystore, креды в `key.properties` (в `.gitignore`),
`signingConfigs.create("release")`, включить Play App Signing.

> **Сделано ровно так.** ⚠️ Важная оговорка: если `android/key.properties` отсутствует
> (свежий клон, CI), сборка **осознанно** откатывается на debug-ключ и пишет об этом в
> лог — чтобы `flutter run --release` работал везде. Значит перед публикацией мало
> «собралось»: надо убедиться, что подпись действительно релизная (см. T4 в
> `docs/release-test-checklist.md`). Play App Signing — отдельный шаг в консоли.

### 🟠 1.4 `allowBackup` по умолчанию `true` — конфиг с креденшелами уезжает в облако — ✅ Сделано (`901ea73`)

> ⚠️ **Находка успела устареть между аудитом и работами.** Она была верна на момент
> аудита (2026-07-27), но уже 2026-07-28 коммит `901ea73` добавил и
> `android:allowBackup="false"`, и полный `data_extraction_rules.xml`. К началу
> доработок по этому пункту делать было нечего — проверяйте манифест, прежде чем
> «чинить» его снова.

**Где:** `app/android/app/src/main/AndroidManifest.xml:12-16` — в `<application>` нет ни
`allowBackup="false"`, ни `fullBackupContent`, ни `dataExtractionRules`.

Auto Backup по умолчанию забирает `filesDir` целиком, а туда пишется:
- `PluginRuntimeConfigStore.kt:38,52,98-118` → `filesDir/singbox/active-config.json` —
  **полный sing-box конфиг с UUID/паролем outbound'а открытым текстом**;
- `RuntimeStateStore` SharedPreferences (`signbox_mm_runtime`) с `configPath`;
- зашифрованный блоб `flutter_secure_storage` (см. 1.5).

Подписка пользователя утекает в Google Drive и извлекается восстановлением на другое
устройство. Обратите внимание: `PluginRuntimeConfigStore.applyOwnerOnlyPermissions()`
(строки 120-126) аккуратно ставит 0600 на файл — и весь этот труд обнуляется бэкапом.

**Фикс:** `android:allowBackup="false"` (либо `dataExtractionRules` с
`<exclude domain="file" path="singbox/"/>` и
`<exclude domain="sharedpref" path="signbox_mm_runtime.xml"/>`).

### 🟡 1.5 `flutter_secure_storage` без `AndroidOptions(encryptedSharedPreferences: true)` — ✅ Сделано (`901ea73` + рабочее дерево)
**Где:** `token_storage.dart:8-9`, `vpn_controller.dart:36`,
`connection_settings_controller.dart:44`, `locale_controller.dart:8`. Поиск
`encryptedSharedPreferences` по `lib/` — 0 совпадений.

В `flutter_secure_storage` 9.x дефолт на Android — legacy-режим: значения шифруются
RSA-ключом из Keystore и складываются в обычные `SharedPreferences`. Известны баги
legacy-пути с потерей ключа после обновления ОС/восстановления бэкапа →
`PlatformException` и «вылет» сессии. В связке с 1.4 зашифрованный блоб бэкапится, а
ключ Keystore — нет → после restore пользователь получает нечитаемое хранилище вместо
чистого состояния.
**Фикс:** `const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true))`
+ graceful fallback на `PlatformException`.

> **Сделана вторая половина:** обёртка `SecureStore` (`app/lib/services/secure_store.dart`)
> трактует нечитаемое хранилище как пустое и **затирает** его, вместо того чтобы бросать.
> Предсказанный аудитом сценарий подтвердился на живом устройстве (Redmi Note 7,
> 2026-07-28): восстановленный бэкап чужой установки давал `BAD_DECRYPT` на каждом
> чтении, `AuthController.start` не выходил из `_initializing`, приложение навсегда
> оставалось на сплэше.
> **Вторая половина тоже сделана:** `SecureStore` теперь конструирует
> `FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true))`.
> Плагин мигрирует уже записанные значения при первом обращении, а то, что не
> смигрировало, подберёт та же логика затирания.
> ⚠️ **Как это проверять:** только **обновлением поверх старой установки**. Чистая
> установка проходит по определению и ничего не доказывает; провалившаяся миграция
> выглядит как выброс пользователя в онбординг с потерей платной сессии.

### 🟠 1.6 🔗 Локальный clash-API открыт без секрета — любое приложение управляет VPN — ✅ Сделано (рабочее дерево)
**Где:** `app/packages/singbox_mm/lib/src/config/singbox_config_builder.dart:129-133`;
порт по умолчанию `16756` (`singbox_feature_settings.dart:704`). Поле `secret` не
задаётся нигде.

На Android loopback **не изолирован между приложениями**. Любое приложение с `INTERNET`
может обратиться к `http://127.0.0.1:16756/` и через Clash API:
- `GET /proxies` → узнать активный сервер/тег подписки;
- `GET /connections` → **полный лог посещённых доменов в реальном времени** (фактически
  история браузинга);
- `PATCH /configs` → переключить режим маршрутизации / выключить проксирование →
  **деанонимизация пользователя без его ведома**.

Это самая серьёзная нативная дыра в проекте. 🔗 Файл общий с iOS — фикс закрывает обе
платформы (см. `docs/improvement-plan-ios.md` 2.2).

**Фикс:** генерировать случайный `secret` на каждый запуск туннеля, класть в конфиг и
передавать в `Authorization: Bearer` из `VpnTunnelHealthProbe.httpGet`
(`VpnTunnelHealthProbe.kt:154`) и из `VpnController._probeViaSingboxApi`
(`vpn_controller.dart:458-482`). Ещё лучше — отключить `clash_api` в production и
заменить health-probe на прямой вызов libbox (`CommandClient`), не открывая TCP-порт.

> **Сделано по первому варианту** (порт остаётся, но за секретом): 128 бит из
> `Random.secure()` генерируются на **каждый** старт туннеля, уходят в
> `experimental.clash_api.secret`, и все три потребителя шлют `Authorization: Bearer`.
> Секрет дополнительно сохраняется в secure storage под `vpn_clash_api_secret` —
> приложение, перезапущенное поверх уже работающего туннеля, иначе не смогло бы его
> опросить. Нативные пробы читают секрет **из самого конфига**, поэтому конфиг, записанный
> до этой правки, продолжает работать (секрет = null). Новый секрет на каждый connect
> означает, что утёкшее в support-bundle значение протухает при следующем подключении.
> Закрывает и iOS 2.2. **Не сделано:** порт по-прежнему фиксированный `16756`, переход на
> `CommandClient` без TCP-порта не рассматривался.

### 🟡 1.7 `stderr.log` sing-box пишется на внешнее хранилище — ✅ Сделано (рабочее дерево)
**Где:** `VpnCoreSetupManager.kt:25,36` — `context.getExternalFilesDir(null)`, то есть
`/sdcard/Android/data/<pkg>/`: на API ≤ 28 читается любым приложением с
`READ_EXTERNAL_STORAGE`, на любом API доступен через MTP/adb без root и **всегда попадает
в бэкап**. Содержимое: адреса/порты нод, SNI, DNS-запросы, ошибки хендшейка — карта
инфраструктуры и активность пользователя. Там же лежит рабочая директория libbox
(кэши geo-правил, `cache.db`).
**Фикс:** `context.filesDir` (или `noBackupFilesDir`), ротация `stderr.log` по размеру,
запись только при включённом диагностическом режиме.

> **Сделан первый пункт:** `workingPath` = `context.filesDir` (был
> `getExternalFilesDir(null)`), так что и лог, и рабочая директория libbox ушли с
> `/sdcard`; бэкап их не заберёт (§1.4 уже выключен). **Ротация по размеру и запись
> только в диагностическом режиме — не сделаны.**

### 🟡 1.8 `attestationToken` — обычный локальный random, тривиально фармится — ⬜ Не бралось
**Где:** `token_storage.dart:36-44` — 32 случайных байта, сгенерированных на клиенте;
отправляется в `POST /trial` (`api_client.dart:133-140`) и `POST /auth/token`
(`api_client.dart:113-118`). Следствия: **бесконечный фарм триалов** (переустановка даёт
новый ключ; злоумышленнику даже не нужно приложение — достаточно `curl` с рандомным hex);
привязка «один ключ = один телефон» обходится копированием device key.
Комментарий в коде это признаёт, но экономический риск (пул триалов, `503` при
исчерпании — `api_client.dart:132`) реален уже сейчас.
**Фикс:** Play Integrity API (Android) / DeviceCheck+App Attest (iOS) с верификацией
nonce на BFF. До этого — rate-limit по IP на `/trial` (см.
`docs/improvement-plan-bff.md` S1) и device key из `Settings.Secure.ANDROID_ID` +
Keystore-attested ключа.

### 🟡 1.9 Диагностика тянет в support-bundle инфраструктурные данные — ✅ Сделано (рабочее дерево)
**Где:** `vpn_controller.dart:857-886` (`log.e('Tunnel failed at runtime', err)`),
bundle собирается в `app_logger.dart:142-186` и шарится через OS-share sheet
(`:194-213`), то есть может уйти в любой мессенджер. `getLastError` — это хвост stderr
sing-box; там регулярно встречаются `outbound/vless[tag] ... dial tcp <IP>:<port>`, SNI,
Reality public key. Токены замаскированы корректно (`settings_screen.dart:177-181`), а
конфиг — нет.
**Фикс:** прогонять `err` через санитайзер (регэкспы на `uuid`, `password=`, `@host:port`,
`pbk=`, `sid=`) перед `log.e` и перед показом в UI.

> **Сделано ровно так.** Новый `app/lib/utils/sanitize.dart` — `sanitizeDiagnostics()`
> вычищает UUID, `password=`/`pbk=`/`sid=`/`obfs-password=`/`auth=`, `credential@host` и
> голые `ip:port`; вызывается в `vpn_controller` и перед `log.e`, и перед показом текста
> пользователю, то есть до попадания в шаренный support-bundle. Правило выбрано
> намеренно грубым: пере-редактирование стоит инженеру поддержки контекста,
> недо-редактирование стоит пользователю подписки.
> **Проверять на устройстве** (T-пункт про санитайзер): в собранном бандле не должно
> быть ни `vless://`-строк, ни адресов нод.

### 🟢 1.10 Экспортированные компоненты — проверено, замечаний почти нет
- `MainActivity` `exported="true"` — обязательно для LAUNCHER. ОК.
- Ресиверы `flutterlocalnotifications` — `exported="false"`. ОК.
- `SignboxLibboxVpnService` — `exported="false"` + `permission="android.permission.BIND_VPN_SERVICE"`. ОК.
- State-broadcast защищён `signature`-permission и `RECEIVER_NOT_EXPORTED`. Хорошая работа.
- `<queries>` без `QUERY_ALL_PACKAGES`. Хорошо.
- ⚠️ **Одно замечание (medium):** deep-link `fatvpn://` (`AndroidManifest.xml:48-53`) —
  обработчик `AuthController._handleUri` (`auth_controller.dart:338-347`) принимает любой
  `shortToken` из любого приложения. Обмен проверяется BFF, так что напрямую это ничего
  не даёт, но позволяет **навязать пользователю чужой ключ** (session fixation):
  вредоносное приложение шлёт `fatvpn://token/XXXX` и молча переключает жертву на
  подконтрольную подписку → весь трафик идёт через сервер атакующего.
  **Фикс:** показывать подтверждение перед обменом токена, полученного из внешнего интента.
  **✅ Сделано (рабочее дерево):** `_handleUri` больше не обменивает ключ, а кладёт его в
  `pendingDeepLinkToken` и уведомляет UI; обмен идёт только через
  `confirmPendingDeepLinkToken`, отказ — через `dismissPendingDeepLinkToken` (пишется в
  лог). Тексты — `deepLinkKeyTitle` / `deepLinkKeyBody(keyCode)` в `Strings`, EN и RU.

---

## 2. БАГИ

### 🔴 2.1 Ротированный refresh-токен сохраняется fire-and-forget → reuse detection убивает сессию — ✅ Сделано (рабочее дерево)
**Где:** `app/lib/services/auth_controller.dart:193-218`

```dart
final fresh = await _apiClient.refreshSession(refreshToken);
_session = fresh;
notifyListeners();
unawaited(_tokenStorage.save(fresh).catchError((_) {}));   // ← строка 204
```

Сервер (`backend/.../AuthController.cs:68-80,109-113,137-143`) реализует rotation +
reuse detection с отзывом **всего семейства**.

**Воспроизводимый сценарий отказа:**
1. Холодный старт: `auth_controller.dart:148-150` безусловно запускает `_refreshNow()`.
2. Сервер отзывает RT1, выдаёт RT2, отвечает 200.
3. Клиент выставляет `_session = fresh` **в памяти**, а запись на диск запускает **без
   `await` и с проглатыванием ошибки**.
4. Процесс убивают (свайп из recents во время сплэша, low-memory kill, краш) **до**
   завершения записи в Keystore — окно реальное, запись идёт через платформенный канал.
5. Следующий запуск читает **RT1** → `/auth/refresh` → сервер видит `RevokedAt != null`
   → `RevokeFamilyAsync` отзывает всё семейство → 401 → `signOut()`.
6. Пользователь **теряет платную подписку в приложении** и вынужден заново пэйриться.

Тот же риск даёт `catchError((_) {})`: если запись упала (см. 1.5 — legacy-режим secure
storage умеет падать после обновления ОС), это молча игнорируется и на следующем старте
гарантированно предъявляется отозванный токен.

**Фикс:** сначала диск, потом состояние:

```dart
final fresh = await _apiClient.refreshSession(refreshToken);
try {
  await _tokenStorage.save(fresh);
} catch (e) {
  log.e('Failed to persist rotated session', e);
  rethrow;              // не отдавать fresh наружу как «успех»
}
_session = fresh;
notifyListeners();
```

Парная правка на BFF — grace-период ~30 с для повторного предъявления только что
отозванного токена (см. `docs/improvement-plan-bff.md` B2), снимает класс проблемы целиком.

> **Сделано ровно так, обе половины.** В приложении: `await _tokenStorage.save(fresh)`
> идёт **до** `_session = fresh`, а провал записи больше не глотается — refresh
> считается неуспешным, старый токен остаётся авторитетным, и повторную попытку
> прикрывает grace-окно BFF. На BFF: `820b1fe`, `Jwt:RefreshGraceWindow` = 30 с.
> Проверяется пунктом **T6** в `docs/release-test-checklist.md` (kill процесса во время
> рефреша, 5 раз подряд).

### 🟠 2.2 Гонка двух одновременных 401 закрыта, но остаётся окно устаревших токенов — ✅ Сделано (рабочее дерево)
Хорошая новость: coalescing реализован корректно (`auth_controller.dart:184-187`,
`_refreshFuture ??= ...`), и все четыре `ApiClient` получают один и тот же коллбэк
`ensureFreshAccessToken`, поэтому параллельные 401 схлопываются в одну ротацию.

**Однако** `ApiClient._authedGet` (`api_client.dart:53-74`) захватывает `accessToken`
**аргументом**, а вызывающие берут его один раз: `home_screen.dart:192`;
`choose_location_screen.dart:31` (фиксируется на момент push экрана и живёт всё время его
жизни); `vpn_controller.dart:612` (`_autoSwitchAccessToken` кэшируется в `_armSessionHealth`
и используется часами). Экран локаций через 10 минут сделает запрос со старым токеном →
401 → **новая ротация**. Формально не reuse, но каждая лишняя ротация открывает окно
бага 2.1.
**Фикс:** не передавать токен параметром — сделать `ApiClient` зависимым от провайдера
`Future<String> Function() readAccessToken` и читать актуальный токен перед каждым запросом.

> **Сделано ровно так.** Аргумент-токен убран из всех методов `ApiClient`, вместо него
> поле `readAccessToken`, которое `AuthController` подключает к
> `currentAccessToken()` — а тот рефрешит **только** когда до истечения access-токена
> меньше 2 минут (см. §3.4). То есть открытый час экран локаций больше не выбивает
> лишнюю ротацию.

### 🟠 2.3 Гонка в `VpnController._ensureInitialized` → дублирующая подписка на `stateStream` — ✅ Сделано (рабочее дерево)
**Где:** `vpn_controller.dart:118-166` — между проверкой `if (_initialized) return` (:119)
и `_initialized = true` (:165) стоят два `await`, а `_stateSubscription = _vpn.stateStream.listen(...)`
(:131) перезаписывается.

Путь воспроизведения: `home_screen.dart:81` (`syncFromRuntime()` → `_ensureInitialized()`)
и `home_screen.dart:82` (`_loadServers()` → `consumeAutoConnect()` → `_autoConnect()` →
`_connect()` → `vpn_controller.dart:542` → `_ensureInitialized()` второй раз, пока первый
висит на await).

`stateStream` — broadcast (`singbox_mm_method_channel.dart:25-40`), поэтому второй
`listen` создаёт **вторую подписку**, а `_stateSubscription` теряет ссылку на первую:
1. **Утечка подписки** — `dispose()` (:915) отменяет только последнюю; первая живёт до
   конца процесса и дёргает `notifyListeners()` на уничтоженном контроллере.
2. **Двойная обработка событий** — `_trackSessionStart`, `_captureTunnelFailure`,
   `_maybeSelfHeal` выполняются дважды на каждое событие.
3. `_vpn.initialize()` вызывается дважды.

**Фикс:** `Future<void>? _initFuture; Future<void> _ensureInitialized() => _initFuture ??= _doInitialize();`
плюс `await _stateSubscription?.cancel();` перед новым `listen`.

> **Сделано ровно так** (обе части). Попутно два чтения из secure storage в
> `_doInitialize` объединены в один `Future.wait` (частично §3.7).

### 🟠 2.4 Sign-out не выключает туннель — VPN остаётся поднятым после выхода — ✅ Сделано (рабочее дерево)
**Где:** `settings_screen.dart:427-429` (`await widget.auth.signOut()` без disconnect),
`auth_controller.dart:487-506` (`signOut()` чистит таймеры и хранилище, но VPN не трогает
— у `AuthController` нет ссылки на `VpnController`), `home_screen.dart:387-398`
(`dispose()` вызывает `_vpn.dispose()`, но не `_vpn.stop()`).

После выхода пользователь остаётся подключённым к серверу по отозванной подписке: иконка
VPN в статус-баре, foreground-нотификация «Connected», весь трафик идёт через чужой exit.
Экран онбординга при поднятом туннеле — прямая рассинхронизация UI и реальности. Тот же
путь у автоматического sign-out на 401 (`auth_controller.dart:207-209`).

Заметьте асимметрию: для 402 это **предусмотрено** (`home_screen.dart:206-209`:
`unawaited(_vpn.disconnect())`), а для sign-out — нет.

**Фикс:** прокинуть в `AuthController` коллбэк `onSessionDropped` и вызывать
`vpn.disconnect(endSession: true)` внутри `signOut()`.

> **Сделано ровно так.** Коллбэк вызывается **первой** строкой `signOut()` — чтобы UI
> ни при каких обстоятельствах не добрался до онбординга поверх живого туннеля; его
> исключение ловится и логируется, но выход не блокирует. Подписывает и снимает коллбэк
> `HomeScreen` (он владеет `VpnController`). Автоматический sign-out по 401 идёт тем же
> путём. Проверяется пунктом **T7** в чек-листе.

### 🟠 2.5 Логика пинга на Android построена на устаревшем допущении — ✅ Сделано (рабочее дерево)
Комментарии в Dart утверждают, что приложение исключено из туннеля
(`ping_service.dart:14-17`, `vpn_controller.dart:432-438`: «the tunnel service
deliberately keeps this app's sockets out of the tun device»).

Нативный код это **прямо опроверг**: `VpnTunBuilderConfigurator.kt:128-144` — «This app
is deliberately *not* excluded from the tunnel… Excluding the whole package on top of that
bought nothing and cost a great deal»; `VpnPackageAccessController.kt:8-14` — «It is now
deliberately tunnelled like any other app».

**Последствия:**
1. `PingService._pingDirectly` (`ping_service.dart:71-85`) при поднятом туннеле измеряет
   «устройство → текущий сервер → кандидат» — ровно та патология, которую для iOS
   специально обходят через extension. Все кандидаты получают завышенную latency.
2. **Когда туннель мёртв, `Socket.connect` до всех кандидатов таймаутится** →
   `pingsByNodeId` пуст → в `AutoSwitchPolicy.evaluate` (`auto_switch_policy.dart:114-131`)
   `reachable` пуст → возвращается `null` → **авто-переключение не срабатывает именно в
   сценарии «сервер умер»**, ради которого оно написано.
3. `_pickBestNode` (`vpn_controller.dart:841-852`) при реконнекте поверх умирающего
   туннеля выберет `nodes.first` вслепую.
4. Ранжирование стран на главном экране показывает искажённые цифры.

**Фикс:** убрать платформенное ветвление в `ping_service.dart:32` — использовать
`pingServerOutsideTunnel` (на Android он должен вызывать `VpnService.protect()` на сокете)
на обеих платформах; либо на Android замерять через clash-api `/proxies/{tag}/delay`.
И синхронизировать комментарии с реальностью.

> ❌ **Рецепт аудита выполнять буквально нельзя.** `pingServerOutsideTunnel` на Android
> **не был реализован вовсе** — метод только объявлен в platform interface. «Убрать
> ветвление в `ping_service.dart:32`» уронило бы каждый пинг в `MissingPluginException`,
> то есть отключило бы и ранжирование стран, и авто-переключение целиком. Нативную
> сторону пришлось писать с нуля (см. ниже), и она же породила регрессию **N1**.

> **Сделано по первому варианту.** `pingServerOutsideTunnel` реализован и на Android:
> `PluginMethodOperations.pingServerOutsideTunnel` биндит сокет на эфемерный порт (без
> этого у него нет fd), отдаёт его `VpnServiceLiveness.active?.protect(socket)` и только
> потом коннектится; жёсткий таймаут поверх мягкого сохранён. Ссылка на живой сервис
> добавлена в `VpnServiceLiveness.active`. `PingService` теперь выбирает
> внетуннельный замер на **обеих** платформах. Комментарии в `ping_service.dart`,
> `singbox_mm_platform_interface.dart` и `vpn_controller._probeThroughTunnel` переписаны
> под реальность. Проверка «пинги не деградировали при включённом VPN» — D1–D3 чек-листа.

### 🟠 2.6 `setState()` без проверки `mounted` после `await` — ✅ Сделано (рабочее дерево)
**Где:** `home_screen.dart:193, 211, 227`; `choose_location_screen.dart:65, 71, 76`
(только ветки `catch (_)` проверяют `mounted`).

`getUsableServers` — это **два сетевых вызова** (`/servers` + `/config`,
`api_client.dart:216-224`) с таймаутом 15 с каждый. За эти 30 с пользователь легко уходит
с экрана (кнопка «назад», sign-out/402 на Home). Результат — необработанное исключение,
которое ловится в `PlatformDispatcher.instance.onError` (`main.dart:29`), но UI-состояние
остаётся сломанным. Дополнительно `home_screen.dart:192` — `widget.auth.session!`
(force unwrap): при sign-out во время загрузки это `Null check operator used on a null value`.
**Фикс:** `if (!mounted) return;` после каждого `await`; безопасное чтение сессии с ранним
выходом.

> **Сделано в обоих экранах:** гарды после каждого `await`, `widget.auth.session`
> читается в локальную переменную с ранним выходом (force unwrap `session!` убран из
> `_loadServers` и `_openLocationPicker`); `choose_location_screen.dart` приведён к тому же.

### 🟡 2.7 Разбор `/config`: base64 без нормализации, `Content-Type` игнорируется — ✅ Сделано (рабочее дерево)
**Где:** `app/lib/services/vless_config_parser.dart:31-43`
1. `base64.decode` требует корректного padding и отвергает URL-safe алфавит (`-`, `_`) —
   Remnawave или CDN вполне могут отдать base64url. Нужен `base64.normalize`.
   ❌ **Половина этого пункта неверна:** декодер Dart URL-safe алфавит принимает —
   проверено тестом. Реально ломали только **отсутствующий padding** и **переносы строк**.
   Регрессионный тест на `-`/`_` всё равно оставлен: поведение зафиксировано, чтобы
   следующая правка парсера его не сломала.
2. Переносы строк внутри base64 (wrapped 76 символов — типично) → `FormatException` →
   пустой список.
3. `Content-Type` возвращается, но выбрасывается: `api_client.dart:288` отдаёт
   `(content, contentType)`, а `vpn_controller.dart:550` делает `final (content, _)`.
   Если BFF отдаст `text/plain` со списком ссылок — парсер вернёт `[]`.
4. Провал маскируется: пустой список → `StateError('No available node in this subscription')`
   (`vpn_controller.dart:555-556`), показываемый пользователю как сырой `e.toString()`.
5. При падении парсера `getUsableServers` тихо откатывается на `/servers`
   (`api_client.dart:225`), где у нод нет `configUri` → та же ошибка.

**Фикс:** `base64.decode(base64.normalize(raw.replaceAll(RegExp(r'\s'), '')))` с fallback
на plain-text + лог `'config parse: N raw → M supported'`.

> **Сделано ровно так, включая лог.** `Content-Type` по-прежнему не используется —
> но теперь это безвредно: не-base64 тело просто разбирается как plain text.

### 🟡 2.8 `findUriForNode` матчит только по хосту — ✅ Сделано (рабочее дерево)
**Где:** `vless_config_parser.dart:134-142`. Если на одном хосте есть vless-443 и
hysteria2-8443, всегда вернётся первый в подписке → недетерминированный выбор протокола.
**Фикс:** приоритет схем (vless > trojan > hysteria2) или явный лог неоднозначности.

> **Сделано:** `_schemePriority = [vless, trojan, hysteria2, hy2]`, всё остальное — в
> хвост (по-прежнему пригодно, просто выбор детерминирован).

### 🟡 2.9 `getUsableServers` глотает 401/402 — ✅ Сделано (рабочее дерево)
**Где:** `api_client.dart:216-225` — `catch (_)` ловит **всё**, включая
`ApiException(402)`. Поэтому ветка обработки 402 в `home_screen.dart:203-210`
(«подписка истекла → экран продления») **никогда не сработает для `/config`**.
Пользователь с истёкшей подпиской увидит список серверов, нажмёт Connect и получит сырую
ошибку вместо экрана продления.
**Фикс:** `on ApiException catch (e) { if (e.statusCode == 401 || e.statusCode == 402) rethrow; return servers; }`

> **Сделано ровно так.** Сетевой фолбэк («`/config` недостижим → отдать сырой
> `/servers`») сохранён намеренно — именно он позволяет уйти с умирающей ноды.

### 🟡 2.10 Хардкод английских строк при русском UI по умолчанию — ✅ В основном (рабочее дерево)
Дефолтный язык — русский (`locale_controller.dart:10`), но пользователю показываются
английские литералы: `auth_controller.dart:376, 435, 475`
(`'Could not reach the server…'`, `'Pairing code expired…'`), все `ApiException.message`
(`api_client.dart:88, 122, 186, 278, 293`), и `StateError` из `vpn_controller.dart:556`
рендерится как `Bad state: No available node in this subscription`.
**Фикс:** убрать текст из `ApiException` — оставить `statusCode` + машинный `code`, а
маппинг в строки делать в UI через `Strings`. `AuthController` уже принимает
локализованные сообщения параметрами (`requestTrial`, `resumeTrial`) — распространить
паттерн на `exchangeShortToken`, `startPairing`, `_pollOnce`.

> **Сделано ровно так, как предлагалось:** у `ApiException` больше нет поля `message` —
> только машинный `code` (`token_exchange_failed`, `servers_failed`, …) и `statusCode`;
> текст подбирает UI. `exchangeShortToken` и `startPairing` теперь принимают
> локализованные сообщения **обязательными** параметрами, так что «забыть» их нельзя.
> Закрывает находку №2 прогона («`Token exchange failed`» при RU-локали).
> **Проверить точечно:** сырой `StateError('No available node in this subscription')`
> из `vpn_controller` — не проверялось.

### 🟡 2.11 Логи буферизуются и теряются при краше — вопреки заявленному контракту — ✅ Сделано (рабочее дерево)
**Где:** `app_logger.dart:26-28` обещает «a crash or force-quit doesn't lose the trail»,
но `_record` (`:91-97`) пишет в `IOSink` без flush, а `flush()` вызывается **только** в
`clear()` (:111). При краше весь несброшенный буфер теряется — то есть именно те строки,
ради которых логгер написан.
**Фикс:** периодический flush (таймер 2 с), обязательный flush на `LogLevel.error` и на
`AppLifecycleState.paused`.

> **Сделано:** публичный `AppLogger.flush()`, таймер на 2 с и безусловный flush на
> `LogLevel.error` («последнее, что процесс успевает сказать»). Вызов из
> `AppLifecycleState.paused` — проверить отдельно в `main.dart`.

### 🟡 2.12 Запрос точных будильников выбрасывает пользователя в системные настройки на первом старте — ✅ Сделано (рабочее дерево)
**Где:** `main.dart:72` → `notification_service.dart:58-69`
(`requestExactAlarmsPermission()` на :64). Этот вызов запускает
`ACTION_REQUEST_SCHEDULE_EXACT_ALARM` — **полноэкранный системный экран настроек** на
первом же запуске, до онбординга, без объяснения. Плюс диалог POST_NOTIFICATIONS сразу
за ним. Классический убийца конверсии, а `SCHEDULE_EXACT_ALARM` ещё и повод для отказа в
Google Play для не-будильника.
**Фикс:** запрашивать лениво — POST_NOTIFICATIONS после успешной активации подписки;
от exact alarms отказаться вовсе (напоминания за 30/15 минут переживут
`inexactAllowWhileIdle`) и убрать `SCHEDULE_EXACT_ALARM` из манифеста
(`AndroidManifest.xml:11`).

> **Сделаны все три пункта.** `NotificationService.init()` больше не просит разрешений
> вообще; `requestPermission()` вызывается из `_syncNotifications` только при активной
> подписке и только один раз. `requestExactAlarmsPermission` убран,
> `SCHEDULE_EXACT_ALARM` удалён из манифеста, минутные напоминания стали inexact.
> Закрывает находку **№3** прогона 2026-07-27 (системный экран «Alarms & reminders» на
> каждом запуске).

### 🟡 2.13 `_pollOnce` глотает любые исключения → бесконечный опрос — ✅ Сделано (рабочее дерево)
**Где:** `auth_controller.dart:442-485` — `catch (_)` без счётчика. Если BFF вернёт
`{"status":"completed"}` без токенов (баг деплоя/версий), `PairingStatus.fromJson`
(`pairing.dart:32-42`) бросит `TypeError` → погашен → **таймер бьёт каждые 2 секунды
бесконечно**, пользователь смотрит на спиннер. Плюс `PairingStart.expiresAt`
(`pairing.dart:16,22`) читается, но нигде не используется.
**Фикс:** счётчик неудач подряд (после N — показать ошибку и остановить), стоп по
`expiresAt`, логировать причину в `catch`.

> **Сделаны все три:** `_maxPollFailures = 5`, жёсткий стоп по `PairingStart.expiresAt`
> (поле наконец используется), `_failPairing(expired:)` разводит «код истёк» и
> «не отвечает» на разные сообщения.

### 🟡 2.14 Кэш `_lastGoodConfig` не разделяется между экземплярами `ApiClient` — ✅ Сделано (рабочее дерево)
**Где:** `api_client.dart:286` — поле экземпляра, а экземпляров четыре (см. 2.2).
Fallback «переиспользовать последнюю подписку» (`:310-314`) работает только внутри того
экземпляра, который уже успешно сходил за конфигом; `VpnController._connect` использует
**свой** клиент. При смене ключа старый `_lastGoodConfig` не инвалидируется — при обрыве
сети возможен коннект по подписке предыдущего ключа.
**Фикс:** один общий `ApiClient` на приложение либо вынести кэш в `ConfigCache` со сбросом
по `sessionMintedAt`.

> **Сделано и то, и другое:** клиент один (`AuthController.api`), а кеш — `_Cached<T>`,
> который помнит `sessionMintedAt` и обнуляется при смене ключа. Фолбэк «переиспользовать
> последнюю подписку при сетевом сбое» сохранён и теперь общий для всего приложения.

### 🟡 2.15 `_waitForDisconnected` — busy-wait с фиксированным дедлайном, продублирован — ✅ Сделано (рабочее дерево)
**Где:** `vpn_controller.dart:832-839` и `home_screen.dart:318-328` — идентичный цикл с
окном 4 с. Дедлайн истекает молча: `_performAutoSwitch` (:802) идёт делать `_connect`
даже если туннель ещё не опустился — ровно та проблема, которую метод должен
предотвращать. При этом нативная остановка может занять больше: `VpnCoreServiceCoordinator.kt:29`
задаёт `RESTART_CLOSE_SUPPRESSION_MS = 15_000L` — **дедлайн клиента в 4 раза меньше окна
подавления в сервисе**.
**Фикс:** ждать событие из `stateStream` (`firstWhere(...).timeout(...)`) вместо polling,
вынести в один метод, увеличить окно до ~10 с, логировать истечение дедлайна.

> **Сделано ровно так, все четыре пункта:** `VpnController.waitForDisconnected()` стал
> публичным и единственным, `home_screen._switchOff` вызывает его вместо своей копии,
> окно 10 с, истечение пишется в лог (`Tunnel did not report disconnected within 10s`).

### 🟢 2.16 Часовые пояса в напоминаниях — корректно, с оговорками
Проверено, багов нет: `tz.TZDateTime.from(when, tz.local)` сохраняет абсолютный момент,
`UILocalNotificationDateInterpretation.absoluteTime` это подтверждает; сервер отдаёт
`DateTimeOffset` со смещением, `DateTime.parse` его разбирает. Оговорки:
`_lastSignature` хранится только в памяти → каждый холодный старт делает `_cancelAll()` +
5 × `zonedSchedule` (10 лишних IPC); при `expiresAt` между рестартами напоминания просто
не запланируются; `_expiryLabel` при 0 часов покажет «истекает через 0 часов»
(`settings_screen.dart:190-193`).

### 🟢 2.17 Мелочи — ✅ Сделано (рабочее дерево)
- `api_client.dart:169` — `pollToken` не URL-кодируется (`?pollToken=$pollToken`);
  сломается на `&`, `=`, `+`, `/`. Использовать `Uri(...).replace(queryParameters: ...)`.
  **✅ Сделано** (рабочее дерево), ровно предложенным способом.
- `MainActivity.kt:15-30` — `MethodChannel` не снимается (`cleanUpFlutterEngine` →
  `setMethodCallHandler(null)`), `Thread` не отменяется, каждый вызов создаёт новый поток
  без пула. **✅ Сделано** (рабочее дерево): обработчик снимается в `cleanUpFlutterEngine`
  (иначе он держит Activity вместе с её окном), поток на вызов заменён одним
  daemon-executor'ом, который гасится там же.

---

## 3. ПРОИЗВОДИТЕЛЬНОСТЬ / БАТАРЕЯ / РАЗМЕР

### 🔴 3.1 Размер APK: ~236 МБ нативных библиотек, без ABI-фильтров и сплитов — ✅ Сделано и измерено (рабочее дерево)
Измерено:

| ABI | Размер `libbox.so` |
|---|---|
| arm64-v8a | 62 715 672 B |
| armeabi-v7a | 55 770 432 B |
| x86 | 60 809 236 B |
| x86_64 | 66 096 856 B |
| **Итого** | **≈ 236 МБ** |

`app/android/app/build.gradle.kts` — нет ни `ndk { abiFilters }`, ни `splits { abi }`,
ни `bundle {}`. Универсальный APK включает все четыре ABI.

**Почему плохо:** **лимит Google Play — 100 МБ на APK / 200 МБ на base-модуль AAB.
Текущая сборка физически не загружается.** `x86`/`x86_64` (≈127 МБ, 54% веса) нужны
только эмуляторам.

Дополнительный источник веса — build-теги в
`app/packages/singbox_mm/tool/fetch_singbox_libbox_android.sh:54`: `with_tailscale`,
`with_naive_outbound`, `with_grpc`, `with_wireguard` в приложении не используются
(парсер поддерживает vless/trojan/hysteria2/ss, реально подписка отдаёт vless + hysteria2),
а `with_tailscale` тянет десятки мегабайт.

**Фикс:**
1. Собирать **AAB** с ABI-сплитами (`flutter build appbundle`) — Play отдаст пользователю
   только его ABI (~25-30 МБ сжатых).
2. `defaultConfig { ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") } }`.
3. Пересобрать libbox без `with_tailscale`, `with_naive_outbound`, `with_grpc`,
   `with_wireguard` — ожидаемая экономия 30-50%.
4. Проверить, что `-s -w` применились, добавить `strip` для армовских `.so`.

> ❌ **Пункт 2 в предложенном виде не работает.** `ndk { abiFilters }` AGP объединяет
> (**union**) между `defaultConfig` и build type, а не пересекает, — и `defaultConfig`
> заполняет сам Flutter Gradle plugin. Фильтр в `release` поэтому не сужает набор, а
> расширяет: первый собранный AAB **всё ещё содержал x86_64** (проверено распаковкой).
> Пришлось идти через Variant API:
> `androidComponents.onVariants(selector().withBuildType("release")) { variant.packaging.jniLibs.excludes.addAll("**/x86/**", "**/x86_64/**") }`
> — он per-variant и финальный. Debug остался универсальным, чтобы x86_64-эмулятор
> продолжал работать.
>
> **Пункт 1 сделан:** `bundle { abi { enableSplit = true }; density { enableSplit = true };
> language { enableSplit = false } }` — язык намеренно не сплитится, Flutter носит свои
> локализации, и языковой сплит Play вырезал бы ресурсы, против которых он резолвится.
>
> **Измерено (`flutter build appbundle --release`, 2026-07-28):** AAB **138.6 МБ** на
> диске, из них **70.3 МБ** — debug-символы, которые Play не раздаёт; фактическое
> скачивание **35.0 МБ** на arm64 и **34.6 МБ** на arm32; сплиты x86/x86_64 — **0 байт**.
> Лимит base-модуля 200 МБ закрыт с запасом.
>
> **Не сделаны пункты 3 и 4:** пересборка libbox без `with_tailscale`/`with_naive_outbound`/
> `with_grpc`/`with_wireguard` требует Go-тулчейна и отложена — это ещё 30–50 % запаса,
> который сейчас не нужен.

### 🟠 3.2 Выбор лучшей ноды — строго последовательный пинг — ✅ Сделано со второго захода (рабочее дерево)
**Где:** `vpn_controller.dart:841-852` — `await` в цикле, таймаут одного пинга 3 с
(`ping_service.dart:60,77`). Это путь **каждого нажатия «Подключить»** (:561), а в режиме
«Best server» кандидатами становятся все ноды всех стран (:339). При 20 нодах, из которых
5 недоступны, только на пинги уходит **15 секунд** сверх остального.

Контраст: в `_evaluateAutoSwitch` (:688-690) и в `home_screen.dart:231-233` те же пинги
делаются **параллельно** через `Future.wait` — паттерн в проекте известен, но в самом
горячем месте не применён.
**Фикс:** `Future.wait(nodes.map(...))` + early-exit при находке ноды < 80 мс.

> **Сделано, но не голым `Future.wait`:** новый `app/lib/utils/parallel.dart`
> (`mapConcurrently`) держит не больше **6** хендшейков в полёте — иначе замеры
> конкурируют друг с другом за радио и портят сами себя (см. §3.9). Тот же помощник
> применён в `_evaluateAutoSwitch`. Early-exit при < 80 мс не делался.
>
> ⚠️ **Первая версия этой правки была регрессией** — параллельность на Dart-стороне
> упиралась в однопоточный executor плагина, и шесть пингов шли медленнее, чем шесть
> последовательных. Разбор и фикс — находка **N1** в шапке документа. Проверять этот
> пункт **обязательно на устройстве**: хост-тесты нативный executor не видят.

### 🟡 3.3 Экран локаций пингует ноды последовательно — ✅ Сделано (рабочее дерево)
**Где:** `choose_location_screen.dart:97-104` — `await` в цикле + `setState` на каждую
ноду (полная перерисовка `ListView`). Раскрытие страны с 6 нодами, половина недоступна ≈
9 с постепенно появляющихся цифр.
**Фикс:** `Future.wait` + один `setState` на пачку.

> **Сделано** через тот же `mapConcurrently` (бюджет 6) + один `setState` на пачку.

### 🟡 3.4 Лишние запросы к BFF — 🟡 В основном (рабочее дерево)
Типичный сеанс «открыл — выбрал страну — подключился»:

| Действие | Файл:строка | Запросы |
|---|---|---|
| Холодный старт | `auth_controller.dart:149` | `POST /auth/refresh` (безусловно!) |
| `HomeScreen._loadServers` | `home_screen.dart:192` | `GET /servers` + `GET /config` |
| Открытие экрана локаций | `choose_location_screen.dart:70` | `GET /servers` + `GET /config` |
| Кнопка «обновить» там же | `choose_location_screen.dart:245` | `GET /servers` + `GET /config` |
| Connect | `vpn_controller.dart:550` | `GET /config` (ещё раз) |
| Каждые 3 минуты сессии | `vpn_controller.dart:770` | `GET /servers` |
| Каждый resume приложения | `main.dart:88` → `auth_controller.dart:180` | `POST /auth/refresh` |

Главное: **`POST /auth/refresh` на каждый холодный старт и каждый resume**. Приложение не
знает срок жизни JWT — `AuthSession.expiresAt` (`auth_session.dart:24-26`) это **срок
подписки, а не токена**. Поэтому оно ротирует refresh-токен по десятку раз в день на
ровном месте, каждый раз открывая окно бага 2.1. Единственная защита — 90-секундное окно
`_skipResumeRefreshWindow`.
**Фикс:** один общий `ApiClient` + кэш `/config` и `/servers` с TTL 5 мин и инвалидацией
по `sessionMintedAt`; парсить `exp` из JWT и рефрешить только когда до истечения < 2 мин
либо по 401. (Парная правка на BFF — отдавать `accessTokenExpiresAt`, см.
`docs/improvement-plan-bff.md`, раздел «Мелкие баги».)

> **Сделано целиком, обе стороны.** BFF (`820b1fe`) отдаёт `accessTokenExpiresAt` в
> `/auth/token` и `/auth/refresh`. Приложение читает его в `AuthSession`, а когда сервер
> его **не** прислал — `/pair/status` и `/trial` этого поля не возвращают — достаёт `exp`
> из самого JWT (`AuthSession._jwtExpiry`, разбор payload без валидации подписи: она дело
> сервера). `AuthController.currentAccessToken()` рефрешит только при остатке < 2 мин,
> так что рефреш «просто потому что экран открылся» ушёл. Срок JWT ещё и хранится
> отдельным ключом (`access_jwt_expires_at`), чтобы холодный старт не ротировал вслепую.
> Кеш `/servers`/`/config` — TTL 5 мин с привязкой к `sessionMintedAt`.
>
> ⚠️ **Рефреш на холодном старте и на resume оставлен сознательно**, вопреки букве этой
> находки: именно он подтягивает срок **подписки**, и без него пользователь, продливший
> ключ в Telegram, остался бы заперт на экране продления. Это открытый продуктовый
> вопрос, а не недоделка — см. «Открытые вопросы» в шапке документа.
>
> ⚠️ **Побочный эффект кеша:** он тихо сломал `_liveUserCounts` (кеш длиннее раунда
> авто-переключения). Разбор — находка **N2**.

### 🟡 3.5 Уведомление VPN перерисовывается раз в секунду всю сессию — ✅ Сделано (рабочее дерево)
**Где:** `SignboxLibboxServiceContract.kt:16` (`NOTIFICATION_STATS_INTERVAL_MS = 1000L`),
`VpnServiceNotificationGraph.kt:38-40`, `VpnLiveNotificationTicker.kt:14-27`.
При сессии 8 часов это **28 800 пересборок уведомления на главном потоке сервиса**,
каждая — Parcel + IPC в `NotificationManagerService` + перерисовка шторки. Плюс
`NotificationTrafficMonitor.captureSnapshot` читает `/proc` через `TrafficStats`.
Сам монитор уже сглаживает скорость на окне 250 мс — секундный тик не даёт точности,
только нагрузку.
**Фикс:** интервал 2-3 с; пропускать `notify()`, если форматированный текст не изменился;
останавливать тикер при выключенном экране (`ACTION_SCREEN_OFF`).

> **Сделаны первые два пункта:** `NOTIFICATION_STATS_INTERVAL_MS` 1000 → **3000** мс
> (8-часовая сессия — 9 600 пересборок вместо 28 800) и новый `notifyIfChanged()`,
> который сравнивает title/text/subText уже собранного уведомления с последним
> показанным и не делает IPC, если ничего не поменялось (дорог именно post и перерисовка
> шторки, а не сборка). **`ACTION_SCREEN_OFF` не делали.**

### 🟡 3.6 Секундный `Timer` на главном экране перерисовывает всё дерево — ✅ Сделано (рабочее дерево)
**Где:** `home_screen.dart:151-153` + `:170-174` — `setState` перестраивает **весь**
`build` (:407-433): хедер с `Image.asset`, карточку локации, кнопку питания с `BoxShadow`,
`_buildBestServers` с пересортировкой `_rankedServers` (`:244-255` — **`sort()` на каждом
кадре**) — и всё ради одной строки `_sessionLabel`. Дополнительно `main.dart:133-144`:
`ListenableBuilder(listenable: _auth)` оборачивает всё дерево, поэтому каждый
`notifyListeners()` в `AuthController` тоже перестраивает корень.
**Фикс:** таймер сессии в `ValueNotifier<Duration>` + `ValueListenableBuilder` только
вокруг `Text`; кэшировать `_rankedServers`; `const` для статики хедера.

> **Сделаны первые две части:** `_sessionTime` — `ValueNotifier<Duration>` (освобождается
> в `dispose`), вокруг него `ValueListenableBuilder` на один `Text`; `_rankedServers`
> стал полем и пересчитывается только при загрузке списка и после замеров, а не на
> каждом кадре. `const` для статики хедера и `ListenableBuilder` вокруг всего дерева в
> `main.dart` — не трогали.

### 🟡 3.7 Старт делает ~15 последовательных чтений из secure storage — ✅ Сделано (рабочее дерево)
**Где:** `connection_settings_controller.dart:152-163` — 11 последовательных
`await _storage.read(...)`; плюс `token_storage.dart:76-87` (3), device-key/session-kind/
key-code (3), `locale_controller.dart` (1), `vpn_controller._ensureInitialized` (1).
Каждое чтение — платформенный канал + расшифровка ключом Keystore; на бюджетных
устройствах 5-15 мс → **150-250 мс** последовательного ожидания ровно там, где идёт
борьба за время до первого кадра (`_minSplashTime = 1400 ms`).
**Фикс:** `Future.wait([...])` вместо цепочки `await`; несекретные данные (язык,
DNS-пресет, bypass-хосты, `vpn_session_started_at`) перенести в `SharedPreferences`.

> **Сделано во всех трёх местах:** `connection_settings_controller.load()` читает свои
> **11** значений одной пачкой `Future.wait`, `TokenStorage.read()`/`save()` — свои
> четыре, `VpnController._doInitialize` — свои два. Перенос несекретных значений в
> `SharedPreferences` не делали: цепочки последовательного ожидания больше нет и без него.

### 🟡 3.8 Опрос `/pair/status` каждые 2 с без бэк-оффа и без остановки в фоне — ✅ Сделано (рабочее дерево)
**Где:** `auth_controller.dart:430`. Пользователь уходит в Telegram оплачивать подписку —
изолят продолжает жить, таймер бьёт: **30 HTTP-запросов в минуту** с мобильного радио.
`AwaitingAuthScreen` (`awaiting_auth_screen.dart:26-47`) не имеет `dispose()`, который
останавливал бы пэйринг.
**Фикс:** бэк-офф 2 → 3 → 5 с; пауза в `AppLifecycleState.paused` с немедленным
`_pollOnce()` на resume; жёсткий стоп по `expiresAt`; `dispose()` экрана останавливает таймер.

> **Сделаны все четыре пункта:** расписание `_pollIntervals = [2, 3, 5] с`,
> `AuthController.setPairingPaused(bool)` (на возврате — немедленный `_pollOnce()` и
> перезапуск таймера), стоп по `expiresAt`, `AwaitingAuthScreen.dispose()` ставит опрос
> на паузу. Лимит `/pair/status` на BFF — 60/мин на IP, запас двукратный.

### 🟡 3.9 Всплеск параллельных TCP-соединений при загрузке главного экрана — ✅ Сделано (рабочее дерево)
**Где:** `home_screen.dart:231-239` — декартово произведение: все ноды всех стран
пингуются одновременно (10 стран × 4 ноды = 40 одновременных `Socket.connect`). На
мобильной сети это всплеск, портящий сами измерения (конкуренция за радио) и похожий на
скан для некоторых NAT/файрволов.
**Фикс:** пул на 6-8 одновременных соединений.

> **Сделано:** вложенные `Future.wait` заменены на плоский список пар «страна × нода»,
> прогоняемый через `mapConcurrently` с бюджетом **6**; вместо `setState` на каждую
> страну — один `setState` на всю пачку.

### 🟡 3.10 `http.Client` никогда не закрывается — по одному на каждый экран — ✅ Сделано (рабочее дерево)
**Где:** `api_client.dart:29`; метода `close()` у `ApiClient` нет. Экземпляры:
`home_screen.dart:35`, `vpn_controller.dart:27`, `settings_screen.dart:35` (**новый на
каждое открытие настроек**), `choose_location_screen.dart:46` (**новый на каждое
открытие**). Каждый держит собственный пул keep-alive соединений — утечка дескрипторов и
сокетов.
**Фикс:** `ApiClient.close()` → `_httpClient.close()` в `dispose()` экранов; либо один
общий `ApiClient` (заодно решает 2.14 и 3.4).

> **Сделано по второму варианту** (он же закрывает 2.14 и 3.4): `ApiClient` стал один на
> приложение — `AuthController.api`, — поэтому экраны больше не заводят собственные пулы
> keep-alive соединений. `ApiClient.close()` добавлен и вызывается при разрушении
> владельца.

### 🟡 3.11 Список приложений для split-tunneling передаётся одним огромным сообщением — 🟡 Частично (рабочее дерево)
**Где:** `MainActivity.kt:34-51` — для каждого launcher-приложения иконка рендерится в
bitmap 96×96 ARGB_8888 и сжимается в PNG с качеством 100 (`drawableToPng`, :53-68);
`installed_apps_service.dart:19` получает всё **одним** `invokeListMethod`.
На типичном телефоне 120-200 приложений × 8-15 КБ = **1.5-3 МБ в одном платформенном
сообщении**, сериализация блокирует UI-поток на сотни миллисекунд. Плюс `Image.memory` в
`_AppTile` (`split_tunneling_screen.dart:248`) декодирует без `cacheWidth/cacheHeight` —
96×96×4 = 36 КБ на иконку × 200 = 7 МБ в памяти.
**Фикс:** отдавать список без иконок, иконки — вторым каналом лениво по `packageName`,
в WEBP качества 80 и размере 48 px; в `Image.memory` указать `cacheWidth: 72,
cacheHeight: 72, filterQuality: FilterQuality.low`.

> **Сделана дешёвая половина:** иконки кодируются в **WEBP q80** вместо PNG q100
> (примерно пятая часть прежнего объёма, на 36dp разницы не видно), а `Image.memory`
> получил `cacheWidth/cacheHeight: 72` и `filterQuality: low` — декодирование сразу в
> размер отрисовки вместо 7 МБ битмапов на список из 200 приложений.
> **Ленивая догрузка иконок вторым каналом по `packageName` отложена сознательно:** это
> переписывание экрана (стейт, плейсхолдеры, отмена запросов при скролле), а не точечная
> правка, и без устройства её не проверить.

### 🟢 3.12 Watchdog туннеля — оценка энергопотребления: в целом хорошо — ✅ Сделано (рабочее дерево)
`VpnTunnelHealthPolicy.kt:37` (`CHECK_INTERVAL_MS = 60_000L`) + бэк-офф до 300 с после 4
неудачных восстановлений — разумно. `VpnTunnelHealthWatchdog.kt:62-68` использует
`Handler.postDelayed`, а не `AlarmManager` → **устройство не будится**. Пробы на отдельном
daemon-executor, не на main. `WakeLock` в проекте не используется вообще.
`hasUpstreamNetwork` предотвращает пробы без сети. Всё это сделано правильно.

Единственное замечание: каждая проба делает до **4 HTTP-запросов**
(`VpnTunnelHealthProbe.kt:70-82`), причём `delay` реально дёргает `gstatic.com` и
`cp.cloudflare.com` **через туннель** — за 8 часов 480 запросов через прокси.
**Фикс:** адаптивный интервал — 60 с после старта, 180 с после N здоровых проверок.

> **Сделано ровно так:** `SETTLED_INTERVAL_MS = 180_000`,
> `HEALTHY_CHECKS_BEFORE_SETTLING = 5`. Любой `DEAD`-вердикт обнуляет счётчик и
> возвращает тесный интервал, `onTunnelStarted` — тоже. Backoff 300 с после серии
> безуспешных восстановлений сохранён и по-прежнему имеет приоритет.

### 🟢 3.13 Дублирующий health-контур в Dart поверх нативного — ⬜ Отложено сознательно
**Где:** `vpn_controller.dart:83` (`_sessionHealthInterval = 3 мин`) → `_sessionHealthTick`
(:643-651) делает свою пробу `_verifyTunnelCarriesTraffic` (:458-482) параллельно с
нативным watchdog'ом, который делает то же самое каждую минуту. Плюс `syncFromRuntime` на
каждом resume запускает ещё одну пробу (:191).
**Фикс:** сделать Dart-сторону потребителем вердикта нативного watchdog'а (пробросить
через `stateDetailsStream`), а не независимым источником проб.

> **Отложено, причина:** это **новая нативная поверхность на обеих платформах** (новый
> вид события через platform channel, свой формат на Android и в Network Extension), и
> проверить её без реального устройства нельзя — а весь остальной объём работ закрывался
> статически. Пока §3.12 снял основную часть расхода на Android-стороне.
> `_sessionHealthInterval` остался 3 мин.

---

## 4. Что сделано хорошо (не переделывать)

- **Защита broadcast'ов состояния**: signature-permission + `RECEIVER_NOT_EXPORTED` +
  `setPackage` (`packages/.../AndroidManifest.xml:3-5`,
  `PluginCallbackRegistrationCoordinator.kt:46-59`, `VpnStateUpdateBroadcaster.kt:16-23`).
- **`VpnServiceLiveness`** — корректное решение проблемы «на диске написано connected, а
  процесс убит»; `reconcileWithRunningService` (`SignboxLibboxServiceContract.kt:53-66`)
  сбрасывает залипшее состояние.
- **Атомарная запись конфига** с `fsync` + `Os.rename` + 0600
  (`PluginRuntimeConfigStore.kt:98-126`).
- **`AutoSwitchPolicy`** — продуманная политика со strikes, cooldown, разделением
  latency/crowding и корректной семантикой «неизвестно ≠ ноль». Покрыта тестами.
- **Fallback авто-переключения**: при неудаче возврат на прежнюю ноду
  (`vpn_controller.dart:811-826`).
- **Различение `UNKNOWN` и `DEAD`** в health-probe (`VpnTunnelHealthProbe.kt:16-20`).
- **Версионированные батчи seed-хостов** (`connection_settings_controller.dart:60-68`) —
  удалённые пользователем записи не воскресают при обновлении.
- **Раздельные списки для include/exclude режимов** — предотвращён класс багов
  «инверсия правил одним тапом».
- Маскирование токенов в support-bundle (`settings_screen.dart:177-181`).

---

## 5. Приоритизированный план

### Блокеры релиза (до любой публикации)
1. **HTTPS + удаление `usesCleartextTraffic`** — `api_config.dart:4`,
   `AndroidManifest.xml:16` (§1.1) — 🟡 cleartext закрыт, **HTTPS остаётся блокером**
2. **Release keystore** — `build.gradle.kts:34` (§1.3) — ✅ `cfe1f2b`
3. **AAB без x86** — `build.gradle.kts` (§3.1) — ✅ через Variant API (не `abiFilters`, он не работает), скачивание **35.0 МБ** arm64 / **34.6 МБ** arm32
4. **`await` при сохранении ротированного refresh-токена** — `auth_controller.dart:204` (§2.1) — ✅
5. **`allowBackup="false"`** — `AndroidManifest.xml:12` (§1.4) — ✅ `901ea73`

### Спринт 1 (безопасность + корректность)
6. Секрет для clash-api — `singbox_config_builder.dart:131` (§1.6) 🔗 — ✅
7. Disconnect при sign-out — `auth_controller.dart:487`, `settings_screen.dart:427` (§2.4) — ✅
8. Идемпотентный `_ensureInitialized` — `vpn_controller.dart:118` (§2.3) — ✅
9. `stderr.log` в `filesDir` — `VpnCoreSetupManager.kt:25` (§1.7) — ✅ (без ротации)
10. `mounted`-гарды после `await` (§2.6) — ✅
11. Certificate pinning (§1.2) — ⬜ отложено до HTTPS
12. Починить измерение пинга на Android — `ping_service.dart:32` (§2.5) — ✅

### Спринт 2 (производительность + UX)
13. Параллельный `_pickBestNode` — `vpn_controller.dart:841` (§3.2) — ✅
14. Единый `ApiClient` + кэш `/config`/`/servers` + refresh только по `exp` (§3.4, §2.14, §3.10) — ✅
15. Локализация всех пользовательских сообщений (§2.10) — ✅ в основном
16. Убрать `requestExactAlarmsPermission` со старта (§2.12) — ✅
17. Тик уведомления 1 с → 3 с (§3.5) — ✅
18. Точечная перерисовка таймера сессии (§3.6) — ✅
19. Устойчивый парсер `/config` (§2.7) — ✅
20. Бэк-офф и пауза в фоне для `/pair/status` (§3.8) — ✅

**Критерий приёмки:** `flutter analyze` без ошибок, `flutter test` зелёный; release-сборка
собирается как AAB и укладывается в лимиты Play; на устройстве — подключение, смена
сервера, sign-out при активном туннеле, холодный старт после kill процесса во время
рефреша (проверка §2.1).

> **Статическая половина закрыта (2026-07-28):** `flutter analyze` чисто в обоих пакетах,
> **275 тестов** зелёные (107 + 1 skip в `app/`, 168 в плагине), три прогона подряд без
> флаков; AAB собирается, подписан настоящим ключом и укладывается в лимиты Play с
> запасом.
> **Устройство — целиком впереди.** Всё, что переписано, — это поведение platform
> channel'ов, которое хост-тесты не достают: подключение как таковое (сменились и
> механизм пинга, и конфиг — в `clash_api` теперь `secret`), смена сервера и
> авто-переключение (busy-wait заменён событием), sign-out при живом туннеле, холодный
> старт после kill во время рефреша, диалог подтверждения `fatvpn://`, санитайзер
> support-bundle, обновление **поверх старой установки** (миграция secure storage) и то,
> что release-APK больше не ставится на x86_64-эмулятор. Список — раздел **2a** в
> `docs/release-test-checklist.md`.
