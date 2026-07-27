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

---

## 1. БЕЗОПАСНОСТЬ

### 🔴 1.1 BFF работает по HTTP — токены и конфиги идут в открытом виде
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

### 🟠 1.2 Полностью отсутствует certificate pinning
**Где:** `app/lib/services/api_client.dart:29` — обычный `http.Client()`.
Даже после перехода на HTTPS клиент доверяет системному trust store: корпоративный/MDM
профиль или root-устройство ставят CA в system store; скомпрометированный публичный CA
выдаёт валидный сертификат. Для VPN-клиента, где перехват `/config` = кража платной
подписки, это неприемлемо.
**Фикс:** `HttpClient` с `badCertificateCallback` + сверка SPKI-пина (SHA-256 публичного
ключа) либо `certificate_pinning_interceptor`. Пинить два ключа (текущий + backup) и
предусмотреть механизм обновления.

### 🔴 1.3 Release-сборка подписана debug-ключом
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

### 🟠 1.4 `allowBackup` по умолчанию `true` — конфиг с креденшелами уезжает в облако
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

### 🟡 1.5 `flutter_secure_storage` без `AndroidOptions(encryptedSharedPreferences: true)`
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

### 🟠 1.6 🔗 Локальный clash-API открыт без секрета — любое приложение управляет VPN
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

### 🟡 1.7 `stderr.log` sing-box пишется на внешнее хранилище
**Где:** `VpnCoreSetupManager.kt:25,36` — `context.getExternalFilesDir(null)`, то есть
`/sdcard/Android/data/<pkg>/`: на API ≤ 28 читается любым приложением с
`READ_EXTERNAL_STORAGE`, на любом API доступен через MTP/adb без root и **всегда попадает
в бэкап**. Содержимое: адреса/порты нод, SNI, DNS-запросы, ошибки хендшейка — карта
инфраструктуры и активность пользователя. Там же лежит рабочая директория libbox
(кэши geo-правил, `cache.db`).
**Фикс:** `context.filesDir` (или `noBackupFilesDir`), ротация `stderr.log` по размеру,
запись только при включённом диагностическом режиме.

### 🟡 1.8 `attestationToken` — обычный локальный random, тривиально фармится
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

### 🟡 1.9 Диагностика тянет в support-bundle инфраструктурные данные
**Где:** `vpn_controller.dart:857-886` (`log.e('Tunnel failed at runtime', err)`),
bundle собирается в `app_logger.dart:142-186` и шарится через OS-share sheet
(`:194-213`), то есть может уйти в любой мессенджер. `getLastError` — это хвост stderr
sing-box; там регулярно встречаются `outbound/vless[tag] ... dial tcp <IP>:<port>`, SNI,
Reality public key. Токены замаскированы корректно (`settings_screen.dart:177-181`), а
конфиг — нет.
**Фикс:** прогонять `err` через санитайзер (регэкспы на `uuid`, `password=`, `@host:port`,
`pbk=`, `sid=`) перед `log.e` и перед показом в UI.

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

---

## 2. БАГИ

### 🔴 2.1 Ротированный refresh-токен сохраняется fire-and-forget → reuse detection убивает сессию
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

### 🟠 2.2 Гонка двух одновременных 401 закрыта, но остаётся окно устаревших токенов
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

### 🟠 2.3 Гонка в `VpnController._ensureInitialized` → дублирующая подписка на `stateStream`
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

### 🟠 2.4 Sign-out не выключает туннель — VPN остаётся поднятым после выхода
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

### 🟠 2.5 Логика пинга на Android построена на устаревшем допущении
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

### 🟠 2.6 `setState()` без проверки `mounted` после `await`
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

### 🟡 2.7 Разбор `/config`: base64 без нормализации, `Content-Type` игнорируется
**Где:** `app/lib/services/vless_config_parser.dart:31-43`
1. `base64.decode` требует корректного padding и отвергает URL-safe алфавит (`-`, `_`) —
   Remnawave или CDN вполне могут отдать base64url. Нужен `base64.normalize`.
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

