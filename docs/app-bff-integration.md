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

## Тесты бэкенда + hardening сессий/pairing (2026-07-08)

Появился первый тест-проект `backend/tests/FatVpn.Bff.Tests` (xUnit + EF Core
InMemory + `FakeRemnawaveClient`), добавлен в `FatVpn.Bff.slnx`. **67 тестов, все
зелёные** (`dotnet test tests/FatVpn.Bff.Tests/FatVpn.Bff.Tests.csproj`): auth/refresh,
pairing, trial, разрешение подписки, гейтинг защищённых эндпоинтов.

Написание тестов вскрыло и закрыло ряд edge-case'ов в бэкенде:

- **Refresh reuse detection.** Предъявление уже отозванного (но не истёкшего)
  refresh-токена — признак кражи/replay. Теперь отзывается **вся семья** активных
  refresh-токенов сессии (`AuthController.RevokeFamilyAsync`), а не только сам токен —
  и вор, и владелец идут на повторный pairing. Раньше просто возвращался 401.
- **Single-use pairing-коды.** Новый терминальный статус `PairingStatus.Consumed`.
  `/pair/status` выдаёт сессию один раз, затем гасит код в `Consumed`, чтобы повторный
  поллинг не намолотил вторую сессию (лишние refresh-токены / параллельные логины).
  `/internal/pair/complete` теперь принимает только `Pending`-код (409 иначе, не только
  на `Completed`).
- **`GET /me` → 401 вместо 404**, когда токен валиден, но сессия не резолвится
  (аккаунт/токен-строка удалены) — единообразно с `/servers` и `/config`, приложение
  трактует «сессия исчезла» одинаково и переавторизуется.
- **Пустой subscription id → 401.** У свежесозданной строки `CurrentSubscriptionId`
  дефолтится в `""`; `SubscriptionResolver` теперь мапит пустую строку в `null`, чтобы
  `/config` вернул 401, а не проксировал пустой id в Remnawave.
- **Коллизии pair-кодов → 503.** Генератор `/pair/start` при 5 подряд коллизиях
  (пространство 32^8) отдаёт 503, а не вставляет дубль под unique-индекс.

Контракт обновлён — `docs/api-contract.md` (`/auth/refresh` reuse, `/me` 401).

## Состояние гита (2026-07-08)

Работа по сессиям (access/refresh split, экран продления) закоммичена в ветку
`feat/pairing-onboarding` — последние коммиты `b8d0023`/`052aa37`/`4fb05cc`/`066f480`
(bff+app: развязка JWT, split, refresh, 402), `6a4ffc4` (3 фикса app), `85a079e`/
`dba0e2f` (docs).

**Ещё не закоммичено (рабочее дерево):** тест-проект `backend/tests/` + hardening
сессий/pairing (reuse detection, single-use коды, `/me` 401, пустой sub id, 503 на
коллизии) и правки доков (CLAUDE.md, api-contract.md, эта секция). См. предыдущую
секцию.

Ветка ещё **не смёржена в `master`** и не запушена как финальная — merge в `master`
остаётся в списке ниже.

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

## Локальные уведомления об истечении подписки/триала (2026-07-09)

Добавлены **системные локальные** напоминания на стороне приложения — без сервера,
без FCM/Firebase. Приложение само планирует их из уже известной даты окончания
(`AuthSession.expiresAt`), поэтому изменений в BFF **не потребовалось**.

- **Тайминг:** за 3 дня, за 1 день и **в момент истечения** (планируются только
  моменты в будущем — для 2-дневного триала «за 3 дня» обычно пропускается).
- **Пере-планирование:** при любом изменении сессии (refresh/pairing/trial/logout)
  и языка. Дедуп по `(expiresAt, language)`, чтобы частые `notifyListeners` не
  плодили лишних вызовов. `signOut` → `expiresAt = null` → все напоминания
  отменяются.
- **Тексты:** общие («Подписка скоро закончится» / «Подписка истекла — продлите в
  Telegram»), т.к. сессия несёт только `expiresAt` и не различает триал/платную.
  Локализованы EN/RU.
- **Android-механика:** `inexactAllowWhileIdle` (не требует `SCHEDULE_EXACT_ALARM`);
  переживают перезагрузку через boot-receiver; разрешение `POST_NOTIFICATIONS`
  (Android 13+). Включён core library desugaring — требование плагина.
- **Промо/новости — отложены:** их нельзя вывести локально из подписки, потребуется
  серверная часть (эндпоинт + доставка) — отдельная задача.

**Новый файл:** `app/lib/services/notification_service.dart` (init плагина + tz,
запрос разрешения, `syncFor(expiresAt, strings, language)`).
**Изменены:** `main.dart` (инициализация + подписка на auth/locale), `strings.dart`
(тексты EN/RU), `AndroidManifest.xml` (права + receiver), `build.gradle.kts`
(desugaring), `pubspec.yaml` (`flutter_local_notifications` + `timezone`).

**Проверено на эмуляторе `emulator-5554`:** `flutter analyze` чисто, debug-APK
собран, уведомление **реально доставилось** (подтверждено в `dumpsys notification`:
`id=2099`, канал `subscription_reminders`, сработал `ScheduledNotificationReceiver`).
Временный debug-триггер (авто-тест через 15 c) после проверки удалён.

> Первоначально добавляли `flutter_timezone`, но он ломал сборку (несогласованный
> JVM target плагина). Убрали — не нужен: `zonedSchedule` планирует **абсолютный**
> момент, поэтому дефолтная зона `tz.local` (UTC) даёт правильное время срабатывания.

## Фикс длительности триала в UI + merge в master (2026-07-09)

- Кнопка онбординга писала «3 дня», а `Trial:DurationDays = 2` — тексты EN/RU
  приведены к **2 дням** (`strings.dart`, комментарий в `auth_controller.dart`).
- Ветка `feat/pairing-onboarding` **смёржена в `master`** (fast-forward) и запушена
  (`origin/master`); в неё также вошли рабочее дерево бэкенда (pairing/subscription
  hardening), тест-проект `backend/tests/` и доки. Пункт «merge в master» из списка
  выше **закрыт**.

## Диагностика «в приложении меньше нод, чем в панели» + PoC Hysteria (2026-07-11)

**Симптом:** в панели Remnawave много нод, а в «Выборе локации» — 6 стран (DE, FI, ES, NO, TR, AM).

**Разбор (по живому Remnawave API, `z.fatvdsnvv.space`):** приложение показывает **пересечение**
`/servers` (все ноды `isConnected && !isDisabled`) ∩ `/config` (ноды подписки), матч по адресу
`host == node.address` (`getUsableServers`, `api_client.dart`). Это by design — предлагать ноды не
из подписки бессмысленно (при коннекте «No available node in this subscription»). Причины пропажи:
- **PL, NL** — их vless-хосты **есть** в подписке, но ноды (`pol_take` 87.239.135.53,
  `neth_play2` 31.77.157.229) `isConnected=false` → фильтр `/servers` их убирает. Фикс — поднять ноды (инфра).
- **FR, US, FI-H2** — Hysteria2-ноды (`FAT-France-HY`/`FAT-Usa-HY`/`FAT-Finland-HY`). Всё
  сконфигурировано верно (host включён, inbound активен на онлайн-ноде, в Default-Squad, UUID
  совпадают), но Remnawave **не рендерит Hysteria ни в один формат подписки** (base64/sing-box/clash) —
  они на Xray-hysteria-плагине, генератор их пропускает. Это сторона панели.
- **«Авто» (`web.max.ru`), «Белые списки» (`81.222.127.189`)** — нет ноды в `/api/nodes` → скрыты.

