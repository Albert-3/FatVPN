# ТЗ: VPN-туннель на iOS (sing-box через Network Extension)

> ✅ **Статус: работает на устройстве.** Ветка `feat/ios-vpn-tunnel`.
> Туннель пропускает трафик и split tunneling по доменам/IP подтверждены на
> реальном iPhone (build 16, 2026-07-24). Осталась опциональная довалидация
> (DNS-leak / фон / смена сети) и мерж в `master`.
> - Плагин `singbox_mm` завендорен как локальный path-пакет
>   (`app/packages/singbox_mm/`, было — git-зависимость на чужой форк) — даёт
>   полный контроль над iOS-кодом плагина без форка на GitHub.
> - ✅ Фаза 1 (сборка `Libbox.xcframework`): workflow `ios-libbox-xcframework`
>   собирается на CI за ~3 мин (`Libbox.xcframework.zip`, 260.88МБ). Артефакт
>   пока не скачан/не закоммичен в репо — сделать перед Фазой 3.
> - ✅ Фаза 2 (NE-таргет) — **полностью подтверждено на CI**:
>   `app/ios/tool/add_packet_tunnel_target.rb` добавляет таргет `PacketTunnel`,
>   и `ios-unsigned`, и подписанный `ios-release` собирают + подписывают оба
>   таргета и успешно грузят билд в TestFlight (build 8). Подробности решённых
>   проблем (product name collision, build-cycle, provisioning profiles,
>   host-app NetworkExtension entitlement) — см. память `project_ios_codemagic`.
> - ✅ Фаза 3 (Swift `NEPacketTunnelProvider`) — реализован на Libbox
>   CommandServer + `ExtensionPlatformInterface` (`openTun`, мониторинг сети),
>   sing-box v1.13.11, xcframework закоммичен через Git LFS.
> - ✅ Фаза 4 (method channel) — `SingboxMmPlugin.swift` рулит
>   `NETunnelProviderManager`; `syncRuntimeState`/`getStateDetails`/
>   `requestNotificationPermission` реализованы (исходный `MissingPluginException`
>   устранён).
> - ✅ Фаза 5 (настройки) — DNS/network stack долетают через единый sing-box
>   JSON (`openTun` → `NEPacketTunnelNetworkSettings`). Split tunneling на iOS
>   реализован **по доменам/IP** (per-app VPN невозможен без MDM): пользователь
>   задаёт хосты, которые уходят мимо VPN (`route.rules → outbound: direct`).
>   Подробности — в разделе Фазы 5.
> - ✅ Фаза 6 (Codemagic) — оба таргета подписываются, билды доезжают до
>   TestFlight (сейчас build 16).
> - ✅ Фаза 7 (устройство) — **трафик идёт на реальном iPhone** (build 16,
>   2026-07-24). Ключевой фикс: поиск TUN fd переписан на канонический способ
>   (WireGuard/sing-box: `getsockopt(SYSPROTO_CONTROL, UTUN_OPT_IFNAME)` вместо
>   сломанного на iOS 17 приватного KVC). Split tunneling по доменам/IP тоже
>   подтверждён на устройстве — для доменных правил пришлось включить sniffing
>   (`route.resolveDestination`, build 16), иначе `domain_suffix` не матчился.
>   Осталась опциональная довалидация: DNS-leak / фон / смена сети.

## Зачем

На реальном iPhone (TestFlight-сборка) при попытке подключиться приложение
падает с:
```
MissingPluginException(No implementation found for method syncRuntimeState
on channel singbox_mm/methods)
```
Весь остальной функционал на iOS уже работает (авторизация, список серверов,
настройки, TestFlight-доставка) — не работает только сам VPN-коннект. На
Android туннель полностью реализован и протестирован на устройстве.

## Текущее состояние (проверено в коде)