### 🟡 2.8 `findUriForNode` матчит только по хосту
**Где:** `vless_config_parser.dart:134-142`. Если на одном хосте есть vless-443 и
hysteria2-8443, всегда вернётся первый в подписке → недетерминированный выбор протокола.
**Фикс:** приоритет схем (vless > trojan > hysteria2) или явный лог неоднозначности.

### 🟡 2.9 `getUsableServers` глотает 401/402
**Где:** `api_client.dart:216-225` — `catch (_)` ловит **всё**, включая
`ApiException(402)`. Поэтому ветка обработки 402 в `home_screen.dart:203-210`
(«подписка истекла → экран продления») **никогда не сработает для `/config`**.
Пользователь с истёкшей подпиской увидит список серверов, нажмёт Connect и получит сырую
ошибку вместо экрана продления.
**Фикс:** `on ApiException catch (e) { if (e.statusCode == 401 || e.statusCode == 402) rethrow; return servers; }`

### 🟡 2.10 Хардкод английских строк при русском UI по умолчанию
Дефолтный язык — русский (`locale_controller.dart:10`), но пользователю показываются
английские литералы: `auth_controller.dart:376, 435, 475`
(`'Could not reach the server…'`, `'Pairing code expired…'`), все `ApiException.message`
(`api_client.dart:88, 122, 186, 278, 293`), и `StateError` из `vpn_controller.dart:556`
рендерится как `Bad state: No available node in this subscription`.
**Фикс:** убрать текст из `ApiException` — оставить `statusCode` + машинный `code`, а
маппинг в строки делать в UI через `Strings`. `AuthController` уже принимает
локализованные сообщения параметрами (`requestTrial`, `resumeTrial`) — распространить
паттерн на `exchangeShortToken`, `startPairing`, `_pollOnce`.

### 🟡 2.11 Логи буферизуются и теряются при краше — вопреки заявленному контракту
**Где:** `app_logger.dart:26-28` обещает «a crash or force-quit doesn't lose the trail»,
но `_record` (`:91-97`) пишет в `IOSink` без flush, а `flush()` вызывается **только** в
`clear()` (:111). При краше весь несброшенный буфер теряется — то есть именно те строки,
ради которых логгер написан.
**Фикс:** периодический flush (таймер 2 с), обязательный flush на `LogLevel.error` и на
`AppLifecycleState.paused`.

### 🟡 2.12 Запрос точных будильников выбрасывает пользователя в системные настройки на первом старте
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

### 🟡 2.13 `_pollOnce` глотает любые исключения → бесконечный опрос
**Где:** `auth_controller.dart:442-485` — `catch (_)` без счётчика. Если BFF вернёт
`{"status":"completed"}` без токенов (баг деплоя/версий), `PairingStatus.fromJson`
(`pairing.dart:32-42`) бросит `TypeError` → погашен → **таймер бьёт каждые 2 секунды
бесконечно**, пользователь смотрит на спиннер. Плюс `PairingStart.expiresAt`
(`pairing.dart:16,22`) читается, но нигде не используется.
**Фикс:** счётчик неудач подряд (после N — показать ошибку и остановить), стоп по
`expiresAt`, логировать причину в `catch`.

### 🟡 2.14 Кэш `_lastGoodConfig` не разделяется между экземплярами `ApiClient`
**Где:** `api_client.dart:286` — поле экземпляра, а экземпляров четыре (см. 2.2).
Fallback «переиспользовать последнюю подписку» (`:310-314`) работает только внутри того
экземпляра, который уже успешно сходил за конфигом; `VpnController._connect` использует
**свой** клиент. При смене ключа старый `_lastGoodConfig` не инвалидируется — при обрыве
сети возможен коннект по подписке предыдущего ключа.
**Фикс:** один общий `ApiClient` на приложение либо вынести кэш в `ConfigCache` со сбросом
по `sessionMintedAt`.

