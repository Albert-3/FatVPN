# ТЗ: VPN-туннель на iOS (sing-box через Network Extension)

> ✅ **Статус: готово, в `master`.** Всё смержено в `master` одним чистым
> squash-коммитом (ветка `feat/ios-vpn-tunnel` удалена). Туннель, split
> tunneling по доменам/IP и довалидация (DNS-leak / фон / смена сети)
> подтверждены на реальном iPhone (build 16–18, 2026-07-24). Последняя сборка,
> **проверенная на устройстве**, — build 18.
>
> **Обновление 2026-08-03.** Сборки с тех пор ушли далеко за 136 — TestFlight
> **186 → 233**, конвейер `ios-release` зелёный (подпись трёх bundle id после
> добавления виджета починена). На устройстве за это время проверялся **не
> туннель**: фикс клоббера сессии (188/189, подтверждён живым пользователем
> 2026-08-01 — первые поведенческие данные на iOS с 2026-07-24) и кнопка виджета
> (207, iPhone 11 / iOS 17.6.1). **Для этого документа это ничего не закрывает:**
> T12–T16 и T23–T25 как не проверялись, так и не проверены, а сборка, поднятая
> на устройстве, проверяла авторизацию и ссылку, а не поведение расширения.
> Виджет живёт в `docs/home-widgets-spec.md`; там же — что App Intent удалён
> 2026-08-03 и нажатие стало ссылкой на всех версиях iOS.
>
> Самая свежая сборка **на момент написания абзаца ниже** — **136** (2026-07-28,
> ремедиация техаудита): зелёная в Codemagic, на устройстве не гонялась. Номер больше не берётся из
> `app/pubspec.yaml`: `ios-release` считает его как `git rev-list --count HEAD` и
> передаёт флагом `--build-number`, так что бампать pubspec руками не нужно —
> оттуда идёт только имя версии (`1.0.4`).
>
> ⚠️ **Оговорка от 2026-07-28.** «Готово» здесь означает «туннель поднимается и
> несёт трафик», а не «туннель корректен». Техаудит 2026-07-27
> (`docs/improvement-plan-ios.md`) нашёл три critical, которые эта довалидация
> пропустить была обязана: blackhole при `serviceStop` (1.1), окно утечки в
> `clearDNSCache` при смене сети (1.2) и полное отсутствие on-demand (1.3).
> Что именно Фаза 7 не покрывала и почему — врезка в конце её раздела.
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
>   Довалидация DNS-leak / фон / смена сети пройдена (build 16–18). **Не
>   проверялись** IPv6-leak, смена сети под нагрузкой, возврат интернета после
>   выключения, кил расширения и чистота диска после logout — см. врезку в конце
>   раздела Фазы 7 и T12–T16 / T23–T25 в `docs/release-test-checklist.md`.

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
- **Split tunneling — две модели, разбивка по платформе.**
  - **По приложениям** (per-app): sing-box `include_package`/`exclude_package`
    (имена Android-пакетов из канала `fatvpn/apps`, только в `MainActivity`).
    **Только Android** — iOS не даёт per-app VPN без MDM.
  - **По хостам** (домены/IP): пользователь добавляет `example.com`, `*.ru`,
    `10.0.0.0/8`; `ConnectionSettingsController` классифицирует каждую запись
    (`InternetAddress.tryParse` → CIDR, иначе домен) и кладёт в
    `RouteOptions.regionDirectDomains`/`regionDirectCidrs`, откуда
    `SingboxRouteRulesBuilder` строит `{domain_suffix|ip_cidr → outbound:
    direct}`. Чистая маршрутизация внутри TUN — **работает на обеих
    платформах** через общий конфиг, без нативного кода. Для доменных правил
    нужен sniffing (`route.resolveDestination`, см. Фазу 7).
  - **UI:** на **iOS** — только хосты (`SplitTunnelHostsScreen`). На
    **Android** — единый экран `SplitTunnelingScreen` с двумя вкладками
    «Приложения» (`AppBypassPicker`) и «Домены/IP» (`HostBypassEditor`) под
    общим переключателем; тела вкладок вынесены в переиспользуемые виджеты.
  - `settings_screen.dart` показывает секцию «Маршрутизация» на `android ||
    iOS` и ведёт на нужный экран по `defaultTargetPlatform`.

### Фаза 6 — Codemagic CI

- `codemagic.yaml` (или workflow настройки, где сейчас настроен
  "iOS release (TestFlight)"): подписывать **два** таргета — `Runner` и
  `PacketTunnel`, оба через App Store Connect API key, как сейчас настроено
  для `Runner`.
- Проверить, что `xcode-project use-profiles` / `automatic code signing`
  подхватывает новый provisioning-профиль расширения.

### Фаза 7 — тестирование на устройстве ✅ (пройдено)

Только реальный iPhone (Network Extension в симуляторе не подключает
настоящий VPN). **Всё проверено на устройстве (build 16–18, 2026-07-24).**

