# Подключение Flutter-экранов к реальному BFF — статус

## Готово

Все 4 экрана (`app/lib/screens/`) переведены с хардкод-данных на реальные вызовы BFF.

**Решения (согласованы с заказчиком):**
- Короткий токен приложение получает через **deep link** от Telegram-бота: `fatvpn://token/<shortToken>`.
- Кнопка Connect на `HomeScreen` остаётся **UI-переключателем** — реальное VPN-туннелирование (sing-box/wireguard) не подключаем, это отдельная большая задача.
- Стек: `http` + `flutter_secure_storage` + `app_links` (без Riverpod/Bloc — состояние через `ChangeNotifier`).

**Новые файлы:**
- `app/lib/config/api_config.dart` — базовый URL BFF (`10.0.2.2:5030` для Android-эмулятора)
- `app/lib/models/{auth_session,server_country,account_status}.dart` — под точную форму JSON `AuthController`/`ServersController`/`MeController`
- `app/lib/services/token_storage.dart` — JWT в `flutter_secure_storage`
- `app/lib/services/api_client.dart` — `exchangeToken`, `getServers`, `getMe`, `getConfig`
- `app/lib/services/auth_controller.dart` — слушает deep link, обменивает short token на JWT, хранит сессию, экспонирует `isAuthenticated`
- `app/lib/screens/awaiting_auth_screen.dart` — экран ожидания, пока нет валидного JWT
- `app/lib/utils/country_flag.dart` — ISO-код страны → эмодзи-флаг (BFF отдаёт код, не эмодзи)

**Изменённые файлы:**
- `app/lib/main.dart` — `AuthController` создаётся на старте приложения, переключает `AwaitingAuthScreen` ↔ `HomeScreen`
- `app/lib/screens/home_screen.dart` — грузит `/servers`, передаёт `auth` дальше
- `app/lib/screens/choose_location_screen.dart` — грузит `/servers`; страна разворачивается в реальный список нод с живым пингом (см. "Реальные ноды и пинг" ниже)
- `app/lib/screens/settings_screen.dart` — грузит `/me` (статус/срок), добавлена кнопка Sign out (чистит токен)
- `app/pubspec.yaml` — добавлены `http`, `flutter_secure_storage`, `app_links`
- `app/android/app/src/main/AndroidManifest.xml` — intent-filter на `fatvpn://` scheme
- `app/ios/Runner/Info.plist` — `CFBundleURLTypes` на `fatvpn://` scheme

**Не тронуто (нет соответствующего API в BFF):**
- `split_tunneling_screen.dart` — список bypass-групп и DNS/Network stack в Settings остаются мок-данными.

## Проверено (без реальной БД, docker недоступен на момент разработки)

- `flutter analyze` — чисто
- Приложение собирается и запускается на эмуляторе (`emulator-5554`)
- `AwaitingAuthScreen` корректно показывается при отсутствии токена
- Deep link `adb shell am start -a android.intent.action.VIEW -d "fatvpn://token/AB12CD34" com.fatvpn.fatvpn_app` доходит до `AuthController`, вызывает `POST /auth/token`
- Найден и исправлен баг: сетевые ошибки (BFF недоступен) не ловились в `catch` (ловился только `ApiException`), из-за чего спиннer крутился бесконечно без сообщения — добавлен generic `catch` с понятным текстом ошибки в `auth_controller.dart`, `home_screen.dart`, `choose_location_screen.dart`, `settings_screen.dart`.

## Полный e2e-тест пройден (2026-07-04)

Docker установлен и работает. Поднят локальный Postgres (`docker-compose up -d postgres` — сервис `bff` из compose не собирается локально, см. известную проблему ниже), накатаны миграции, `dotnet run` API поднят на `http://localhost:5030`.

Прогнан полный цикл на эмуляторе `emulator-5554`:
1. `POST /internal/tokens` (с `Bot:Secret` из `appsettings.Development.json`) — регистрация short-токена → 201.
2. `adb shell am start -a android.intent.action.VIEW -d "fatvpn://token/<shortToken>" com.fatvpn.fatvpn_app` — deep link.
3. Приложение само переходит с `AwaitingAuthScreen` на `HomeScreen`, дергает `POST /auth/token`, сохраняет JWT.
4. `HomeScreen`/`ChooseLocationScreen` грузят `GET /servers` — реальный список стран/нод из Remnawave (DE/NL/FI/ES/FR/US/NO/TR/AM).
5. `Settings` грузит `GET /me` — реальный статус подписки ("Active, expires in N days").
6. `Sign out` корректно чистит сессию, возвращает на `AwaitingAuthScreen`.

**Найден и исправлен реальный баг**: в `app/android/app/src/main/AndroidManifest.xml` отсутствовало разрешение `android.permission.INTERNET` и `android:usesCleartextTraffic="true"` — без них Android блокирует сетевые запросы (BFF работает по `http://`, не `https://`). Добавлены оба атрибута.

**Известное ограничение**: `GET /config` возвращает 502, т.к. тестовый `remnawaveSubscriptionId` ("test-subscription-id") не существует как реальная подписка в Remnawave-панели — это ожидаемо для синтетических тестовых токенов, не баг. `docker-compose up -d` (без указания сервиса) также падает при сборке `bff`-образа — `nuget.config` в репозитории ссылается на Windows-путь (`C:\Program Files (x86)\Microsoft Visual Studio\Shared\NuGetPackages`), которого нет в Linux-контейнере; для локальной разработки достаточно `docker-compose up -d postgres` + `dotnet run` напрямую, прод использует уже собранный образ на сервере.

## Реальные ноды и пинг на ChooseLocationScreen (2026-07-04)

`GET /servers` теперь отдаёт для каждой страны не только агрегат, но и полный список реальных нод:

```
[{ "country": string, "flag": string, "nodeCount": int,
   "nodes": [{ "id": string, "name": string, "address": string, "port": int, "usersOnline": int }] }]
```