**PoC (реализован):** т.к. правки Remnawave вне нашей зоны, обходим на стороне BFF —
`SubscriptionAugmenter` дописывает синтезированные `hysteria2://`-ссылки в `/config` (auth = `vlessUuid`
из vless-строк подписки; params — из Happ/xray-json рендера). См. `docs/api-contract.md` → `GET /config`.
Задеплоено на прод (ветка прода `feat/pairing-onboarding`: файл взят `git checkout origin/master -- …`,
строка вызова в `ConfigController` добавлена вручную — cherry-pick конфликтовал). Прод `/config` теперь
отдаёт 13 vless + 3 hysteria2. **Осталось:** проверить на устройстве, что sing-box реально поднимает
тоннель к Xray-hysteria-серверу; если да — тянуть хосты из `/api/hosts` вместо хардкода и оформить в код
(коммит `77624b2` на `master`).

## Синхронизация состояния при переоткрытии приложения + таймер сессии (builds 19–24, 2026-07-25)

**Симптом (репорт пользователя, кроссплатформенный):** при включённом VPN пользователь свайпает
приложение из недавних — туннель продолжает работать (живёт в OS-расширении/сервисе, не в процессе
приложения). При повторном открытии **иногда** тоггл застревает на «Connecting» и не подключается —
помогает только закрыть и открыть ещё раз. И если всё же подключается — **таймер сессии начинается
с нуля**.

Билды 19–23 чинили это по частям (синк тоггла с уже запущенным туннелем на старте — build 19;
таймер от wall-clock + восстановление из secure storage через relaunch — builds 20/22; self-heal
поллер — build 23), но фикс был неполным. **Build 24 (commit `dd601cc`) — финальный разбор двух
оставшихся причин, обе на стороне Dart** (`vpn_controller.dart` + `home_screen.dart`), потому
одинаково чинят Android и iOS.

**Причина 1 — застревание на «Connecting».** Живой push из работающего сервиса **есть** (broadcast →
`PluginNetworkEventCoordinator.stateReceiver` → эмит в Flutter-стрим) плюс чтение снапшота с диска на
attach/getState — это гонка, а не отсутствие механизма. Слушатель `stateStream` слепо писал
`_state = state` на каждое событие, но self-heal-поллер `_pollRuntimeStateUntilSettled` взводился
**только** из `syncFromRuntime.getState`. Если после этого стрим приносил устаревший `connecting`
(перезатирая `connected`), поллер уже не перезапускался → вечный спиннер. Плюс дедлайн 20 c и
`catch (_)`, глотавший ошибки.
- **Фикс:** хелпер `_maybeSelfHeal()` взводит поллер **из стрим-событий тоже** (не только из
  `syncFromRuntime`); дедлайн 20→60 c (медленный handshake / ре-handshake после перезапуска сервиса
  ОС); `try/catch` **внутри** цикла (разовая ошибка `getState` не обрывает опрос); по истечении
  дедлайна, если всё ещё транзиент — принудительный откат в `disconnected` (ретрабельное состояние
  вместо вечного спиннера, пользователь просто тапает «Подключить»). Ошибка в `syncFromRuntime`
  теперь логируется, а не глотается.

**Причина 2 — обнуление таймера.** `_trackSessionStart` удалял сохранённый старт сессии
(`_sessionStartedAt` + ключ `vpn_session_started_at` в secure storage) на **любом** `disconnected`,
включая кратковременные разрывы при авто-реконнекте / перезапуске сервиса ОС. Решение пользователя по
поведению: **копить общее время, пока пользователь сам не выключит VPN**.
- **Фикс:** `_trackSessionStart` больше не стирает старт на транзиентных `disconnected` (только ставит
  его при первом `connected`, если пусто). Сброс только через `disconnect({bool endSession = true})`:
  кнопка off и ветка 402 (истёкшая подписка) → `endSession: true`; смена сервера/локации и
  авто-реконнект при смене настроек (`_switchOff`) → `endSession: false`, таймер переживает свап.
  В `_handleVpnChange` убрано обнуление отображаемого значения при транзиентном разрыве (замирает и
  корректно возобновляется из `_tickSession`, без мигания на 00:00:00).

> Нативный `connectedAt` (`PluginStatsTracker.connectedAtMillis`, отдаётся в `getStats().connectedAt`)
> сбрасывается при реальном реконнекте — не подходит под «копить общее время», поэтому здесь не
> используется. Нативный код (Kotlin/Swift) не тронут.

**Изменены:** `app/lib/services/vpn_controller.dart`, `app/lib/screens/home_screen.dart`,
`app/pubspec.yaml` (`1.0.4+24`). `flutter analyze` по всему `lib` — чисто.

**Раскатка:** Android — release-APK build 24 собран локально. iOS — Codemagic workflow `ios-release`
собрал и залил build 24 в TestFlight. ⚠️ **Грабли номера билда:** `flutter build ipa` не задаёт
`--build-number` ⇒ `CFBundleVersion` берётся из `pubspec`; Codemagic собирает **origin/master**, значит
бамп обязан быть **закоммичен и запушен в origin**, и номер должен быть **строго выше последнего
загруженного** в TestFlight, иначе Publishing падает 409 `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE`
(был кейс: origin застрял на 22 при незапушенных 23+24). В `codemagic.yaml` нет `triggering:` ⇒ после
пуша сборку запускать вручную.

## Hysteria2: обе неизвестные закрыты, splicing включён по умолчанию (2026-07-27)

PoC из раздела выше (`SubscriptionAugmenter`) был выключен флагом `Remnawave:AugmentHysteria`, потому
что на устройстве FR/US поднимали туннель, но не несли трафик, а две вещи оставались недоказанными.
Обе проверены против живой панели и реальных нод — **обе гипотезы сняты**, флаг включён по умолчанию.

**1. Пароль действительно равен vless-UUID.** В config-профиле `Hysteria-3` инбаунды идут с пустым
`clients: []` (креды подставляет нода в рантайме), поэтому по профилю проверить было нельзя. Но панель
**рендерит Hysteria в xray-json** (Happ) — только в него, не в base64/sing-box/clash. В этом рендере
есть `streamSettings.hysteriaSettings.auth`, и он байт-в-байт равен vless-UUID того же пользователя —
ровно тому, который мы вынимаем из `vless://`-строк подписки.

```
# подписка в xray-json (Happ UA):
curl -H 'user-agent: Happ/1.9.0' https://sub.fatklyuchi.space/sub/<shortUuid>
```

**2. sing-box совместим с этими инбаундами по проводу.** Локальный sing-box 1.13.14 с **точно тем**
outbound'ом, который строит приложение (`hysteria2`, `tls.alpn=["h3"]`, `domain_strategy=ipv4_only`,
`udp_fragment=true` — дамп даёт `app/test/hysteria_outbound_test.dart`), пронёс реальный трафик через
все три ноды:

| Нода | Exit IP | Гео | 10 МБ |
|---|---|---|---|
| `h1-fi.arpozan.cloud` | 87.251.16.4 | FI | ~1–2 Мбит/с |
| `h2-fr.arpozan.cloud` | 130.49.218.80 | FR | ~17 Мбит/с |
| `h3-us.arpozan.cloud` | 78.153.155.198 | US | ~11 Мбит/с |

Нестандартный блок `finalmask` в Xray-инбаунде оказался **локальным QUIC-тюнингом** (`congestion: bbr`,
размеры receive-window), а не изменением формата — клиентского аналога не требует. `udp_fragment` на
результат не влияет (проверено с ним и без него). uTLS-фингерпринт из рендера панели (`firefox`/`qq`)
к sing-box неприменим: для QUIC-протоколов билдер `utls` намеренно вырезает.