Плагин `singbox_mm` — git-зависимость приложения
(`app/pubspec.yaml:56-58`, форк `https://github.com/thethtwe-dev/singbox_mm.git`,
запиненный ради x86_64 `libbox.so` для Android-эмулятора).

- **Android** (`android/` в пакете): полная рабочая реализация — своя
  `VpnService` (`SignboxLibboxVpnService.kt`), собранный через gomobile
  `libbox.so` под arm64-v8a/armeabi-v7a/x86/x86_64. Канал `singbox_mm/methods`
  (+ event-каналы `singbox_mm/state`, `singbox_mm/stats`) реализован полностью.
- **iOS** (`ios/Classes/SingboxMmPlugin.swift` в том же пакете) — **заглушка**.
  `startVpn` всегда возвращает ошибку `IOS_EXTENSION_REQUIRED`:
  > "iOS requires a Packet Tunnel Network Extension bound to sing-box core.
  > This plugin cannot launch VPN processes directly on iOS."

  Реализованы: `initialize`, `validateConfig`, `setConfig`, `startVpn`
  (заглушка-ошибка), `stopVpn`, `restartVpn`, `getState`, `getStats`,
  `getLastError`, `getSingboxVersion`, `pingServer`, `requestVpnPermission`
  (хардкод `true`).

  **Не реализованы вообще** (падают в `default: result(FlutterMethodNotImplemented)`,
  отсюда и краш): `syncRuntimeState`, `getStateDetails`,
  `requestNotificationPermission`. Их дергают `home_screen.dart`,
  `settings_screen.dart`, `connection_settings_controller.dart`.
  Нет ни `.xcframework` с sing-box ядром (`ios/Assets/` — пустая папка, только
  `.gitkeep`), ни таргета Network Extension.

- **Xcode-проект приложения** (`app/ios/Runner.xcodeproj`): только два таргета —
  `Runner` и `RunnerTests`. Нет NE-таргета, нет `.entitlements`-файлов, нет
  App Group, нет упоминаний `NetworkExtension`/`PacketTunnel` где-либо в
  `app/ios/`.

**Граница ответственности:** доделать 3 недостающих метода в Swift-плагине —
несложно, но бесполезно само по себе. Реальный туннель — это отдельный
NE-таргет с `NEPacketTunnelProvider`, что Apple **обязательно** требует для
любого VPN-приложения на iOS (не ограничение конкретно этого плагина).

## Целевая архитектура

```
Runner (основное приложение, существующий таргет)
  │  App Group (общий контейнер + Darwin-нотификации)
  ▼
PacketTunnelExtension (НОВЫЙ таргет, NetworkExtension)
  │  линкует Libbox.xcframework (собран из исходников sing-box через gomobile)
  ▼
sing-box core (тот же движок, что и на Android, но iOS-сборка)
```

Приложение (`Runner`) продолжает вызывать те же методы плагина
(`setConfig`/`startVpn`/`stopVpn`/`getState`/...), но на iOS они не запускают
процесс напрямую, а управляют системным `NETunnelProviderManager`, который
поднимает/останавливает расширение.

## План по фазам

### Фаза 0 — Apple Developer (сделать первым, самое дешёвое и может потребовать ожидания)

1. В Apple Developer Portal включить capability **Network Extensions** на
   App ID `com.fatvpn.fatvpnApp`.
2. Создать **App Group** (например `group.com.fatvpn.fatvpnApp`), включить
   на основном App ID и на новом App ID расширения
   (`com.fatvpn.fatvpnApp.PacketTunnel`).
3. Обновить/перекачать provisioning-профили (Codemagic это тоже затронет —
   см. фазу 6).

> Апрув capability иногда не мгновенный — стоит сделать это первым шагом дня,
> чтобы не ждать в конце.

### Фаза 1 — собрать sing-box под iOS

Основа: тот же Go-исходник sing-box, из которого форк `singbox_mm` уже собирает
`libbox.so` под Android через `gomobile`. Для iOS `gomobile bind` умеет
собирать `.xcframework` тем же способом (`gomobile bind -target=ios ...`).