**Бэкенд:**
- `backend/src/FatVpn.Bff.Infrastructure/Remnawave/IRemnawaveClient.cs` — `ServerCountry.Nodes` (был `PingHost: string`, стал `Nodes: IReadOnlyList<ServerNode>`), новый record `ServerNode(Id, Name, Address, Port, UsersOnline)`.
- `RemnawaveClient.GetNodesAsync` — группирует реальные ноды Remnawave (`uuid`, `name`, `address`, `port`, `usersOnline` из `GET /api/nodes`) по `countryCode`, без изменений выдуманных/агрегированных данных.
- `docs/api-contract.md` обновлён под новую форму ответа.

**Flutter:**
- `app/lib/models/server_country.dart` — добавлен класс `ServerNode`, `ServerCountry.nodes` вместо `pingHost`.
- `app/lib/services/ping_service.dart` (новый) — измеряет реальный пинг TCP-коннектом (`Socket.connect` с таймаутом 3с) до `address:port` ноды. ICMP-пинга на мобильных платформах без нативного кода/root нет, и Remnawave не отдаёт клиентскую задержку, поэтому TCP-хендшейк до настоящего адреса ноды — ближайший реалистичный прокси для "пинга".
- `app/lib/screens/choose_location_screen.dart` — тайл страны разворачивается по тапу (как в исходном мокапе), показывает список реальных нод с именем и измеренным пингом (или "unreachable", если TCP-коннект не удался); выбор страны — отдельной кнопкой "Select".

**Проверено на эмуляторе:** развернул NL (2 ноды) — увидел реальные имена `neth_play2` (292ms) и `FAT-Netherlands-1CENT` (1102ms), пинг посчитан вживую с устройства.

## Локализация EN/RU (2026-07-05)

Добавлен переключатель языка (EN/RU) в `SettingsScreen` — не полноценный `flutter_localizations`/`.arb`, а лёгкий кастомный слой, т.к. нужен был только ручной переключатель, а не системная локаль устройства.

**Новые файлы:**
- `app/lib/l10n/strings.dart` — класс `Strings` со всеми UI-строками, две константы `enStrings`/`ruStrings`; русские плюральные формы (день/дня/дней, час/часа/часов, сервер/сервера/серверов) считаются по стандартным правилам склонения.
- `app/lib/services/locale_controller.dart` — `ChangeNotifier`, хранит `AppLanguage` в `flutter_secure_storage` (ключ `app_language`), переживает перезапуск приложения.
- `app/lib/l10n/app_localizations.dart` — `InheritedNotifier`-обёртка вокруг `LocaleController`; `S.of(context)` возвращает текущий `Strings`.

**Изменённые файлы:**
- `app/lib/main.dart` — `MaterialApp` обёрнут в `AppLocalizationsScope`.
- Все 5 экранов (`home`, `settings`, `choose_location`, `awaiting_auth`, `split_tunneling`) переведены со статичных строк на `S.of(context)`.
- `SettingsScreen`, секция SYSTEM — `SegmentedButton<AppLanguage>` EN/RU вместо статичной строки "English".

**Не тронуто намеренно:** имена стран/нод (реальные данные Remnawave), сообщения об ошибках API (`e.message` приходит с BFF как есть), пользовательские данные в split tunneling (например, название bypass-группы) — это динамический контент, а не UI-лейблы.

**Проверено на эмуляторе (`emulator-5554`):** переключение EN→RU в Settings мгновенно перекрашивает весь UI без перезапуска экрана (`ChangeNotifier` + `InheritedNotifier`) — проверены Settings, Home, ChooseLocation; склонения "27 дней", "1 сервер" / "2 сервера" отображаются корректно.

## Бэкенд: `POST /trial` (2026-07-05)

Реализован и проверен end-to-end на локальном Postgres (эндпоинт бэкенда, Flutter-сторона ещё не подключена — приложение продолжает работать через deep-link токен от бота).

- `backend/src/FatVpn.Bff.Api/Controllers/TrialController.cs` — `POST /trial`: хеширует `attestationToken` (соль + SHA256) как ключ устройства, проверяет анти-абуз по таблице `Trials`, берёт свободный слот из пула Remnawave-подписок, выдаёт JWT на `Trial:DurationDays` (по умолчанию 3 дня, конфигурируемо).
- `backend/src/FatVpn.Bff.Api/Controllers/InternalTrialPoolController.cs` — `POST/GET /internal/trial-pool`: наполнение и статус пула триальных подписок, защищено тем же `X-Bot-Secret`.
- `backend/src/FatVpn.Bff.Domain/TrialSubscriptionSlot.cs` + EF-миграция `AddTrialSubscriptionPool`.
- Полный контракт и известные MVP-упрощения (attestation не верифицируется, пул подписок наполняется вручную) — см. `docs/api-contract.md`.
- **Проверено:** наполнение пула → выдача триала → JWT → `GET /me` (`active`) → повторная попытка того же устройства → `409` → пул исчерпан → `503`.
- ⚠️ **Перед проды**: `Trial:DeviceKeySalt` пуст в `appsettings.json` — задать реальное значение через `dotnet user-secrets`/container env до реального использования (см. `CLAUDE.md`, раздел Production Server).

## Реальное VPN-туннелирование (Android, 2026-07-05)

Кнопка Connect на `HomeScreen` перестала быть UI-переключателем — теперь она реально поднимает VPN-туннель через sing-box.

**Решение:** взят готовый Flutter-плагин `singbox_mm` (git-зависимость на `https://github.com/thethtwe-dev/singbox_mm.git`, не pub.dev — опубликованный тарбол содержит бинарник только под `arm64-v8a`, а полный git-репозиторий даёт ещё и `x86_64` для эмулятора). Плагин реализует настоящий libbox JNI-мост (готовые `libbox.so`, без сборки Go на машине разработчика) — рассматривался и альтернативный `v2ray_box`, но у него VPN-режим всегда поднимает и sing-box, и Xray-core с самодельным SOCKS-мостом между ними и требует собирать оба нативных ядра через Go; `singbox_mm` архитектурно проще и не требует Go-тулчейна вообще.

