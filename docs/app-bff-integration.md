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

## Осталось сделать

1. (Опционально) починить сборку `bff` в Docker локально на Windows — либо убрать Windows-специфичный fallback путь из `nuget.config`, либо исключить его через `.dockerignore`/отдельный nuget.config для контейнера.