**Ключевой фикс, который разблокировал трафик (build 14→16).** Туннель
поднимался («connected»), но пакеты не ходили — `openTun` не мог получить
рабочий TUN fd. Прежний путь через приватный KVC `packetFlow.value(
forKeyPath: "socket.fileDescriptor")` на iOS 17.x возвращает `nil`, а
fallback-скан по `AF_SYSTEM + SOCK_DGRAM` (builds 12–13) ловил не тот сокет.
Заменено на канонический способ (WireGuard-iOS / sing-box-for-apple): скан
своих fd + `getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME)`, берётся
дескриптор с именем `utun*`. После этого трафик пошёл.

**Результаты довалидации на устройстве:**
- ✅ Трафик идёт, подключение/отключение, смена сервера — работают.
- ✅ **DNS не течёт** — `dnsleaktest.com` показывает только Cloudflare
  (настроенный DNS), реального провайдера в списке нет.
- ✅ **Работа в фоне** — туннель держится при сворачивании/блокировке,
  интернет работает после возврата. (Замирал только UI-таймер сессии — это
  Dart `Timer.periodic`, который iOS приостанавливает в фоне; исправлено в
  `home_screen.dart`: время считается от wall-clock метки старта +
  `WidgetsBindingObserver`, build 18. Общий Flutter-код — чинит и Android.)
- ✅ **Смена сети Wi-Fi↔LTE** — туннель переживает переключение.
- ✅ **Split tunneling по доменам/IP** — хост из списка обхода идёт мимо VPN,
  остальной трафик через туннель. Для доменных правил включён sniffing
  (`route.resolveDestination`, build 16), иначе `domain_suffix` не матчился.

> ⚠️ **Чего эта валидация НЕ проверяла (дописано 2026-07-28 по итогам техаудита).**
> Список выше закрывает вопрос «туннель вообще работает?», но не вопрос «туннель
> работает **правильно**?». Технический аудит 2026-07-27
> (`docs/improvement-plan-ios.md`) нашёл пять находок, каждая из которых **совместима**
> со всеми галочками выше, — то есть Фаза 7 не могла их поймать по построению:
>
> | Не проверялось | Находка | Почему проходило мимо |
> |---|---|---|
> | **IPv6-leak** | 1.7 | Проверялся только DNS (`dnsleaktest.com`). `NEIPv6Settings` объявляет `::/0` без единого IPv6-адреса на интерфейсе — весь IPv6-трафик может идти мимо туннеля, и DNS-тест этого не видит |
> | Смена сети **под нагрузкой** | 1.2 | Проверялось, что туннель «переживает» переключение. `clearDNSCache()` при этом сбрасывает network settings в `nil` и применяет заново — окно в сотни миллисекунд без маршрутов. Вхолостую его не видно, и `dnsleaktest` сразу после коннекта чистый |
> | **Возврат интернета после выключения** тоггла | 1.1 | Проверялось подключение/отключение как смена статуса, а не как «после отключения страницы грузятся». `serviceStop()` закрывает ядро, но не вызывает `cancelTunnelWithError` — маршруты остаются в utun, читать из них некому |
> | Восстановление после **кила расширения** (jetsam) | 1.3, 3.1, 3.2 | Расширение не убивали. On-demand не настроен вообще (grep: 0 совпадений), поэтому iOS не поднимет его обратно — трафик пойдёт открыто |
> | Что **остаётся на диске** после logout | 2.1, 1.6 | Контейнеры не выгружались. `active-config.json`, `start_options.plist` и `Caches/stderr.log` живут открытым текстом и не удаляются при отключении/выходе |
>
> Воспроизводимые проверки под каждый пункт — блок **T-iOS** в
> `docs/release-test-checklist.md` (T12–T16, T23–T25). До их прохождения
> формулировка «Фаза 7 пройдена» означает только «туннель поднимается и несёт
> трафик», и ничего больше.

> Замечание по данным серверов (не баг кода): нода с меткой «FR»
> (`countryCode=France`, адрес `h2-fr.arpozan.cloud`, IP `77.83.246.92`)
> фактически выходит в Польше — особенность VDS у провайдера. Метка в панели
> верная; чтобы получить реально французский выход, нужен другой сервер
> (вопрос к владельцу инфраструктуры, не к приложению/BFF).

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
- [x] DNS-leak тест (только Cloudflare), стабильность в фоне и при смене сети —
      пройдено на устройстве (build 16–18); UI-таймер сессии в фоне починен
      (build 18)
- [ ] ⚠️ **IPv6-leak, смена сети под нагрузкой, возврат интернета после
      выключения, восстановление после кила расширения, чистота диска после
      logout** — **не проверялись** (дописано 2026-07-28). Разбор — врезка в конце
      Фазы 7; сами проверки — T12–T16 и T23–T25 в
      `docs/release-test-checklist.md`
- [x] Переоткрытие приложения при живом туннеле: тоггл больше не застревает на
      «Connecting» (self-heal взводится и из stream-событий, дедлайн 60 c, откат
      в `disconnected` по таймауту), таймер сессии копит общее время до явного
      выключения пользователем (build 24; кроссплатформенный Dart-фикс, детали —
      `docs/app-bff-integration.md`)

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