**Ключевая находка при подключении:** `GET /servers` отдаёт для ноды `port` — это служебный порт агента Remnawave (`2222`), не реальный клиентский inbound-порт (в реальности 443/8443/2083/18443 и т.д., у одной ноды их может быть несколько под разные транспорты). Поэтому сопоставление ноды из `/servers` с `vless://` URI из `/config` в `vless_config_parser.dart` идёт **только по адресу**, порт не сравнивается.

**Новые файлы:**
- `app/lib/services/vless_config_parser.dart` — декодирует base64-блок из `/config` в список `vless://` URI, ищет URI по адресу ноды.
- `app/lib/services/vpn_controller.dart` — `ChangeNotifier`-обёртка вокруг `SignboxVpn`: `connectToBestNode()` меряет пинг по всем нодам страны (переиспользует `PingService`), выбирает самую быструю, тянет `/config`, находит нужный URI и вызывает `connectManualConfigLink()` (сам плагин внутри запрашивает VPN- и notification-разрешения и бросает понятное исключение при отказе).

**Изменённые файлы:**
- `app/pubspec.yaml` — git-зависимость `singbox_mm`.
- `app/lib/screens/home_screen.dart` — `_toggleConnection` заменён на реальный async-вызов `VpnController`; статус/таймер сессии/ошибка подключения теперь идут от настоящего `VpnConnectionState`, а не от локального bool.
- `app/lib/l10n/strings.dart` — добавлена строка `connecting` (EN/RU).
- `AndroidManifest.xml` — без изменений: разрешения и объявление `VpnService` уже приезжают через Gradle manifest merger из собственного манифеста плагина (подтверждено на его example-приложении).

**Проверено на эмуляторе (`emulator-5554`), сначала на example-приложении плагина, потом в самом FatVPN:**
- Реальный `vless://` (grpc-транспорт) из живой Remnawave-подписки корректно распознан плагином (`Config Protocol: vless (supported)`), ядро sing-box v1.13.11.
- В **собственном** приложении: локальный BFF + реальный Remnawave-пользователь → `HomeScreen` → Connect → системные диалоги VPN/notification permission → «Подключено к DE», таймер идёт, 🔑-иконка в статус-баре Android → Disconnect → чистый возврат в «Отключено».
- Известное ограничение подтверждено на практике: `GET /config` возвращает 502 для синтетических тестовых токенов (тестовый `remnawaveSubscriptionId` не существует в Remnawave) — для проверки нужен реальный `remnawaveSubscriptionId` живого пользователя (получен через `GET /api/users` на панели и зарегистрирован вручную через `POST /internal/tokens`).
- **xHTTP отдельно проверен (2026-07-05, на example-приложении плагина):** реальная нода `81.222.127.189:443` (xHTTP + кастомные anti-detection параметры — xmux, padding, `uplinkHTTPMethod=DELETE` и т.д.) подключилась и дала `Detail: OK / validated=true` с живым трафиком (~3.5 KB/s download, 39 KB за 42 секунды). Снимает риск из `VPN-App-Project.md` п.14 ("xHTTP реально используется в проде") хотя бы для этой конфигурации — см. там же за деталями и остаточным риском для других xHTTP-нод.

**Проверено на реальном физическом телефоне (2026-07-05):** Xiaomi Redmi Note 7 (Android 10, `arm64-v8a`) по USB. Тот же полный цикл, что на эмуляторе — Connect → «Connected to DE» с таймером сессии и бейджем **VPN** в статус-баре Android → Disconnect → чистый возврат в «Disconnected». Подтверждает, что плагин реально работает не только в виртуальном окружении эмулятора.
- Для теста на физическом устройстве BFF на `10.0.2.2` (алиас только для эмулятора) недоступен — пришлось временно указать в `app/lib/config/api_config.dart` `http://localhost:5030` и прокинуть порт через `adb reverse tcp:5030 tcp:5030` (работает поверх USB, не зависит от Wi-Fi). Изменение отменено сразу после теста, в git не попало.
- На MIUI (Xiaomi) `adb shell input tap` не работает без отдельной настройки «Отладка USB (безопасность)» в Параметрах разработчика (`SecurityException: Injecting to another application requires INJECT_EVENTS permission`) — кнопки нажимались вручную на устройстве.

**Известное ограничение среды:** сборка native-библиотек плагина под 4 ABI разом требует несколько ГБ временного места на диске при `flutter build apk` — если диск C: почти заполнен, `mergeDebugJniLibFolders`/`bundleDebugAar` падают с `FileSystemException`/`not enough space on the disk`. Обход для теста на конкретном устройстве — собирать только под нужный ABI: `flutter build apk --release --target-platform android-arm64`.

## Авто-выбор лучшего сервера и ранжирование по пингу (2026-07-05)

Доработан UX выбора сервера на `HomeScreen` по замечаниям заказчика.

**Изменения:**
- **Авто-подключение к лучшему серверу при первом запуске.** Раньше при загрузке `/servers` первая страница списка молча выбиралась как `_selectedServer`. Теперь, пока пользователь явно не выбрал локацию (флаг `_serverExplicitlySelected`), Connect вызывает новый `VpnController.connectToBestOverall(countries, token)` — тот пингует ноды **всех** стран сразу, подключается к самой быстрой в целом и возвращает её страну, чтобы отразить авто-выбор в UI. Если пользователь выбрал страну руками — работает прежний `connectToBestNode(country, token)`.
- **Нижний блок «Best Servers» больше не хардкод-порядок стран.** После загрузки `/servers` асинхронно (`_measureBestPings`) меряется реальный TCP-пинг до каждой ноды; для страны берётся минимальный пинг среди её нод, страны сортируются по нему (`_rankedServers`), в блок попадают топ-3 реально быстрейших. Под флагом показывается измеренный пинг (`XXXms`/`unreachable`) со спиннером во время замера — как на `ChooseLocationScreen`.
- **Выбор сервера подсвечивается и в отключённом режиме.** Раньше рамка выбранного сервера и название страны в верхней карточке показывались только при активном соединении (`_connected && ...`). Теперь тап по серверу сразу подсвечивает его и обновляет карточку локации даже без подключения (`_serverExplicitlySelected`).