**Проверено также:** libbox собран с `hysteria2` и `quic-go` — и `android/src/main/jniLibs/*/libbox.so`,
и `ios/Frameworks/Libbox.xcframework` (грепом по бинарям); ноды `FAT-Finland-HY`/`FAT-France-HY`/
`FAT-Usa-HY` в `/api/nodes` — `isConnected=true, isDisabled=false`, адреса совпадают с хостами, которые
синтезирует BFF ⇒ пересечение в `getUsableServers` сойдётся и страны появятся в «Выборе локации».

**Вывод по старому симптому.** «Подключено, но нет интернета» — не конфиг и не креды. Наиболее вероятная
причина: сеть оператора резала **UDP/443**, а эти ноды говорят только по QUIC. Приложение поднимает
статус «подключено» по состоянию OS-туннеля независимо от того, дошёл ли sing-box до сервера, поэтому
заблокированный путь выглядит точно как рабочий. Отдельно: FI-нода медленная (~1–2 Мбит/с) — это её
ёмкость, не протокол.

**Изменено:** `RemnawaveOptions.AugmentHysteria` → `true` по умолчанию (+ переписан remarks с
доказательствами), комментарий в `ConfigController`, шапка `SubscriptionAugmenter`, новый
`backend/tests/FatVpn.Bff.Tests/SubscriptionAugmenterTests.cs` (форма ссылок, сохранение исходных строк,
неразрушение непарсибельного входа, отказ без vless-строки). `dotnet test` — **80 passed**.

**Осталось:** задеплоить BFF на прод (там флаг можно и не задавать — дефолт теперь `true`; если в env
контейнера остался `Remnawave__AugmentHysteria=false`, его надо убрать) и проверить на устройстве по
мобильной сети и по Wi-Fi. Хардкод трёх хостов в `SubscriptionAugmenter` оставлен намеренно — тянуть их
из `/api/hosts` значит лишний round-trip на каждый `/config`; вернуться к этому, если хосты начнут меняться.

## Туннель, который «отваливается» после долгой работы (2026-07-27)

**Симптом от заказчика:** «Долго если впн работает включен, в моменте он перестаёт работать, пока его
не выключить и включить».

**Диагноз.** Это тот же класс отказа, что описан абзацем выше, только растянутый во времени: sing-box
держит туннель *поднятым*, но перестаёт нести трафик. Состояние ОС при этом не меняется — tun-девайс на
месте, foreground-сервис жив, `NEVPNStatus` остаётся `.connected` — поэтому ни система, ни приложение
ничего не замечают. До этой правки жив был только один сторож, и он был не в том месте:

* `VpnController._evaluateAutoSwitch` (Dart, раз в 3 минуты) сравнивал **пинги до нод**, а это ничего не
  говорит о самом туннеле: нода, которая отвечает на пинг, но чей туннель мёртв, выглядела здоровой;
* проверка «а идёт ли трафик» (`_verifyTunnelCarriesTraffic`) вызывалась **только сразу после коннекта**;
* и любой Dart-таймер всё равно умирает вместе с Flutter-движком, когда приложение свёрнуто или смахнуто,
  а туннель в это время продолжает жить в сервисе/расширении.

**Что сделано — сторож внутри самого туннеля.** Проба ходит в собственный control-API ядра
(`experimental.clash_api`, порт читается из конфига) и просит sing-box **самого** сходить на
captive-portal-урл через активный outbound. Это принципиально: свои сокеты сервис держит вне tun-девайса,
поэтому запрос «от себя» ушёл бы по underlay и вернулся бы успешным при любом состоянии туннеля. Вердикт
«мёртв» требует провала **обоих** урлов (`gstatic` и `cp.cloudflare.com`) — один заблокированный хост не
должен запускать бесконечный цикл перезапусков.

| | Android | iOS |
|---|---|---|
| Где живёт | `VpnTunnelHealthWatchdog` в `SignboxLibboxVpnService` | `TunnelHealthWatchdog` в `PacketTunnelProvider` |
| Ритм | раз в 60 с (Handler ⇒ считается время бодрствования), первая проверка через 45 с | то же, `DispatchSourceTimer` |
| Внеочередная проверка | смена default-network (`VpnDefaultInterfaceMonitorController`), +8 с на устаканивание | смена underlay (`NWPathMonitor` в `ExtensionPlatformInterface`) **и** `wake()` после сна устройства, тоже +8 с |
| «Сети нет вообще» | `VpnUpstreamNetworkResolver.resolve` | `ExtensionPlatformInterface.hasUsableUpstream` (тот же `NWPathMonitor`) |
| Починка | `scheduleRestart` — тот же stop/start, что у кнопки «Перезапустить» в уведомлении | `reloadService` (= `startOrReloadService`, тот же вызов, что и у старта) |

Пороги одинаковые на обеих платформах (60 с ритм, первая проверка через 45 с, 2 провала подряд ⇒
починка, не чаще раза в 90 с, после 4 безуспешных ритм расширяется до 5 минут, здоровая проба
сбрасывает всё обратно). На Android они вынесены в `VpnTunnelHealthPolicy` — чистый класс без
Android-зависимостей, покрыт 11 тестами (`VpnTunnelHealthPolicyTest`); на iOS та же логика живёт
внутри `TunnelHealthWatchdog` (юнит-тестов нет — Swift на Windows не собрать). Отдельно:
отсутствие upstream вообще (лифт, самолёт) **не** засчитывается туннелю в минус на обеих платформах.

Про iOS-триггер по смене сети стоит отметить: комментарий в `ExtensionPlatformInterface.
reportDefaultInterface` (написан ещё при отладке Фазы 7) описывает ровно этот отказ — «первый
path-update приходит до `openTun`, поэтому свежее соединение выглядит нормально; поломка прилетает на
*следующем* — Wi-Fi/cellular switch, переассоциация с AP, обновление DHCP». Это и есть самый вероятный
триггер жалобы заказчика, и теперь сторож дёргается именно в этот момент, а не через минуту.

⚠️ На Android намеренно **не** используется `VpnServiceReloader` (лёгкий reload ядра): он перечитывает
конфиг сырым файлом, минуя `VpnCoreLifecycleCoordinator.prepareConfig`, и в приложении этот путь никогда
не вызывался. Автоматическая починка на телефоне пользователя — неподходящее место, чтобы стать первым
его вызовом. На iOS такой дилеммы нет: `reloadService` берёт тот же `configContent`, с которым туннель
стартовал.

**Dart-слой (подстраховка, пока приложение живо):** периодический тик переименован в
`_sessionHealthTick` и теперь сначала проверяет, несёт ли туннель трафик, и только потом меряет
альтернативы; мёртвый туннель эскалируется в переключение ноды. Плюс проба запускается на
`syncFromRuntime` — то есть когда пользователь открывает приложение, что чаще всего и есть момент
«почему ничего не грузится».

**Проверено:** `:singbox_mm:testDebugUnitTest` — 11 новых тестов зелёные (падает только
довисевший с master `SingboxMmPluginTest`: `Looper.getMainLooper not mocked`); `flutter analyze` чисто;
`flutter test` — 51 passed, падает только дефолтный `widget_test.dart` (тоже с master);
`flutter build apk --release` собирается (230 МБ, R8 отработал).