Шаги:
1. Найти, из какого репозитория/версии sing-box собран Android `libbox.so`
   (посмотреть build-скрипты форка `thethtwe-dev/singbox_mm`, если они есть в
   репе, иначе — апстрим `sagernet/sing-box`, пакет `experimental/libbox`).
2. Установить `gomobile`, `gobind`, актуальный Go + Xcode command line tools.
3. `gomobile bind -target=ios -o Libbox.xcframework ./experimental/libbox`
   (точный путь пакета зависит от версии sing-box — проверить по факту).
4. Проверить, что xcframework собрался под `ios-arm64` (реальные устройства) —
   на симуляторе Network Extension всё равно тестировать нельзя полноценно.

Это самая непредсказуемая фаза с точки зрения времени — есть шанс упереться в
версии Go/Xcode или размер бинаря (см. риски).

### Фаза 2 — новый Xcode-таргет

1. В `app/ios/Runner.xcodeproj` добавить таргет **Network Extension**
   (`File → New → Target → Network Extension`), назвать например
   `PacketTunnel`.
2. Bundle ID: `com.fatvpn.fatvpnApp.PacketTunnel`.
3. Добавить `.entitlements` для обоих таргетов (`Runner` и `PacketTunnel`) с
   `com.apple.developer.networking.networkextension` (значение
   `packet-tunnel-provider`) и App Group из фазы 0.
4. Слинковать `Libbox.xcframework` (фаза 1) в `PacketTunnel` таргет.
5. Обновить `Podfile`, если xcframework подключается через CocoaPods
   (`pod 'Libbox', :path => ...` или через `vendored_frameworks`).

### Фаза 3 — Swift-реализация `NEPacketTunnelProvider`

Новый файл в таргете `PacketTunnel`, например `PacketTunnelProvider.swift`:
- `startTunnel(options:completionHandler:)` — прочитать конфиг (из App Group
  shared container, куда `Runner` пишет через `setConfig`), инициализировать
  Libbox, настроить `NEPacketTunnelNetworkSettings` (DNS, маршруты — тут же
  прокинуть текущие split-tunneling настройки из `connection_settings_controller.dart`),
  открыть `packetFlow` и передать пакеты в sing-box.
- `stopTunnel(with:completionHandler:)` — остановить sing-box, освободить
  ресурсы.
- Двусторонний обмен состоянием с основным приложением — либо через App Group
  shared `UserDefaults`/файл + Darwin-нотификации (`CFNotificationCenter`),
  либо через `NETunnelProviderSession.sendProviderMessage`.

Это самая объёмная и рискованная часть — тут же всплывут проблемы с лимитом
памяти (см. риски).

### Фаза 4 — доделать метод-канал плагина (`SingboxMmPlugin.swift`)

Заменить прямой запуск в `startVpn`/`stopVpn` на управление
`NETunnelProviderManager` (`loadAllFromPreferences`, `saveToPreferences`,
`connection.startVPNTunnel()` / `stopVPNTunnel()`), и добавить недостающие
методы в `handle()`:
- `syncRuntimeState` — прочитать актуальное состояние из `NETunnelProviderManager.connection.status`.
- `getStateDetails` — вернуть структуру, аналогичную тому, что уже формирует
  `getState`/`getStats`, но в формате, который ждёт `VpnConnectionSnapshot`
  (см. `lib/singbox_mm_method_channel.dart:145-160` в пакете).
- `requestNotificationPermission` — стандартный `UNUserNotificationCenter` запрос.

### Фаза 5 — прокинуть настройки приложения ✅