### 🟡 2.15 `_waitForDisconnected` — busy-wait с фиксированным дедлайном, продублирован
**Где:** `vpn_controller.dart:832-839` и `home_screen.dart:318-328` — идентичный цикл с
окном 4 с. Дедлайн истекает молча: `_performAutoSwitch` (:802) идёт делать `_connect`
даже если туннель ещё не опустился — ровно та проблема, которую метод должен
предотвращать. При этом нативная остановка может занять больше: `VpnCoreServiceCoordinator.kt:29`
задаёт `RESTART_CLOSE_SUPPRESSION_MS = 15_000L` — **дедлайн клиента в 4 раза меньше окна
подавления в сервисе**.
**Фикс:** ждать событие из `stateStream` (`firstWhere(...).timeout(...)`) вместо polling,
вынести в один метод, увеличить окно до ~10 с, логировать истечение дедлайна.

### 🟢 2.16 Часовые пояса в напоминаниях — корректно, с оговорками
Проверено, багов нет: `tz.TZDateTime.from(when, tz.local)` сохраняет абсолютный момент,
`UILocalNotificationDateInterpretation.absoluteTime` это подтверждает; сервер отдаёт
`DateTimeOffset` со смещением, `DateTime.parse` его разбирает. Оговорки:
`_lastSignature` хранится только в памяти → каждый холодный старт делает `_cancelAll()` +
5 × `zonedSchedule` (10 лишних IPC); при `expiresAt` между рестартами напоминания просто
не запланируются; `_expiryLabel` при 0 часов покажет «истекает через 0 часов»
(`settings_screen.dart:190-193`).

### 🟢 2.17 Мелочи
- `api_client.dart:169` — `pollToken` не URL-кодируется (`?pollToken=$pollToken`);
  сломается на `&`, `=`, `+`, `/`. Использовать `Uri(...).replace(queryParameters: ...)`.
- `MainActivity.kt:15-30` — `MethodChannel` не снимается (`cleanUpFlutterEngine` →
  `setMethodCallHandler(null)`), `Thread` не отменяется, каждый вызов создаёт новый поток
  без пула.

---

## 3. ПРОИЗВОДИТЕЛЬНОСТЬ / БАТАРЕЯ / РАЗМЕР

### 🔴 3.1 Размер APK: ~236 МБ нативных библиотек, без ABI-фильтров и сплитов
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

### 🟠 3.2 Выбор лучшей ноды — строго последовательный пинг
**Где:** `vpn_controller.dart:841-852` — `await` в цикле, таймаут одного пинга 3 с
(`ping_service.dart:60,77`). Это путь **каждого нажатия «Подключить»** (:561), а в режиме
«Best server» кандидатами становятся все ноды всех стран (:339). При 20 нодах, из которых
5 недоступны, только на пинги уходит **15 секунд** сверх остального.

Контраст: в `_evaluateAutoSwitch` (:688-690) и в `home_screen.dart:231-233` те же пинги
делаются **параллельно** через `Future.wait` — паттерн в проекте известен, но в самом
горячем месте не применён.
**Фикс:** `Future.wait(nodes.map(...))` + early-exit при находке ноды < 80 мс.

### 🟡 3.3 Экран локаций пингует ноды последовательно
**Где:** `choose_location_screen.dart:97-104` — `await` в цикле + `setState` на каждую
ноду (полная перерисовка `ListView`). Раскрытие страны с 6 нодами, половина недоступна ≈
9 с постепенно появляющихся цифр.
**Фикс:** `Future.wait` + один `setState` на пачку.

### 🟡 3.4 Лишние запросы к BFF
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

