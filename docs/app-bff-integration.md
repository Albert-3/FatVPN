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

**Осталось:** привязка при pairing идёт к «последнему ключу» юзера (логика в боте, ещё не реализована — см. `bot-pairing-spec.md`); runtime-прогон стороны бота — после её реализации.

## Осталось сделать

1. (Опционально) починить сборку `bff` в Docker локально на Windows — либо убрать Windows-специфичный fallback путь из `nuget.config`, либо исключить его через `.dockerignore`/отдельный nuget.config для контейнера.
2. Flutter-сторона `/trial`: авто-запрос триала при первой установке (сейчас все 4 экрана всё ещё привязаны только к deep-link токену от бота), плюс реальная верификация устройства (Play Integrity/App Attest) вместо MVP-хеша.
3. Решить, кто и как наполняет пул `TrialSubscriptionSlots` в проде (бот при создании ключей? отдельный скрипт? вручную через `POST /internal/trial-pool`?).
4. iOS-сторона VPN-туннеля — отдельная большая задача (Network Extension, физический iPhone, Apple Developer аккаунт — пока ничего из этого нет).
5. Settings: **DNS-сервер и Network stack — сделаны** (см. секцию «Settings: реальные DNS и Network stack» выше). Осталась только **split tunneling** (по решению заказчика вынесена отдельно):
   - **Split tunneling**: `InboundOptions.includePackages`/`excludePackages` + `splitTunnelingEnabled` — маппится на `route.include_package`/`exclude_package` в sing-box. Нужен способ показать список установленных приложений в `SplitTunnelingScreen` (пакет `singbox_mm` его не даёт — понадобится отдельный пакет вроде `device_apps`/`installed_apps` или platform channel). Android-only, полноценно тестируется лишь на реальном телефоне.
   - Уточнено на практике: `featureSettings` применяется при `connectManualConfigLink()` — т.е. нужен реконнект (в UI есть подсказка). Возможность "hot-reload" на лету (`restart()`/`applyProfile()`) не проверялась — при необходимости изучить.
6. Перенос на прод: сейчас всё (BFF + бот) работает только на тестовом сервере (87.121.221.229, тестовый бот `@testfatvpnnbot`) — миграция на прод-бот и прод-окружение ещё не сделана, шаги описаны в `docs/bot-integration-spec.md` ("Миграция на прод-бот").
7. Google Play Console / Apple Developer аккаунты — ждём данные от заказчика (см. `VPN-App-Project.md`, п.11).