**Сделано.** Android- и iOS-пути уже сведены к одному конфиг-формату: Dart
строит единый sing-box JSON (`singbox_config_builder.dart` из
`buildFeatureSettings()`), а iOS-путь передаёт его как есть — плагин кладёт
конфиг в `startVPNTunnel(options: ["configContent": ...])`, расширение отдаёт
его целиком в Libbox CommandServer (`startOrReloadService`). Никакой отдельной
Dart-логики под iOS нет.

- **DNS + network stack**: применяются самим sing-box. Из JSON (`dns`-блок,
  `inbounds[tun].stack`) ядро вычисляет `LibboxTunOptions` и вызывает
  `ExtensionPlatformInterface.openTun`, который переводит их в
  `NEPacketTunnelNetworkSettings` (адреса, маршруты, `NEDNSSettings`, MTU,
  excluded routes). Отдельно прокидывать ничего не нужно — работает через
  общий конфиг. Останется подтвердить на устройстве в Фазе 7.
- **Split tunneling — разные модели под платформу.**
  - **Android** — по приложениям: sing-box `include_package`/`exclude_package`
    (имена Android-пакетов из канала `fatvpn/apps`, который реализует только
    `MainActivity`). Экран `split_tunneling_screen.dart` (список приложений).
  - **iOS** — по хостам: per-app VPN для не-MDM приложений невозможен и sing-box
    эти ключи там игнорирует, поэтому bypass задаётся доменами/IP. Экран
    `split_tunnel_hosts_screen.dart`: пользователь добавляет `example.com`,
    `*.ru`, `10.0.0.0/8` и т.п. `ConnectionSettingsController` классифицирует
    каждую запись (`InternetAddress.tryParse` → CIDR, иначе домен) и кладёт в
    `RouteOptions.regionDirectDomains`/`regionDirectCidrs`, откуда
    `SingboxRouteRulesBuilder` строит правило `{domain_suffix|ip_cidr →
    outbound: direct}`. Это чистая маршрутизация внутри TUN — работает на iOS
    через общий конфиг, без нативного кода.
  - `settings_screen.dart` показывает секцию «Маршрутизация» на обеих
    платформах (`android || iOS`) и ведёт на нужный экран по
    `defaultTargetPlatform`.

### Фаза 6 — Codemagic CI

- `codemagic.yaml` (или workflow настройки, где сейчас настроен
  "iOS release (TestFlight)"): подписывать **два** таргета — `Runner` и
  `PacketTunnel`, оба через App Store Connect API key, как сейчас настроено
  для `Runner`.
- Проверить, что `xcode-project use-profiles` / `automatic code signing`
  подхватывает новый provisioning-профиль расширения.

### Фаза 7 — тестирование на устройстве 🔧 (в работе)

Только реальный iPhone (Network Extension в симуляторе не подключает
настоящий VPN).

**Текущий блокер — трафик не идёт (build 14).** Туннель поднимается
(«connected»), но пакеты не ходили. Причина — `openTun` не мог получить
рабочий TUN fd:
- прежний путь через приватный KVC `packetFlow.value(forKeyPath:
  "socket.fileDescriptor")` на iOS 17.x возвращает `nil` (Apple закрыла
  доступ к внутренностям `NEPacketTunnelFlow`);
- fallback-скан по `AF_SYSTEM + SOCK_DGRAM` (builds 12–13) ловил не тот
  сокет — критерий «семейство+тип» не уникален для utun.

В **build 14** заменено на канонический способ (WireGuard-iOS /
sing-box-for-apple): скан своих fd + `getsockopt(fd, SYSPROTO_CONTROL,
UTUN_OPT_IFNAME)`, берётся дескриптор, чьё имя начинается с `utun`. Только
публичные POSIX, идентификация по самому utun. Вызывается после
`setTunnelNetworkSettings`. **Ждёт проверки на устройстве.**

Если после build 14 трафик всё равно не пойдёт — следующие подозреваемые:
memory jetsam (post-start drops, `LibboxSetMemoryLimit(true)` уже стоит) и
загадка контейнера (`diagnostics.txt` пуст даже при успехе — возможно,
расширение и Runner пишут в разные физические App Group контейнеры).