**Не проверено:** на устройстве — тестировщики недоступны (Артур и заказчик в Армении). Swift-часть на
Windows не компилируется вообще (нет тулчейна) ⇒ единственная проверка сборки iOS — прогон Codemagic;
новый файл зарегистрирован в `app/ios/tool/add_packet_tunnel_target.rb` (он хардкодит список
`.swift`-файлов таргета, поэтому забыть про него = не собрать расширение). Для заливки в TestFlight
нужен бамп `pubspec.yaml` выше 28 — **закоммиченный и запушенный в origin/master**, см. грабли номера
билда выше.

## Белые списки в split tunneling (Android + iOS, 2026-07-27)

Split tunneling умел только **исключения**: выбранные приложения и домены шли мимо VPN, всё
остальное — через туннель. Добавлен второй режим — **белый список**: через VPN идёт только то,
что перечислено, весь прочий трафик уходит напрямую. Последний пункт из списка заказчика.

**Два режима, два набора списков.** Переключатель `SplitTunnelMode {exclude, include}` живёт в
`ConnectionSettingsController` (ключ `conn_split_mode`), а списки у каждого режима **свои**
(`conn_split_tunnel_packages`/`conn_split_tunnel_hosts` рядом со старыми `conn_split_packages`/
`conn_split_hosts`). Общий список был бы ловушкой: одно нажатие на переключатель молча
инвертировало бы смысл всех сохранённых правил, а посеянные по умолчанию `yandex.ru`/`wildberries.ru`/
`ozon.ru` — домены, которые должны VPN **обходить**, — превратились бы в единственные три сайта,
которым VPN разрешён. UI читает список активного режима через `activePackages`/`activeHosts`,
так что ветвление по режиму не расползается по экранам.

**Приложения (только Android).** Тот же путь, что и раньше, но в `include_package` вместо
`exclude_package`. Здесь была зарыта мина: `VpnPackageAccessController.addAllowedPackage` **молча
выбрасывал** пакет самого приложения — наследие тех времён, когда приложение исключалось из туннеля
целиком. С allow-list это ровно та регрессия, которую чинил `58f16af`: весь трафик приложения
(включая его API-запросы и собственные проверки доступности) ушёл бы мимо туннеля, а любая проба
изнутри рапортовала бы «работает» поверх мёртвого соединения. Решение — `VpnSplitTunnelPackages`
(чистая функция, 6 unit-тестов): пустой список на входе = никакой per-app фильтрации вообще
(«разрешить никому» = туннель, которым не может пользоваться ни одно приложение), непустой —
к выбору пользователя всегда добавляется собственный пакет.

**Домены и IP (обе платформы).** Конфиг sing-box собирается на **Dart-стороне** плагина, поэтому
маршрутизация одинаково работает и на iOS, где per-app невозможен. В `RouteOptions` добавлены
`regionProxyDomains`/`regionProxyCidrs` — зеркало `regionDirect*`. Когда они не пусты:
`route.final` становится `direct`, а перечисленное уходит в туннель отдельными правилами
(`SingboxRouteRulesBuilder`). Флаг **выводится из самих списков**, а не хранится отдельно:
отдельный переключатель допускал бы состояние «белый список включён, но пуст», то есть весь трафик
мимо туннеля при зелёном тумблере в UI. Пустой список просто оставляет полный туннель — а экран
об этом честно предупреждает (`splitTunnelIncludeEmptyNotice`), потому что безопасное поведение тут
противоположно тому, что подразумевает надпись «только эти».

**DNS — самая тонкая часть.** В режиме исключений каждый A-запрос получает fake-IP, и именно это
позволяет доменным правилам срабатывать без снифинга. В белом списке так делать **нельзя**: имена,
которые уходят через `direct`, получили бы адрес `198.18.x.x`, не значащий ничего за пределами
туннеля, — интернет сломался бы целиком в момент сохранения первого правила. Поэтому fake-IP
выдаётся только перечисленным доменам, их AAAA идут в `dns-remote`, а `dns.final` переключается на
`dns-direct`. Bootstrap-домены самого сервера по-прежнему резолвятся первыми и напрямую.

**Изменённые/новые файлы:** `services/connection_settings_controller.dart` (режим + вторые списки +
маппинг), `screens/split_tunnel_hosts_screen.dart` (новый `SplitTunnelModeSelector`, редактор привязан
к активному списку), `screens/split_tunneling_screen.dart` (селектор над вкладками, пикер приложений
на активном списке), `screens/settings_screen.dart` (режим и счётчики в support-бандл), `l10n/strings.dart`
(EN/RU), `packages/singbox_mm/lib/src/models/singbox_feature_settings.dart`,
`.../config/singbox_config_builder.dart`, `.../config/internal/singbox_route_rules_builder.dart`,
`.../config/internal/singbox_dns_builder.dart`, `.../android/.../VpnSplitTunnelPackages.kt` (новый),
`.../VpnTunBuilderConfigurator.kt`, `.../VpnPackageAccessController.kt`, `.../VpnTunSessionManager.kt`.

**Проверено:** `flutter analyze` чисто; `flutter test` — 63 passed (12 новых: 7 на режимы в
`connection_settings_test.dart`, 5 в новом `split_tunnel_whitelist_test.dart`, который прогоняет
настройки до готового конфига sing-box и проверяет `route.final`, правила и DNS в обоих режимах);
`:singbox_mm:testDebugUnitTest` — 6 новых Kotlin-тестов зелёные. Падают только два теста,
довисевшие с master: `widget_test.dart` и `SingboxMmPluginTest` (`Looper.getMainLooper not mocked`) —
проверено отдельным прогоном на чистом HEAD.

**Не проверено:** на устройстве — тестировщиков нет. Белый список по доменам стоит проверять именно
вживую: правильный маршрут и правильный DNS здесь видно только по тому, какой IP отдаёт `2ip.ru`
внутри перечисленного домена и вне его.

## Хосты «Белые списки» / «Авто» из панели (2026-07-27)

Заказчик под «белыми списками» имел в виду **не** сплит-туннелинг (он остаётся как есть, см. секцию
выше), а отдельный хост в панели — `🌍 Белые списки #1`. Он держит связь во время отключений
мобильного интернета: адрес, который он фронтит, лежит в белом списке оператора.

**Проверено по API панели и по кабинету Selectel** (только чтение, `GET /api/hosts`,
`GET /api/config-profiles`):

- хост: `81.222.127.189:443`, path `/api/v1/assets`, SNI/Host `d48e1a7c-…selcdn.net`, ALPN `h2`,
  `securityLayer: TLS` (TLS терминируется на CDN, на инбаунде `security: none`);
- инбаунд (профиль `cf441dfa…`): `network: xhttp`, **`mode: "packet-up"`**, `uplinkHTTPMethod:
  DELETE`, `uplinkDataPlacement: body`, `xmux` (`maxConnections: 1`), padding-обфускация
  (`xPaddingHeader: X-Signature`, `xPaddingKey: _token`, placement `query`);
- CDN-ресурс Selectel `fat.hata-internet.space` → источник `fat.hata-internet.space:443` по HTTPS,
  HTTP/2 и HTTP/3 включены, разрешены методы `POST/PUT/PATCH/DELETE`, ограничений по странам/IP нет,
  тип раздачи «Статика» (режима WebSocket/динамики у Selectel в списке нет).

**Вывод на тот момент: наш клиент к этому хосту подключиться не может.** Официальный sing-box не
реализует XHTTP, а `http`-транспорт, в который плагин ремапит xhttp, умеет только один поток —
разделённый аплинк `DELETE`'ом с padding'ом он не изобразит. Поэтому фильтр `type=xhttp` в
`services/vless_config_parser.dart` тогда оставили: хост, который всегда падает, пингуется нормально
(отвечает CDN) и выглядит как поломка приложения, а не как отсутствующий сервер.
**Это решение отменено — см. следующий раздел.**