### 🟡 3.5 Уведомление VPN перерисовывается раз в секунду всю сессию
**Где:** `SignboxLibboxServiceContract.kt:16` (`NOTIFICATION_STATS_INTERVAL_MS = 1000L`),
`VpnServiceNotificationGraph.kt:38-40`, `VpnLiveNotificationTicker.kt:14-27`.
При сессии 8 часов это **28 800 пересборок уведомления на главном потоке сервиса**,
каждая — Parcel + IPC в `NotificationManagerService` + перерисовка шторки. Плюс
`NotificationTrafficMonitor.captureSnapshot` читает `/proc` через `TrafficStats`.
Сам монитор уже сглаживает скорость на окне 250 мс — секундный тик не даёт точности,
только нагрузку.
**Фикс:** интервал 2-3 с; пропускать `notify()`, если форматированный текст не изменился;
останавливать тикер при выключенном экране (`ACTION_SCREEN_OFF`).

### 🟡 3.6 Секундный `Timer` на главном экране перерисовывает всё дерево
**Где:** `home_screen.dart:151-153` + `:170-174` — `setState` перестраивает **весь**
`build` (:407-433): хедер с `Image.asset`, карточку локации, кнопку питания с `BoxShadow`,
`_buildBestServers` с пересортировкой `_rankedServers` (`:244-255` — **`sort()` на каждом
кадре**) — и всё ради одной строки `_sessionLabel`. Дополнительно `main.dart:133-144`:
`ListenableBuilder(listenable: _auth)` оборачивает всё дерево, поэтому каждый
`notifyListeners()` в `AuthController` тоже перестраивает корень.
**Фикс:** таймер сессии в `ValueNotifier<Duration>` + `ValueListenableBuilder` только
вокруг `Text`; кэшировать `_rankedServers`; `const` для статики хедера.

### 🟡 3.7 Старт делает ~15 последовательных чтений из secure storage
**Где:** `connection_settings_controller.dart:152-163` — 11 последовательных
`await _storage.read(...)`; плюс `token_storage.dart:76-87` (3), device-key/session-kind/
key-code (3), `locale_controller.dart` (1), `vpn_controller._ensureInitialized` (1).
Каждое чтение — платформенный канал + расшифровка ключом Keystore; на бюджетных
устройствах 5-15 мс → **150-250 мс** последовательного ожидания ровно там, где идёт
борьба за время до первого кадра (`_minSplashTime = 1400 ms`).
**Фикс:** `Future.wait([...])` вместо цепочки `await`; несекретные данные (язык,
DNS-пресет, bypass-хосты, `vpn_session_started_at`) перенести в `SharedPreferences`.

### 🟡 3.8 Опрос `/pair/status` каждые 2 с без бэк-оффа и без остановки в фоне
**Где:** `auth_controller.dart:430`. Пользователь уходит в Telegram оплачивать подписку —
изолят продолжает жить, таймер бьёт: **30 HTTP-запросов в минуту** с мобильного радио.
`AwaitingAuthScreen` (`awaiting_auth_screen.dart:26-47`) не имеет `dispose()`, который
останавливал бы пэйринг.
**Фикс:** бэк-офф 2 → 3 → 5 с; пауза в `AppLifecycleState.paused` с немедленным
`_pollOnce()` на resume; жёсткий стоп по `expiresAt`; `dispose()` экрана останавливает таймер.

### 🟡 3.9 Всплеск параллельных TCP-соединений при загрузке главного экрана
**Где:** `home_screen.dart:231-239` — декартово произведение: все ноды всех стран
пингуются одновременно (10 стран × 4 ноды = 40 одновременных `Socket.connect`). На
мобильной сети это всплеск, портящий сами измерения (конкуренция за радио) и похожий на
скан для некоторых NAT/файрволов.
**Фикс:** пул на 6-8 одновременных соединений.

### 🟡 3.10 `http.Client` никогда не закрывается — по одному на каждый экран
**Где:** `api_client.dart:29`; метода `close()` у `ApiClient` нет. Экземпляры:
`home_screen.dart:35`, `vpn_controller.dart:27`, `settings_screen.dart:35` (**новый на
каждое открытие настроек**), `choose_location_screen.dart:46` (**новый на каждое
открытие**). Каждый держит собственный пул keep-alive соединений — утечка дескрипторов и
сокетов.
**Фикс:** `ApiClient.close()` → `_httpClient.close()` в `dispose()` экранов; либо один
общий `ApiClient` (заодно решает 2.14 и 3.4).