Проверить после того, как трафик пойдёт:
- Подключение/отключение, смена сервера.
- DNS не течёт (проверить через внешний сервис проверки DNS-leak).
- Поведение при уходе в фон / возврате.
- Разрыв сети / переключение Wi-Fi↔LTE не роняет процесс.
- Split tunneling по доменам/IP: добавить хост (напр. `ifconfig.me` или свой
  IP-диапазон), подключиться, убедиться что трафик к нему идёт мимо VPN
  (внешний IP для этого хоста ≠ IP сервера), а остальной трафик — через VPN.

## Риски

- **Лимит памяти Packet Tunnel Extension.** У Apple он исторически очень
  жёсткий (десятки МБ). Go-рантайм sing-box (GC, горутины) может не влезть без
  тюнинга сборки (`GOGC`, отключение неиспользуемых протоколов при сборке
  xcframework, чтобы уменьшить бинарь).
- **Апрув Network Extension entitlement** от Apple иногда требует обоснования
  использования — не всегда мгновенный self-service (сделать это первым
  шагом, чтобы не блокировать остальное).
- **Опыта Swift/NEPacketTunnelProvider в проекте пока не было** (весь VPN-код
  на Android — Kotlin) — закладывать время на разбор специфики API, если
  разработчик не делал этого раньше.
- **gomobile-сборка под iOS** может потребовать конкретных версий Go/Xcode —
  до реальной попытки сборки неясно, будут ли сюрпризы совместимости.

## Чек-лист готовности

- [x] Network Extension capability включена на App ID, App Group создана
- [x] `Libbox.xcframework` собран под `ios-arm64` и коммитится (Git LFS,
      2 бинарника точечно)
- [x] Таргет `PacketTunnel` добавлен (`add_packet_tunnel_target.rb`),
      entitlements на обоих таргетах верны
- [x] `PacketTunnelProvider.swift` поднимает/останавливает туннель и
      **пропускает трафик на устройстве** (подтверждено, build 16)
- [x] `SingboxMmPlugin.swift`: `syncRuntimeState`, `getStateDetails`,
      `requestNotificationPermission` реализованы, `startVpn`/`stopVpn`
      управляют `NETunnelProviderManager`
- [x] DNS / network stack настройки из приложения долетают до расширения
      через единый sing-box JSON (Фаза 5; device-подтверждение — в Фазе 7)
- [x] Split tunneling на iOS реализован по доменам/IP (per-app невозможен без
      MDM); Android остаётся per-app. Экран `split_tunnel_hosts_screen.dart`,
      маппинг в `route.rules → direct`. **Подтверждён на устройстве** (build 16;
      для доменов включён sniffing `route.resolveDestination`)
- [x] Codemagic собирает и подписывает **оба** таргета, TestFlight-сборка
      устанавливается на реальном iPhone (Фаза 6; build 16 в TestFlight)
- [x] Туннель реально пропускает трафик на iPhone (TUN fd) — подтверждено build 16
- [ ] Опционально: DNS-leak тест, стабильность в фоне и при смене сети

## С чего начать «завтра» (самое дешёвое, чтобы проверить реализуемость)

1. Включить Network Extension capability + App Group в Apple Developer
   Portal (фаза 0) — не блокирует остальную работу, но может потребовать
   ожидания апрува, поэтому первым делом.
2. Параллельно — попытаться собрать `Libbox.xcframework` через `gomobile bind
   -target=ios` (фаза 1) на исходниках sing-box, из которых собран Android
   `libbox.so`. Это самый неопределённый шаг: если сборка не идёт гладко
   (версии Go/Xcode, размер бинаря, отсутствующие C-зависимости) — лучше
   узнать это в первый день, а не после того, как будет готов весь остальной
   Xcode-таргет.