**Исправлен баг «No matching config for \<node\>».** `GET /servers` перечисляет **все** ноды Remnawave независимо от squad, а `/config` содержит `vless://` только для нод, реально входящих в подписку пользователя. `connectToBestNode` выбирал быстрейшую ноду среди всех нод страны и падал `StateError`, если её не было в конфиге. Теперь `VpnController._connect` сначала пересекает список кандидатов с нодами из `/config` и выбирает лучший пинг уже среди доступных.

**Изменённые файлы:**
- `app/lib/services/vpn_controller.dart` — общий `_connect(candidates, token)` (фильтрует кандидатов по `/config`), `connectToBestNode` и новый `connectToBestOverall` поверх него.
- `app/lib/screens/home_screen.dart` — `_serverExplicitlySelected`, `_measureBestPings`/`_bestPingByCountry`/`_rankedServers`, подсветка выбора в offline-режиме, пинг под флагами.
- `app/pubspec.yaml` — версия поднята до `1.0.1+2`.

**Проверено на физическом телефоне (Redmi Note 7, релизный arm64-APK):** установлен `1.0.1+2`, авторизация через deep link на реальную подписку, блок «Best Servers» ранжируется по живому пингу, выбор подсвечивается в отключённом режиме. `adb reverse tcp:5030` слетает при переподключении USB/перезапуске adb-демона — при обрыве связи с BFF первым делом восстанавливать его.

## Settings: реальные DNS и Network stack (2026-07-05)

DNS-сервер и Network stack в `SettingsScreen` перестали быть мок-строками — теперь это настоящие настройки, сохраняются между запусками и применяются к туннелю при следующем подключении.

**Как прокидывается в туннель:** `singbox_mm.connectManualConfigLink(...)` принимает `featureSettings: SingboxFeatureSettings`. Раньше приложение его не передавало (действовали дефолты плагина). Теперь `VpnController._connect` собирает `featureSettings` из пользовательских настроек **на каждом коннекте**, поэтому правки в Settings вступают в силу при следующем (пере)подключении — под карточкой CONNECTION SETTINGS показана подсказка «Применится при следующем подключении».

**Маппинг:**
- **DNS-сервер** → `DnsOptions.fromProvider(preset:)`. В UI четыре пресета: Cloudflare (1.1.1.1), Google (8.8.8.8), Quad9 (9.9.9.9), AdGuard (94.140.14.14). `custom` пока не выводим — под него нужен текстовый ввод резолвера (отдельная задача).
- **Network stack** → `InboundOptions(tunImplementation:)`. Два значения плагина: `system` (в UI подписан «Mixed», как в мокапе) и `gVisor`.

**Дефолты выбраны так, чтобы не менять уже проверенное на устройстве поведение туннеля:** до этой правки `featureSettings` не передавался → действовали дефолты плагина (Cloudflare-подобный DNS, gVisor tun). Поэтому стартовые значения — Cloudflare + gVisor.

**Новые/изменённые файлы:**
- `app/lib/services/connection_settings_controller.dart` (новый) — `ChangeNotifier`, хранит DNS-пресет и tun-стек в `flutter_secure_storage` (ключи `conn_dns_preset`/`conn_network_stack`), собирает `SingboxFeatureSettings.buildFeatureSettings()`. Паттерн как у `LocaleController`.
- `app/lib/services/vpn_controller.dart` — конструктор принимает `ConnectionSettingsController`, `_connect` передаёт `featureSettings` в `connectManualConfigLink`.
- `app/lib/main.dart` — контроллер создаётся на старте (`.load()`), прокидывается в `HomeScreen`.
- `app/lib/screens/home_screen.dart` — принимает и форвардит контроллер в `VpnController` и `SettingsScreen`.
- `app/lib/screens/settings_screen.dart` — статичные строки DNS/Network stack заменены на реактивные пикеры (`AnimatedBuilder` + модальный bottom-sheet с галочкой на выбранном) + подсказка о реконнекте.
- `app/lib/l10n/strings.dart` — строка `appliesOnNextConnection` (EN/RU). Имена DNS-провайдеров и Mixed/gVisor — технические/брендовые, не локализуются.

**Проверено:** `flutter analyze` — чисто. Runtime-прогон на устройстве (сохранение выбора между запусками + фактическое применение DNS/стека к живому соединению) — требует поднятого BFF и реальной Remnawave-подписки, **ещё не прогнан**.

**Осталось из этого блока:** split tunneling (см. пункт 5 ниже) — по решению заказчика вынесен в отдельную задачу.

## Pairing-онбординг вместо deep-link токена (2026-07-05)

Заказчику не нравилась старая схема входа (short-токен из чата → deep link). Переделано на **pairing**: приложение — точка входа, кнопка ведёт в бот, после покупки/связывания приложение подключается само. Бэкенд-часть — Фаза 1 (см. `docs/api-contract.md`, `Account`/`PairingCode`), сторона бота — `docs/bot-pairing-spec.md`. Здесь — **Фаза 2 (Flutter)**.

**Флоу:** `AwaitingAuthScreen` (переделан в онбординг) при открытии зовёт `POST /pair/start` → показывает кнопку «Connect with Telegram» (`url_launcher` → `t.me/<bot>?start=pair<code>`) + QR (`qr_flutter`) и сам код как fallback для кросс-девайса. Фоном каждые 2с поллит `GET /pair/status`; на `completed` сохраняет JWT и `main.dart` переключает на `HomeScreen`.

**Новые файлы:** `models/pairing.dart` (`PairingStart`/`PairingStatus`), правки `api_config.dart` (`telegramBotUsername`, `telegramPairLink`).
**Изменённые:** `api_client.dart` (`startPairing`/`pollPairing` + **таймауты** 15с/10с; `getServers` теперь принимает JWT — эндпоинт закрыт `[Authorize]`), `auth_controller.dart` (pairing-логика + поллинг; deep-link оставлен на переход), `awaiting_auth_screen.dart` (полноценный экран), `home_screen.dart`/`choose_location_screen.dart` (токен в `getServers`), `strings.dart` (EN/RU), `pubspec.yaml` (`url_launcher`, `qr_flutter`).