**Что в приложении всё-таки изменилось.** Хостам без флага в ремарке (бакет `??`) теперь рисуется 🌍
вместо строки `??`, а заголовок группы берётся из локализации (`whitelistLocations`: EN `Whitelists`,
RU `Белые списки` — так их называет сама панель). Это задел: как только на панели появится рабочий
хост с обходом, он встанет в эту группу сам. Файлы: `utils/country_flag.dart` (`unknownCountryCode`,
`countryLabel`, глобус как фолбэк), `services/api_client.dart`, `screens/choose_location_screen.dart`,
`screens/home_screen.dart` (3 места), `l10n/strings.dart`.

**Рабочий обход, который у нас уже есть.** Хосты `🇪🇺 Авто 🚀 [Hysteria]` и `🇪🇺 Авто 🔥 [GRPC]` оба
указывают на `web.max.ru:8443` (домен мессенджера MAX) на инбаунде `VLESS_GRPC` — тот же трюк с
белым списком, но на gRPC, который sing-box умеет. Флаг 🇪🇺 в ремарке ставит их в группу EU, и они
доступны в приложении уже сейчас. Стоит подтвердить у заказчика, что этот фронт держится при
отключениях.

**Что просить у панели, чтобы «Белые списки» заработали:** поднять на том же CDN-фронте инбаунд
`network: ws` (или `httpupgrade`) с отдельным путём и завести под него хост. Приложение подхватит
его без релиза. Риск: у Selectel нет режима раздачи под WebSocket, CDN может буферизовать поток —
проверяется только опытом.

**Проверено:** `flutter analyze` чисто, `flutter test` — 64 passed (падает только довисевший с master
`widget_test.dart`, проверено на чистом HEAD).

## Второе ядро: Xray рядом с sing-box (2026-07-27)

Просить панель менять транспорт не понадобилось — вместо этого в приложение добавлено **второе
ядро**. Идея: sing-box остаётся хозяином туннеля (TUN, маршрутизация, сплит-туннелинг, DNS), а узлы
на транспорте, которого он не умеет, терминирует Xray и отдаёт их sing-box'у как обычный локальный
SOCKS5. Так «Белые списки #1» и `🇪🇸 Испания xHTTP+Reality` становятся такими же серверами, как все
остальные, без изменений в BFF и в панели.

### Почему одна Go-библиотека, а не две

Готовые сборки libXray взять и положить рядом с libbox **нельзя**:

- на Android оба gomobile-биндинга несут классы `go.Seq`/`go.Universe` под этими же именами — два
  таких jar'а в одном APK конфликтуют на этапе dex, а нативные функции `Java_go_Seq_*` есть в обеих
  `.so`, так что JNI связал бы их с чужим Go-рантаймом;
- на iOS всё жёстче: обе библиотеки — статические Go-архивы, и линковка двух в один `.appex`
  падает на дублирующихся символах рантайма.

Поэтому собирается **один** модуль, который биндит `sing-box/experimental/libbox` вместе с
собственным пакетом-обёрткой над Xray: `app/packages/singbox_mm/tool/fatcore` (`go.mod` +
`fatxray/`). Один рантайм, один `go.Seq`, один артефакт на платформу. Имя библиотеки осталось
`libbox`/`Libbox.xcframework`, поэтому вся существующая обвязка не изменилась.

Сборка: `tool/build_fatcore_android.sh [abi ...]` (заменяет `fetch_singbox_libbox_android.sh`) и
`tool/build_fatcore_ios.sh` (заменяет `fetch_singbox_libbox_ios.sh`, гоняется в Codemagic —
локального Mac нет). API обёртки: `Fatxray.start/stop/isRunning/version/setProtector`.

### Как это работает при подключении

1. Плагин сам решает, какое ядро нужно: `linkNeedsXrayCore(link)` в
   `lib/src/config/xray_config_builder.dart` (`type=xhttp`/`splithttp`). Приложение про движки
   ничего не знает — оно как и раньше зовёт `connectManualConfigLink`.
2. `buildXraySocksBridgeConfig` собирает Xray-конфиг из самой ссылки: socks-инбаунд на
   `127.0.0.1:11080` (**не** 10808 — там дефолтный mixed-инбаунд sing-box) и vless/xhttp-аутбаунд.
   Блок обфускации из параметра `extra` переносится **как есть**: это контракт с инбаундом сервера
   (`uplinkHTTPMethod: DELETE`, данные в body, padding в query), любая «нормализация» здесь ломает
   соединение.
3. Конфиг уходит в нативную часть (`setXrayConfig`) **до** старта туннеля и запускается **внутри**
   VPN-процесса, раньше sing-box.
4. Конфиг sing-box строится из настоящего профиля узла (сплит-туннелинг и DNS должны остаться
   теми же), после чего аутбаунд с тегом узла подменяется на `socks 127.0.0.1:11080`
   (`redirectProxyOutboundToSocks`). Тег сохраняется, поэтому все правила маршрутизации продолжают
   действовать.

**Петля и как она не возникает.** sing-box не добавляет правило обхода для адреса самого узла — ни
на этом пути, ни на обычном; свои сокеты он выводит из туннеля через `VpnService.protect`. Значит и
Xray обязан делать то же: Kotlin отдаёт в ядро `Protector`, который зовёт `service.protect(fd)`
(`VpnXrayEngine.kt`, `VpnServiceControlGraph`). Без этого соединение Xray к узлу попадает в свой же
TUN, sing-box возвращает его на socks-порт — и сессия зацикливается. На iOS этого делать не нужно:
собственный трафик Network Extension и так идёт мимо её туннеля.

**Порядок.** Старт: Xray → sing-box (sing-box дёргает socks-порт с первого же пакета). Стоп: sing-box
→ Xray. На каждом подключении к обычному узлу конфиг Xray **очищается** (`setXrayConfig(null)`),
иначе ядро осталось бы поднятым от прошлой сессии.

**Размер.** Xray добавляет ~18 МБ к `libbox.so` на каждый ABI (arm64: 62 → 80 МБ). 32-битный x86
убран совсем — под него нет ни устройств, ни используемого образа эмулятора. Управляется это тем,
какие ABI лежат в `jniLibs`: `abiFilters` для этого использовать нельзя, он конфликтует с
`--split-per-abi`, которым собираются релизные APK.

**Файлы:** `tool/fatcore/**`, `tool/build_fatcore_{android,ios}.sh`, `codemagic.yaml`,
`android/src/main/jniLibs/*/libbox.so` + `android/libs/libbox.jar` (пересобраны; x86 удалён),
`lib/src/config/xray_config_builder.dart`, `lib/src/core/internal/singbox_mm_client_api_upstream.dart`,
`.../singbox_mm_client_orchestration_manual_connect.dart`, `singbox_mm_platform_interface.dart`,
`singbox_mm_method_channel.dart`, `android/.../VpnXrayEngine.kt` (новый), `VpnCoreServiceFlow.kt`,
`VpnCoreServiceCoordinator.kt`, `VpnServiceControlGraph.kt`, `PluginRuntimeConfigStore.kt`,
`PluginConfigOperations.kt`, `PluginMethodDispatcher.kt`, `PluginFactoryDefaults.kt`,
`PluginMethodHandlersFactory.kt`, `PluginContracts.kt`, `consumer-rules.pro`,
`ios/Classes/SingboxMmPlugin.swift`, `app/ios/PacketTunnel/PacketTunnelProvider.swift`,
`app/lib/services/vless_config_parser.dart`.

### Почему «Белые списки #1» не подключался: `xPaddingBytes` (2026-07-28)