### 🟡 3.11 Список приложений для split-tunneling передаётся одним огромным сообщением
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

### 🟢 3.12 Watchdog туннеля — оценка энергопотребления: в целом хорошо
`VpnTunnelHealthPolicy.kt:37` (`CHECK_INTERVAL_MS = 60_000L`) + бэк-офф до 300 с после 4
неудачных восстановлений — разумно. `VpnTunnelHealthWatchdog.kt:62-68` использует
`Handler.postDelayed`, а не `AlarmManager` → **устройство не будится**. Пробы на отдельном
daemon-executor, не на main. `WakeLock` в проекте не используется вообще.
`hasUpstreamNetwork` предотвращает пробы без сети. Всё это сделано правильно.

Единственное замечание: каждая проба делает до **4 HTTP-запросов**
(`VpnTunnelHealthProbe.kt:70-82`), причём `delay` реально дёргает `gstatic.com` и
`cp.cloudflare.com` **через туннель** — за 8 часов 480 запросов через прокси.
**Фикс:** адаптивный интервал — 60 с после старта, 180 с после N здоровых проверок.

### 🟢 3.13 Дублирующий health-контур в Dart поверх нативного
**Где:** `vpn_controller.dart:83` (`_sessionHealthInterval = 3 мин`) → `_sessionHealthTick`
(:643-651) делает свою пробу `_verifyTunnelCarriesTraffic` (:458-482) параллельно с
нативным watchdog'ом, который делает то же самое каждую минуту. Плюс `syncFromRuntime` на
каждом resume запускает ещё одну пробу (:191).
**Фикс:** сделать Dart-сторону потребителем вердикта нативного watchdog'а (пробросить
через `stateDetailsStream`), а не независимым источником проб.

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
   `AndroidManifest.xml:16` (§1.1)
2. **Release keystore** — `build.gradle.kts:34` (§1.3)
3. **AAB + `abiFilters` без x86** — `build.gradle.kts` (§3.1)
4. **`await` при сохранении ротированного refresh-токена** — `auth_controller.dart:204` (§2.1)
5. **`allowBackup="false"`** — `AndroidManifest.xml:12` (§1.4)

### Спринт 1 (безопасность + корректность)
6. Секрет для clash-api — `singbox_config_builder.dart:131` (§1.6) 🔗
7. Disconnect при sign-out — `auth_controller.dart:487`, `settings_screen.dart:427` (§2.4)
8. Идемпотентный `_ensureInitialized` — `vpn_controller.dart:118` (§2.3)
9. `stderr.log` в `filesDir` — `VpnCoreSetupManager.kt:25` (§1.7)
10. `mounted`-гарды после `await` (§2.6)
11. Certificate pinning (§1.2)
12. Починить измерение пинга на Android — `ping_service.dart:32` (§2.5)

### Спринт 2 (производительность + UX)
13. Параллельный `_pickBestNode` — `vpn_controller.dart:841` (§3.2)
14. Единый `ApiClient` + кэш `/config`/`/servers` + refresh только по `exp` (§3.4, §2.14, §3.10)
15. Локализация всех пользовательских сообщений (§2.10)
16. Убрать `requestExactAlarmsPermission` со старта (§2.12)
17. Тик уведомления 1 с → 3 с (§3.5)
18. Точечная перерисовка таймера сессии (§3.6)
19. Устойчивый парсер `/config` (§2.7)
20. Бэк-офф и пауза в фоне для `/pair/status` (§3.8)

**Критерий приёмки:** `flutter analyze` без ошибок, `flutter test` зелёный; release-сборка
собирается как AAB и укладывается в лимиты Play; на устройстве — подключение, смена
сервера, sign-out при активном туннеле, холодный старт после kill процесса во время
рефреша (проверка §2.1).