**Проверено на эмуляторе (`emulator-5554`) end-to-end:** `/pair/start` → экран с кнопкой/QR/кодом → поллинг `pending` → завершение через `POST /internal/pair/complete` (имитация бота) → app сохраняет account-JWT и переходит на `HomeScreen` с живыми пингами через авторизованный `/servers`. Прогон логировался (`[PAIR]` poll trace) и подтверждён скриншотами.

**Найдены и исправлены 2 реальных дефекта устойчивости:**
- HTTP-вызовы pairing не имели таймаута → при потере ответа юзер застревал на спиннере навсегда. Добавлены таймауты → падает в состояние ошибки с кнопкой «Get a new code».
- `_tokenStorage.save()` (Android Keystore) на эмуляторе иногда **зависает**, блокируя переход. Порядок изменён: **сначала `notifyListeners()` (переход), потом best-effort `unawaited(save())`** — медленное/зависшее хранилище больше не мешает входу.
- Плюс guard `_pollInFlight` от наложения тиков (двойная обработка `completed`).

**Замечание по тесту:** BFF на `10.0.2.2:5030` из эмулятора периодически терял ответы (нестабильный NAT-loopback эмулятора) — для стабильного прогона использовался `adb reverse tcp:5030` + временный `localhost` в `api_config` (откат сразу после теста, в git не попало).

## Фаза 3 (бот) + деплой + e2e на реальном телефоне (2026-07-06)

**Сторона бота реализована и задеплоена** на тестовый сервер (см. `docs/bot-pairing-spec.md`, там status = deployed). Кратко: `main_refactored.py` ловит `/start pair<code>` → `handle_pair` (берёт последний ключ юзера, шлёт `complete_pairing`; нет ключа → запоминает код и завершает pairing автоматически после выдачи ключа); хуки `upsert_subscription` в `db_remnawave` (создание/смена/extend-refresh) и `key_handlers` (продление); новый `services/pairing_state.py`.

**Деплой (тестовый сервер `87.121.221.229`):**
- Ветка `feat/pairing-onboarding` запушена; BFF-checkout (`/opt/fatvpn-bff`) переключён на неё, пересобран — миграция `AddAccountAndPairing` применена к боевому Postgres.
- Бот: 5 файлов залиты (md5 сверены), контейнер пересобран, полит без ошибок. Проводка бот→BFF проверена (реальный `upsert_subscription` из контейнера → 200).
- **BFF выставлен наружу (HTTP):** порт `127.0.0.1:5030` → `0.0.0.0:5030`; **Postgres** забиндён на `127.0.0.1:5433`; включён `ufw` (22/5030/4444). Починен предсуществующий баг compose бота (дублированный ключ `networks:`, ронял `docker compose` v2). Бэкапы на сервере: `/root/docker-compose.yml.bak*`, `/root/bot-compose.yml.bak`, `/root/bot-bak/`.

**E2E подтверждён на реальном телефоне (Redmi Note 7):** собран **универсальный release-APK** (`api_config.dart` → `http://87.121.221.229:5030`, лежит в `dist/FatVPN-demo-1.0.1.apk`, ~225 МБ), установлен по USB. Пользователь прошёл pairing через `@testfatvpnnbot` и подключился. **VPN реальный:** публичный IP выхода телефона совпал с адресом ноды `arm_4vps` (`45.130.254.49`) — трафик реально идёт через ноду (не муляж).

**Осталось по pairing:** HTTPS + домен (сейчас HTTP по IP — не для сторов); merge `feat/pairing-onboarding` → `master`; полный pairing через живой Telegram у нескольких юзеров; перенос на прод-бота (спека — `bot-pairing-spec.md`).

## Русский по умолчанию + язык и ручной ввод ключа на стартовом экране (2026-07-06)

По замечанию заказчика доработан онбординг (`AwaitingAuthScreen`).

**Русский по умолчанию.** `LocaleController` стартует с `AppLanguage.ru`; `load()` теперь
переключает на английский только если пользователь **явно** выбирал `en` ранее (ключ
`app_language` в `flutter_secure_storage`). Раньше дефолт был `en`. Выбор по-прежнему
переживает перезапуск.

**Переключатель языка на первом экране.** В правом верхнем углу `AwaitingAuthScreen`
добавлен компактный сегментный тоггл `RU | EN` (`_LanguageToggle`) — тап сразу
перекрашивает весь UI (общий `LocaleController` через `InheritedNotifier`) и сохраняет
выбор. Дублирует переключатель в `SettingsScreen`, состояние синхронно (один контроллер).

**Ручной ввод ключа (оба варианта входа).** Pairing остаётся основным способом, но под
разделителем добавлен сворачиваемый блок **«У меня уже есть ключ»** (`_ManualKeyEntry`):
поле ввода 32-символьного токена + кнопка «Подключить». Вызывает существующий
`AuthController.exchangeShortToken` (legacy deep-link-путь, claim `fatvpn_token_id`) —
нужен пользователю, купившему ключ на **другом Telegram-аккаунте**: в боте на том
аккаунте «Поменять ключ» выдаёт 32-символьный код, его и вставляют. Ошибка
(неверный/просроченный токен) показывается в общем блоке ошибки сверху.

**Изменённые файлы:** `services/locale_controller.dart` (дефолт ru), `l10n/strings.dart`
(`haveKeyTitle`/`enterKeyHint`/`submitKey`, EN/RU), `screens/awaiting_auth_screen.dart`
(`_LanguageToggle`, `_ManualKeyEntry`).

**Проверено:** `flutter analyze` — чисто. Runtime-прогон на эмуляторе/устройстве
(визуальная проверка тоггла и обмена токена) — ещё не прогнан.

## Split tunneling (Android, 2026-07-06)