Мост запускался, но хост не отвечал. Диагноз поставлен экспериментом на десктопе: собран тот же
`xray-core` (`v1.260327.1-…50231eaff98c`, тот, что вшит в fatcore), и через него прогнаны два
конфига с одним UUID — рабочий Happ-JSON (панель отдаёт его Happ'у готовым) и наш, собранный
`buildXraySocksBridgeConfig` из vless://-ссылки. Happ-конфиг ходит (выходной IP — узел), наш
получает **`400 Bad Request` на каждый uplink** (`failed to send upload > bad status code:400`).

Разница — в `extra`: ссылка панели обрезана относительно её же Happ-шаблона. Решающее поле —
`xPaddingBytes: "16-64"`: без него Xray паддит своим дефолтом 100–1000 байт, а инбаунд валидирует
токен-паддинг (`_token` в query, `tokenish`) и отвергает запрос. Добавление одного этого поля в
`extra` делает наш конфиг рабочим (проверено там же; остальные отсутствующие поля — `sc*`,
`xmux.h*` — на подключение не влияют, это тюнинг).

Фикс в `xray_config_builder.dart`: если ссылка объявляет `xPaddingObfsMode` без `xPaddingBytes`,
мост подставляет `"16-64"`; ссылка со своим размером остаётся как есть. Тесты: два новых кейса в
`xray_config_builder_test.dart`, пакет — `flutter analyze` чисто, все тесты проходят (флакует только
тайминговый `signbox_vpn_failover_test.dart` под нагрузкой, в изоляции зелёный). Правильное место
фикса вообще-то панель (вписать `xPaddingBytes` в extra-параметры хоста — тогда его получат все
клиенты), но клиентский фолбэк оставлен: он совпадает с шаблоном панели и срабатывает только когда
поле не пришло.

**Проверено на реальном устройстве (Redmi Note 7, Android 10, arm64, 2026-07-28, ~01:15).**
Release-APK, вход по ключу заказчика, сервер «Белые списки»:

- `SignboxLibboxService: Xray core started (26.7.11)` — второе ядро поднимается на живом arm64;
- аутбаунд узла в sing-box действительно подменён на мост: `GET /proxies` через clash API отдаёт
  `🌍 Белые списки #1 -> type=SOCKS`;
- delay-тест через этот аутбаунд — **758 мс**;
- **браузер телефона на `api.ipify.org` показал `87.121.221.178`** — origin-адрес узла. Это и есть
  сквозное доказательство: трафик устройства идёт через XHTTP-мост.

Смотреть внутрь работающего ядра с ноутбука удобно так: `adb forward tcp:16756 tcp:16756`, дальше
обычные запросы к `http://127.0.0.1:16756/proxies`, `/connections`, `/proxies/<tag>/delay` (тег —
это ремарка хоста, её надо url-энкодить вместе с эмодзи).

**Осторожно: сам хост нестабилен, и это не наша сторона.** В ту же ночь он то отдавал
`502 Bad Gateway` на каждый uplink, то работал. Проверено на десктопе тем же ядром: эталонный
Happ-конфиг заказчика — тот, что заведомо рабочий, — падал с 502 наравне с нашим, а через минуту
оба проходили (4 попытки подряд: 2 × 502, затем 2 × успех; ещё через минуту наш конфиг — 6 из 6).
502 приходит от CDN Selectel, то есть он не достучался до origin `fat.hata-internet.space:443`.
**Вывод: жалобу «работал и перестал» по этому хосту нельзя автоматически считать багом приложения
— сначала прогнать эталонный Happ-конфиг через xray-core с десктопа.** Когда origin лежит,
сторож здоровья честно видит мёртвый туннель и перезапускает ядро каждые ~1.5 мин, а приложение
показывает «Сервер не отвечает. Выберите другой.» — это корректное поведение, а не ложная тревога.
Стоит попросить владельца панели разобраться со стабильностью origin за CDN.

### Приложение навсегда зависало на заставке после восстановления бэкапа (2026-07-28)

Найдено при первой же установке на реальный телефон (Redmi Note 7, Android 10, MIUI): APK ставится,
запускается — и остаётся на splash-экране навсегда. В логе:

```
javax.crypto.BadPaddingException: ... BAD_DECRYPT
  at TokenStorage.read (token_storage.dart:77)
  at AuthController.start (auth_controller.dart:122)
```

**Причина.** `flutter_secure_storage` на Android хранит значения в SharedPreferences, зашифрованных
ключом из Keystore. Android Auto Backup (`allowBackup` по умолчанию **true**) выгружает
preferences в облако, а ключ Keystore невыгружаем — он не покидает устройство. При установке
приложения на новый телефон под тем же Google-аккаунтом Android восстанавливает preferences, ключа
к ним нет, и **любое** чтение падает с `BAD_DECRYPT`. `AuthController.start()` ждёт это чтение до
первого кадра, исключение улетало наружу, `_initializing` навсегда оставался `true`, а гейт в
`main.dart:104` по нему показывает заставку. Выхода для пользователя не было — только переустановка
с очисткой данных (а на MIUI и `adb shell pm clear`, и `adb shell input` запрещены без входа в
Mi-аккаунт, так что даже диагностировать это с ноутбука неудобно).

**Починено в трёх местах:**

1. `services/secure_store.dart` (новый) — обёртка `SecureStore` с тем же API, что у
   `FlutterSecureStorage`. Ловит `PlatformException`: на чтении — стирает хранилище (`deleteAll`,
   один раз на инстанс) и возвращает `null`; на записи — стирает и **повторяет запись**, иначе
   только что изменённая настройка молча не сохранилась бы. Терять там нечего: содержимое
   нечитаемо по определению. Подключена во всех четырёх местах, где читалось защищённое хранилище
   (`token_storage`, `connection_settings_controller`, `locale_controller`, `vpn_controller`) —
   вызовы не изменились, поменялся только тип поля.
2. `AndroidManifest.xml` + `res/xml/data_extraction_rules.xml` — `allowBackup="false"` и правила
   извлечения, закрывающие ещё и device-to-device перенос Android 12+ (его `allowBackup` не
   покрывает). Токены сессии и так не то, что стоит копировать на чужой телефон.
3. `AuthController.start()` — тело обёрнуто в `try/catch`: что бы ни сломалось, `_initializing`
   снимается и приложение уходит на онбординг. Уже восстановленная сессия при этом не сбрасывается.

**Тесты:** `test/secure_store_test.dart` — мок метод-канала плагина, который ведёт себя как
устройство после восстановления бэкапа (кидает `BadPaddingException`, пока не позовут `deleteAll`).
Пять кейсов: чтение возвращает `null` и стирает **один раз** на весь холодный старт; после этого
хранилище снова работает; запись на «отравленном» хранилище всё-таки долетает; здоровое хранилище
не трогается; `TokenStorage.read()` отдаёт `null` вместо исключения. `flutter analyze` чисто,
69 из 70 тестов проходят (`widget_test.dart` падал и до правок — проверено на застэшенном дереве).

## Второе ядро на iOS: код готов, не хватает пересобранного фреймворка (2026-07-28)

**Писать код не нужно — он весь есть**, разобран строка за строкой при ревизии 28 июля:

- `app/ios/PacketTunnel/PacketTunnelProvider.swift` — `startXrayIfNeeded` поднимает ядро **до**
  sing-box (тот дёрнет SOCKS-порт с первого пакета), `stopTunnel` гасит его **после** sing-box
  (пока тот доживает, он ещё шлёт трафик в порт), `reloadService` поднимает ядро заново, если оно
  умерло, — иначе sing-box перезагрузился бы на мёртвый SOCKS. Протектор сокетов на iOS не нужен:
  трафик самого Network Extension и так идёт мимо её туннеля;
- `ios/Classes/SingboxMmPlugin.swift` — метод `setXrayConfig` хранит конфиг и кладёт его в
  `startOptions["xrayConfigContent"]` при старте. Смена сервера на iOS идёт через `restartVpn`
  (stop + start), то есть тем же путём, так что отдельной ветки для переключения не требуется;
- Dart-часть общая с Android (`connectViaXrayCore`), решение «нужно ли второе ядро» принимает
  `linkNeedsXrayCore` — платформа про движки ничего не знает;
- `tool/build_fatcore_ios.sh` и воркфлоу `ios-libbox-xcframework` собирают оба ядра в один
  `Libbox.xcframework` (почему именно один — см. раздел про второе ядро выше).

**Чего не хватает:** самого артефакта. `app/packages/singbox_mm/ios/Frameworks/Libbox.xcframework`
в репозитории — сборка от 2026-07-24, только sing-box, без `Fatxray`. Пересобрать его можно лишь
на macOS, локального Mac у проекта нет.

**Как довести до конца:**

1. запустить воркфлоу `ios-libbox-xcframework` в Codemagic (раннер `mac_mini_m2`, ~30–60 мин);
2. скачать `Libbox.xcframework.zip` из артефактов сборки;
3. распаковать поверх `app/packages/singbox_mm/ios/Frameworks/`;
4. закоммитить — бинарники ведёт Git LFS, шаблоны уже прописаны в `.gitattributes`;
5. прогнать `ios-unsigned` (проверка компиляции), затем `ios-release` в TestFlight и проверить
   «Белые списки» на живом iPhone.

**Страховка от тихого провала.** Раньше устаревший фреймворк проявлялся бы как ошибка компиляции
в глубине таргета PacketTunnel (`cannot find 'FatxrayStart' in scope`) — читается как баг в коде, а
не как несвежий бинарник. Теперь есть `tool/check_xray_bridge.sh`: он проверяет, что в заголовках
фреймворка есть `FatxrayStart`, и отдельно ловит неразрешённые LFS-указатели (файл на 130 байт
вместо бинарника). Скрипт вызывается в `ios-release` и `ios-unsigned` сразу после `git lfs pull` и
падает с инструкцией из четырёх шагов. Такая же проверка добавлена в конец
`build_fatcore_ios.sh` — gomobile молча отдаёт фреймворк из одного пакета, если второй не
забиндился, и снаружи такой артефакт не отличить.

## Ключ и аккаунт перестали быть двумя разными входами (2026-07-28)

**Симптом, с которого начали:** «подключение ключа через Telegram работает неправильно».
Вычитка обоих путей входа показала, что их действительно два, и они неравноценны.

- **Pairing** (`/pair/*` → `/internal/pair/complete`) даёт аккаунт-сессию: подписка резолвится
  из `Account` живьём, поэтому продление и смена ключа доезжают до приложения.
- **Вставка «Кода для FatVPN App»** (`/auth/token`) давала token-сессию: подписка бралась из
  строки `Tokens`, которую обновляет **только** `/internal/tokens`. Бот при продлении зовёт
  `/internal/account/subscription` — то есть пишет в `Accounts`. Продлил → приложение
  по-прежнему считает подписку истёкшей, `/config` отвечает 402, а сам ключ на `/auth/token`
  получает 404. Триал устроен так же (`TrialController` создаёт строку `Tokens`), поэтому весь
  первый опыт пользователя жил на этом пути.

**Решение — вставка кода стала таким же явным выбором ключа, как pairing.**

- `Tokens.AccountId` (миграция `LinkTokenToAccount`, накатывается автоматически на старте).
  `/internal/tokens` принимает `telegramUserId` и проставляет владельца; активную подписку
  **не трогает** — показать код это ещё не выбор.
- `/auth/token` для ключа с владельцем записывает его подписку в аккаунт
  (`CurrentSubscriptionId`/`CurrentKeyCode`/`ExpiresAt`) и выдаёт **аккаунт-сессию**. Срок для
  проверки «не истёк» берётся больший из строки ключа и аккаунта, если это один и тот же
  ключ, — иначе продлившему подписку отвечали 404 на его собственный ключ.
- `/internal/account/subscription` получил `makeActive`. Без него вызов применяется, только
  если `subscriptionId` совпадает с активным (или активного ещё нет). У пользователя может
  быть несколько ключей, и продление ключа №2 больше не перетаскивает приложение с ключа №1.
- Ключ без владельца (старая сборка бота, триал) работает ровно как раньше.

**В приложении заодно:**

- 404 на вставленный код больше не показывается как «Не удалось подключиться к серверу» —
  отдельная строка `keyNotFound` (EN/RU).
- Pairing-попытка пишется в secure storage (`pending_pairing`) и восстанавливается на холодном
  старте. Раньше ОС могла убить приложение, пока пользователь в Telegram: бот завершал старый
  код и писал «✅ подключено», а приложение возвращалось, выпускало **новый** код и ждало его
  вечно. Код очищается при завершении, истечении, триале, вставке ключа и выходе.
- Вставка ключа теперь глушит поллинг pairing (раньше таймер продолжал стучать из-за Home).

**Тесты:** бэкенд 106 passed / 7 skipped (Testcontainers без Docker) — новый файл
`AccountKeyBindingTests.cs` (7 тестов) плюс 4 в `AuthControllerTests`. Приложение — 190 passed,
включая три новых в `audit_pairing_poll_test.dart` на переживание перезапуска.

**Сторона бота написана и залита на сервер, но НЕ задеплоена.** Код бота живёт только в
`/opt/FatVPN/bot` (в репозитории его нет). Изменены пять файлов, рядом с каждым лежит
`<файл>.pre-keychoice` — оригинал:

| Файл | Что |
|---|---|
| `api/fatvpn_bff_api.py` | `telegram_user_id` обязателен в `register_short_token`; новый `expire_short_token`; `make_active`/`replaces_subscription_id` в `upsert_subscription` |
| `services/pairing_state.py` | хранилище вариантов выбора; в `callback_data` едет только индекс (лимит Telegram 64 байта, и подделать чужой `short_uuid` нельзя) |
| `main_refactored.py` | `handle_pair` не выбирает ключ молча: один — сразу, несколько — меню, ноль — как раньше. Обработчик `pairsel:` зарегистрирован **до** catch-all роутера (aiogram диспетчеризует в порядке регистрации) |
| `database/db_remnawave.py` | смена ключа и продление-перевыпуском шлют `replaces_subscription_id`; отложенный pair-код разбирается и при продлении |
| `handlers/key_handlers.py` | гашение старого кода при смене ключа; `user_id` в регистрацию кода |

**Найдено при чтении живого бота (в спеке этого не было):** `handle_key_details` вызывал
`upsert_subscription` — то есть **просмотр экрана ключа переключал приложение на этот ключ**.
Полистал свои ключи в боте — приложение уехало на последний просмотренный. Именно из-за этого в
BFF добавились `replacesSubscriptionId` (замена ключа переключает, только если приложение сидело
на заменяемом) и правило «истёкший активный ключ защищать нечего».

Два решения, принятых по ходу и отличающихся от первого наброска ТЗ:
- покупка **второго** ключа больше не переключает приложение (раньше переключала). Переключит,
  если активного ключа нет или он истёк; а покупка «из приложения» доводится отложенным pair-кодом;
- при истёкшем ключе `?start=pair<код>` пишет «подписка истекла» и падает в обычное меню, а не в
  тупик без кнопок.

### Деплой состоялся (2026-07-28), и он вскрыл мину в аудиторской ремедиации

Задеплоено: бот (`fatvpn-bot`), BFF (`fatvpn-bff`, master `43e1a8d`), миграция
`LinkTokenToAccount` применилась на старте. Проверено сквозным прогоном на живом стеке —
см. ниже.

⛔ **BFF отставал на 59 коммитов, то есть этот деплой впервые вынес на прод весь техаудит
(`820b1fe`) — а в нём была ошибка, убивавшая API целиком.** Валидация на request-record'ах
стояла как `[property: StringLength(...)]`, то есть на сгенерированном свойстве. MVC такой
record биндить отказывается (`ModelMetadata.ThrowIfRecordTypeHasValidationOnProperties`) и
кидает исключение **до** входа в экшен. Результат: `/auth/token`, `/auth/refresh`, `/trial`,
`/internal/tokens`, `/internal/pair/complete`, `/internal/account/subscription` и
`/internal/trial-pool/slots` отдавали **500 на любой запрос**. Живые пользователи перестали
рефрешить сессии.

Поймано первым же вызовом после деплоя, починено за минуты (`26dfae4`, `43e1a8d`): у
позиционного параметра record'а атрибут и так адресуется параметру — лишним был префикс
`property:`.

**Почему это не поймали 113 тестов:** все они конструируют record напрямую и через биндинг не
проходят. Добавлен `EveryRequestRecord_KeepsItsValidationOnTheConstructorParameter` — обходит
рефлексией все типы сборки API и падает, если валидация висит на свойстве, которое является
параметром первичного конструктора. Он **сразу нашёл ещё один** пропущенный grep'ом эндпоинт
(`AddTrialSlotsRequest` — там был `MaxLength`, а не `StringLength`).

Урок на будущее: любой код BFF, который «готов, собирается и покрыт тестами», но ни разу не
поднимался на сервере, — непроверен. Ровно та же формулировка уже стоит про iOS-ремедиацию
выше по документу.

**Что понадобилось для деплоя, кроме кода.** Ремедиация добавила `ValidateOnStart`, который
отказывается стартовать без `Trial:DeviceKeySalt` — в `.env` на сервере его не было, контейнер
ушёл бы в crash-loop. Сгенерирован (`openssl rand -hex 32`) и дописан в `.env`.
`docker-compose.yml` на сервере пришлось собрать вручную: у него есть незакоммиченные
прод-правки (Caddy, публичный порт 5030, localhost-бинд Postgres, сеть `fatvpn_default`), а
апстрим в том же файле добавил `Trial__DeviceKeySalt` и `ReverseProxy__KnownNetworks__0`
(без второго все клиенты за Caddy делят один бакет рейт-лимита). Бэкапы:
`/root/env.bak-keychoice`, `/root/compose.bak-keychoice`.

Побочный эффект соли: хеши device-key пересчитались, поэтому устройства, уже потратившие
триал, для сервера теперь новые и могут взять его ещё раз. Разово.

**Сквозная проверка на живом стеке** (реальным модулем бота из его контейнера, синтетический
`telegramUserId`, строки потом удалены) — всё зелёное:

1. регистрация кода с владельцем → `Tokens.AccountId` проставлен;
2. вставка кода в приложении → аккаунт-сессия, `/me` отдаёт именно этот ключ и его `keyCode`;
3. обновление про **другой живой** ключ — приложение не переключилось;
4. замена ключа (`replacesSubscriptionId`) — приложение переехало, **та же сессия продолжила
   работать** без повторного входа;
5. погашенный код → 404.

Плюс снаружи, по публичному адресу: `/health` 200, `/auth/refresh` 401, `/auth/token` 404,
`/pair/start` 200, `/trial` с коротким attestation 400, бот видит BFF, unhandled exceptions — 0.

⚠️ **Правки приложения (Flutter) не задеплоены** — они лежат в рабочем дереве и требуют новой
сборки APK: отдельное сообщение на 404 при вводе ключа и переживание pairing'ом убийства
процесса. На работу задеплоенного сегодня это не влияет.

⚠️ Чек-лист «Доработки 2» руками в Telegram (меню выбора из нескольких ключей, просмотр чужого
ключа, продление) **не прогонялся** — проверено программно, но не глазами в боте.

## «Бот подключил, а приложение нет» — сессия, которую затирал летящий refresh (2026-08-01)

**Жалоба заказчика** (iPhone, TestFlight 1.0.4 (186), сразу после конца триала): выбираю ключ
через Telegram — бот пишет «✅ подключено», в приложении по-прежнему «подписка истекла»; тот
же ключ, скопированный и вставленный руками, работает сразу.

Первая версия диагноза («шёл в бота напрямую, pairing не запускался, поэтому токенная
триальная сессия и не могла ничего узнать») **оказалась неверной** — и это стоит запомнить:
слова пользователя о том, *что* он нажимал, разошлись с тем, что видел сервер.

**Что было на самом деле — по данным прода.** `PairingCodes`: два кода 2026-07-31 в 20:26:52 и
20:27:14 доведены до `Consumed` (2), то есть приложение **получило сессию оба раза**.
`RefreshTokens`: обе аккаунт-сессии брошены — ни одного продления после выдачи, — а в те же
секунды продолжала ротироваться старая триальная цепочка. В 20:27:52 пользователь вставил ключ
руками; эта сессия жива.

**Корень.** `AuthController._doRefresh` применял ответ `/auth/refresh` безусловно. Экран
«подписка истекла» рефрешит просроченную триальную сессию (кнопка «проверить снова», возврат
в приложение). Если ответ прилетал **после** того, как `/pair/status` уже поставил новую
платную сессию, ротация старой затирала её и в памяти, и на диске: приложение снова видело
«истекла», гейт возвращал на экран продления, тот выпускал новый pair-код. В проде это
случилось дважды подряд — отсюда и «бот подключил, а приложение нет». Бот не врал.

**Фикс** (`fa9bc8f`): результат refresh применяется, только если сессия, с которой он начался,
всё ещё текущая — проверка до записи на диск, после неё (с восстановлением диска, если замена
случилась прямо во время записи) и в ветке ошибок, где поздний 401 мёртвой сессии мог
разлогинить новую.

**Зеркальная гонка** (`4d3530b`), найдена при вычитке того же места: `/pair/status` со статусом
`completed` тоже применялся безусловно, поэтому опрос, оставшийся в полёте, мог затереть
сессию от **вставленного ключа** (и заодно стереть `keyCode`, оставив Settings без активного
ключа). Экран продления держит кнопку Telegram и поле ключа рядом, так что это одно движение
руки, — и прод остановился в шаге от этого: код `SVPP92D7` (20:27:36) всё ещё опрашивался,
когда через 16 секунд вставили ключ. Заодно: сессия, выпущенная и не пригодившаяся, теперь
возвращается через `/auth/logout` (best-effort) — pairing-сессия иначе держит один из трёх
слотов устройств ключа все 90 дней.

Тесты: `app/test/refresh_race_session_clobber_test.dart` — три сценария (клоббер после
pairing, поздний 401, зеркальный случай). Весь набор: 250 тестов, `flutter analyze` чист.

⚠️ **На устройстве не проверено.** Обе правки — Dart под хостовыми тестами. Раскатано:
TestFlight **188** (только первая правка) и **189** (обе), Android APK пересобран локально.
Приёмка: триал истёк → «Подключить через Telegram» → выбрать ключ в боте → вернуться в
приложение; сессия должна пережить возврат. Вторая половина: начать pairing, не доводить его,
вставить ключ — приложение должно остаться на вставленном ключе, даже если бот потом завершит
код.