Раньше `SplitTunnelingScreen` был мок-экраном (хардкод-группа «Russian services»,
кнопки-заглушки). Теперь это рабочий выбор приложений в обход VPN.

**Как работает.** Выбранные приложения (по `packageName`) прокидываются в
`InboundOptions(splitTunnelingEnabled: true, excludePackages: [...])` →
плагин `singbox_mm` кладёт их в `route`/`inbound` sing-box как `exclude_package`.
Применяется при следующем (пере)подключении (как DNS/стек — та же подсказка
`appliesOnNextConnection`). Режим — **exclude** (выбранные приложения идут мимо
туннеля), как в UI-спеке «Apps that bypass the VPN».

**Список приложений — свой нативный channel (2026-07-07).** `singbox_mm` список
приложений не даёт. Сначала пробовали пакет `installed_apps`, но у него фильтр
только по `FLAG_SYSTEM`: с `excludeSystemApps: true` прятались предустановленные
браузеры (Chrome, Mi Browser — а их-то и хотят пускать мимо VPN), а с `false`
вываливались все служебные пакеты (`com.android.systemui…` и т.п.). Правильный
набор — **только запускаемые приложения** (те, что в лаунчере). Поэтому сделан
собственный platform-channel `fatvpn/apps` (`MainActivity.kt` →
`queryIntentActivities(MAIN/LAUNCHER)`, отдаёт `name`/`packageName`/PNG-иконку),
Dart-обёртка `services/installed_apps_service.dart`. Пакет `installed_apps` **удалён**,
вместе с ним ушёл флаг **`QUERY_ALL_PACKAGES`** (проблемный для Play) — вместо него
в манифест добавлен `<queries>` с `MAIN/LAUNCHER`-интентом (даёт видимость только
launcher-приложений, без всеобъемлющего разрешения).

**Состояние и хранение.** Расширен `ConnectionSettingsController` (не отдельный
контроллер — он уже собирает `featureSettings` и прокинут в `VpnController`):
`splitTunnelEnabled` + `Set<String> bypassPackages`, ключи `conn_split_enabled`/
`conn_split_packages` в `flutter_secure_storage`. `buildFeatureSettings()` включает
bypass только когда фича включена И выбран хотя бы один пакет (пустой список — no-op).

**Изменённые/новые файлы:** `services/connection_settings_controller.dart`
(split-состояние + маппинг), `services/installed_apps_service.dart` (новый — обёртка
над нативным channel), `android/.../MainActivity.kt` (channel `fatvpn/apps`),
`android/.../AndroidManifest.xml` (`<queries>` MAIN/LAUNCHER),
`screens/split_tunneling_screen.dart` (тоггл, поиск, список запускаемых приложений
с иконками и чекбоксами), `screens/settings_screen.dart` (прокинут `connectionSettings`),
`l10n/strings.dart` (`searchApps`/`loadingApps`/`splitTunnelDisabledHint`, EN/RU),
`pubspec.yaml` (удалён `installed_apps`).

**Проверено на реальном телефоне (Redmi Note 7, 2026-07-07) — работает:**
в списке — только launcher-приложения (Chrome есть, служебных пакетов нет);
отметили Chrome «в обход VPN», подключились → `2ip.ru` в Chrome показал реальный
IP устройства (мимо туннеля); сняли галочку, переподключились на ноду NO →
`2ip.ru` показал норвежский IP ноды. Один браузер, разный маршрут по галочке —
split tunneling реально управляет трафиком по приложениям. `flutter analyze` — чисто.

## Trial на старте (2026-07-06)

Бэкенд `POST /trial` был реализован ещё 2026-07-05, но Flutter-сторона к нему не
была подключена (вход шёл только через pairing/ключ). Теперь на онбординге есть
кнопка **«Попробовать 3 дня бесплатно»**.

**Флоу.** Кнопка на `AwaitingAuthScreen` → `AuthController.requestTrial` → берёт
стабильный **device-key** и зовёт `POST /trial` → на 200 сохраняет account-JWT и
`main.dart` переключает на `HomeScreen`. Ошибки локализованы: `409` →
«пробный уже использован», `503` → «нет свободных слотов», прочее → generic.

**Device-key (MVP `attestationToken`).** `TokenStorage.readOrCreateDeviceKey()` —
случайный 32-байтный ключ в `flutter_secure_storage`, создаётся один раз и
**не удаляется при sign-out** (иначе выход давал бы устройству второй триал).
Play Integrity / App Attest — отдельная задача (см. `docs/api-contract.md`).
Ограничение: переустановка приложения сбрасывает ключ → возможен повторный триал;
для MVP приемлемо, реальная привязка — через настоящую аттестацию.

**Изменённые файлы:** `services/token_storage.dart` (device-key),
`services/api_client.dart` (`startTrial`), `services/auth_controller.dart`
(`requestTrial` + `trialBusy`), `screens/awaiting_auth_screen.dart` (кнопка +
спиннер), `l10n/strings.dart` (`tryFreeTrial`/`trialAlreadyUsed`/`trialNoCapacity`/
`trialFailed`, EN/RU).

**Проверено:** `flutter analyze` — чисто. Runtime-прогон (реальная выдача триала из
пула на устройстве) — **ещё не прогнан**; напоминание: пул `TrialSubscriptionSlots`
на сервере нужно наполнить через `POST /internal/trial-pool`, а `Trial:DeviceKeySalt`
задать перед проды (см. `CLAUDE.md`).

## Триал как точка входа: выдача на лету + авто-коннект (2026-07-07)

Смена принципа по замечанию заказчика (Robert): случайный юзер из стора должен
получить **бесплатный ключ сразу**, чтобы поднять VPN и только потом открыть
Telegram (который у него без VPN может не работать) и купить ключ.

**Бэкенд — выдача на лету.** `POST /trial` больше не берёт подписку из пула, а
**создаёт нового пользователя в Remnawave** (`POST /api/users`, squad
`Remnawave:TrialSquadUuid` = `Default-Squad`, 3 дня). Масштабируется на любой поток
установок без ручного пополнения. Изменённые файлы: `RemnawaveClient`
(+`CreateTrialUserAsync`), `IRemnawaveClient`, `RemnawaveOptions` (+`TrialSquadUuid`),
`TrialController` (пул → создание на лету, 502 при сбое Remnawave). **Задеплоено на
тестовый сервер и проверено** (curl 200 + телефон).

**Онбординг — триал главной кнопкой.** На `AwaitingAuthScreen` primary-кнопка —
**«Попробовать 3 дня бесплатно»** (зелёная, `Icons.bolt`), Telegram/QR/ручной ключ —
вторичные. Кнопка показывается **только если устройство ещё не брало триал**
(`AuthController.trialAvailable` = `!hasAttemptedAutoTrial`); если триал уже был —
её нет, primary становится «Подключить через Telegram». Тихий авто-триал на старте
(промежуточный вариант) убран — юзер видит экран и жмёт кнопку сам.

**Авто-коннект после триала.** После успешной выдачи `AuthController` выставляет
одноразовый флаг `consumeAutoConnect()`; `HomeScreen` после загрузки `/servers`
сам поднимает туннель к лучшей ноде (`connectToBestOverall`) — один системный диалог
VPN-разрешения, дальше юзер уже в VPN.

**Проверено на реальном телефоне (Redmi Note 7, 2026-07-07):** свежая установка →
онбординг с кнопкой «3 дня бесплатно» → тап → триал создан в Remnawave → авто-коннект
→ **реальный VPN подключён к AM** (бейдж VPN в статус-баре, таймер сессии идёт).

**Изменённые файлы (app):** `services/auth_controller.dart` (`trialAvailable`,
`consumeAutoConnect`, `_grantTrial` ставит авто-коннект; silent-auto-trial убран),
`services/token_storage.dart` (`hasAttemptedAutoTrial`/`markAutoTrialAttempted`,
device-key), `services/api_client.dart` (`startTrial`), `screens/awaiting_auth_screen.dart`
(триал primary, `_telegramButton` primary/secondary, компактный одноэкранный layout),
`screens/home_screen.dart` (`_autoConnect`), `main.dart` (простой лоадер).

## Выбор локации и переподключение — доработки (2026-07-07)

Пачка правок по замечаниям заказчика во время живого теста на телефоне.

**«Лучший сервер» — отдельный выбираемый пункт.** Раньше на `ChooseLocationScreen`
«Лучший сервер» был только заголовком, его нельзя было выбрать, и после выбора
конкретной страны **нельзя было вернуться к авто**. Теперь вверху списка —
отдельная плитка «Лучший сервер / Автоматически» с бейджем **АКТИВНО** (когда
активен авто-режим) либо кнопкой «Выбрать». Выбор возвращается на `HomeScreen`
через новый тип `LocationSelection` (`.best()` / `.country(...)`): `.best()`
сбрасывает явный выбор (`_serverExplicitlySelected=false`) → Connect снова берёт
быстрейшую ноду в целом. Текущий выбор подсвечивается (рамка + бейдж).

**Список локаций фильтруется по подписке.** `/servers` отдаёт **все** ноды
Remnawave независимо от сквода, поэтому в списке были страны, к которым подписка
(триал) не может подключиться — выбор такой давал `No available node in this
subscription`. Добавлен `ApiClient.getUsableServers()`: тянет `/servers` и
`/config`, оставляет только страны/ноды, реально присутствующие в подписке
(пересечение по адресу через `vless_config_parser`). Фолбэк на полный список, если
`/config` недоступен. Используется в `HomeScreen` и `ChooseLocationScreen`. Фильтр
**динамический** — появится нода в подписке, появится и в списке.

**Переключение локации сразу применяется (авто-реконнект).** Раньше смена страны
только меняла `_selectedServer`, а туннель оставался на старой ноде — применялось
лишь после ручного выкл/вкл. Теперь смена локации (из списка **и** из тайлов
«Лучшие серверы») переподключает на выбранную. Тайлы «Лучшие серверы» стали
one-tap quick-connect (тап = подключение/переключение, а не просто подсветка).

**Фикс гонки переподключения.** Симптом: выбрал новую страну, а остался на старой
(старый туннель не успевал погаснуть, новый connect дропался плагином). Введён
`_switchOff()` — ждёт реального `disconnected` (до 4с) перед новым коннектом.
Подключение теперь единообразно из трёх мест: кнопка питания, список локаций,
тайлы «Лучшие серверы».

**Изменённые файлы:** `services/api_client.dart` (`getUsableServers`),
`screens/choose_location_screen.dart` (`LocationSelection`, плитка «Лучший сервер»,
подсветка, фильтр), `screens/home_screen.dart` (`_openLocationPicker`,
`_selectAndConnect`, `_connectCurrentSelection`, `_switchOff`, фильтр),
`l10n/strings.dart` (`bestServerAuto`, `activeBadge`, EN/RU).

**Проверено на реальном телефоне (2026-07-07):** US и прочие недоступные страны
пропали из списка; выбор страны/тайла честно переподключает именно на неё; возврат
к «Лучший сервер» работает.

## Срок триала 2 дня + фикс отображения (2026-07-07)

- **Срок триала: 3 → 2 дня** (`Trial:DurationDays` в `appsettings.json`), задеплоено.
- **Фикс «Истекает через N дней».** `SettingsScreen._expiryLabel` считал `remaining.inDays`
  (округление **вниз**) — свежий N-дневный триал показывал `N-1` (2-дневный → «1 день»,
  3-дневный → «2 дня»), т.к. `expiresAt` = grant + N·24ч, а на момент запроса остаётся
  чуть меньше. Теперь округление к ближайшему дню (`(inHours/24).round()`), свежий
  N-дневный триал корректно показывает `N`.

## Сессии: развязка JWT + access/refresh split (2026-07-08)

Переделана модель сессии — раньше срок JWT был жёстко равен сроку подписки, из-за
чего продление не продлевало уже выданный токен, а истечение выкидывало сразу на
онбординг. Теперь:

**Бэкенд (2 коммита):**
1. **Развязка + живые проверки.** JWT-срок отделён от подписки; право доступа
   проверяется в каждом запросе. `/config` и `/servers` при истёкшей подписке →
   **402** (а не 401), `/me` → `status: expired`. Общий `SubscriptionResolver`.
2. **Access + refresh split.** Короткий access-JWT (**30 мин**) + долгий отзываемый
   **refresh** (90 дней, хранится хешированным, ротируется). Новые `POST /auth/refresh`
   (ротация) и `POST /auth/logout` (отзыв); `/auth/token`, `/trial`,
   `/pair/status` теперь отдают и `refreshToken`. Сущность `RefreshToken` + миграция
   `AddRefreshTokens`. **Проверено локально curl-ом** (выдача, ротация: старый refresh
   → 401; logout → 401; истечение → 402).

**Приложение (1 коммит):**
- `AuthSession`/`TokenStorage` хранят refresh; `ApiClient` прозрачно рефрешит access
  на 401 и повторяет запрос (колбэк `onUnauthorized`, прокинут в Home/ChooseLocation/
  Settings/VpnController); `+refreshSession()`/`+logout()`.
- `AuthController`: гейт `isLoggedIn` vs `subscriptionActive`; refresh на холодном
  старте и на resume; `notifyExpired()` на 402; `signOut()` отзывает refresh.
- `main.dart` — три ветки: онбординг / **экран продления** / Home; refresh на resume
  → продление/истечение подхватываются сами.
- `AwaitingAuthScreen` — режим `renew` («Подписка истекла», без триала,
  «Продлить через Telegram» + «Я продлил — обновить»). HomeScreen на 402 гасит
  туннель и уходит на renew.
- **Настройки:** access 30 мин, refresh 90 дней (`Jwt:AccessTokenLifetime`/
  `Jwt:RefreshTokenLifetime` в `appsettings.json`).

**✅ E2E пройден на эмуляторе (2026-07-08):** login (deep-link) → Home; cold-start →
`/auth/refresh` с ротацией, вход сохранён без re-pairing; истечение подписки → экран
«Подписка истекла»; продление → Home (silent renew, полный цикл); быстрый cold-start.
**Найдены и починены 3 дефекта (коммит `6a4ffc4`):** (1) deep-link/ручной ключ крашились
`unknown-route`-ассертом (Flutter обрабатывал deep link параллельно с app_links) →
`flutter_deeplinking_enabled=false` в манифесте; (2) `exchangeShortToken` залипал на
онбординге при зависшем Keystore (ждал `save()` до `notifyListeners()`) → переход
первым, save best-effort; (3) cold-start блокировал первый кадр на refresh → refresh
в фоне + коалесценция общим Future.

Контракт — см. `docs/api-contract.md` (раздел «Модель токенов»).

## Состояние гита (2026-07-08)

Вся описанная выше работа **закоммичена** в ветку `feat/pairing-onboarding` (рабочее
дерево чистое). Последние коммиты: `532b895` (bff: триал на лету), `4730ad6` (app:
split tunneling + триал/авто-коннект + выбор локации + онбординг + Settings DNS/стек),
`64e1f2e` (docs). Ветка ещё **не смёржена в `master`** и не запушена как финальная —
merge в `master` остаётся в списке ниже.

## Осталось сделать

0. **⚠️ Анти-абуз триала — единственная реально недописанная функциональность (перед
   раздачей тестерам).** Проверено по коду: `token_storage.dart` device-key всё ещё
   случайный `Random.secure()`, а `MainActivity.kt` содержит только channel
   `getLaunchableApps` (для split tunneling) — ANDROID_ID не реализован. Переустановка =
   новый ключ = новый бесплатный триал. См. п.2 ниже и `docs/api-contract.md`.
1. (Опционально) починить сборку `bff` в Docker локально на Windows — либо убрать Windows-специфичный fallback путь из `nuget.config`, либо исключить его через `.dockerignore`/отдельный nuget.config для контейнера.
2. **⚠️ Анти-абуз триала «удалил → скачал заново» (перед стором!).** Сейчас device-key — случайный UUID в secure storage; переустановка = новый ключ = **новый бесплатный триал** (бесконечно). Фикс: стопгап через **ANDROID_ID (SSAID)** как `attestationToken` (переживает переустановку на release-подписи, closes казуальный абуз), а по-настоящему — **Play Integrity / App Attest**. Подробности и планы — `docs/api-contract.md`, «Открытые вопросы».
3. Триал теперь выдаётся **на лету** (см. секцию 2026-07-07) — пул `TrialSubscriptionSlots` больше не нужен (legacy, можно удалить при чистке).
4. iOS-сторона VPN-туннеля — отдельная большая задача (Network Extension, физический iPhone, Apple Developer аккаунт — пока ничего из этого нет).
5. Settings: **DNS-сервер, Network stack и Split tunneling — сделаны и Split tunneling протестирован на реальном телефоне** (см. секции выше). Нюанс:
   - `featureSettings` применяется при `connectManualConfigLink()` — т.е. нужен реконнект (в UI есть подсказка). Возможность "hot-reload" на лету (`restart()`/`applyProfile()`) не проверялась — при необходимости изучить.
6. Перенос на прод: сейчас всё (BFF + бот) работает только на тестовом сервере (87.121.221.229, тестовый бот `@testfatvpnnbot`) — миграция на прод-бот и прод-окружение ещё не сделана, шаги описаны в `docs/bot-integration-spec.md` ("Миграция на прод-бот").
   - **HTTPS + домен — отложено до этого переноса (решение заказчика 2026-07-08).** Тестовый сервер остаётся на HTTP по IP (`http://87.121.221.229:5030`); домен+HTTPS поднимаем сразу на проде. Сервер есть (тот же), домена нет — заказчику надо купить и дать доступ к DNS. На сервере уже подготовлен Caddy (reverse-proxy + Let's Encrypt) — переиспользовать на проде.
7. Google Play Console / Apple Developer аккаунты — ждём данные от заказчика (см. `VPN-App-Project.md`, п.11).
