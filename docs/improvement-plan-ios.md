# План доработок — iOS (Runner + PacketTunnel NE + sing-box/libbox)

> **Назначение документа:** техзадание для исполнителя (Claude Opus). Аудит проведён
> 2026-07-27 по коду `master`. Охват: `app/ios/**`,
> `app/packages/singbox_mm/ios/Classes/SingboxMmPlugin.swift`, Dart-слой метод-каналов,
> `codemagic.yaml`, `app/ios/tool/add_packet_tunnel_target.rb`.
>
> Смежные документы: `docs/improvement-plan-bff.md`, `docs/improvement-plan-app-android.md`.

**Общая оценка:** архитектура выбрана канонически верно (NEPacketTunnelProvider +
Libbox CommandServer + `getsockopt(UTUN_OPT_IFNAME)` для TUN fd — так же делают
WireGuard-iOS и sing-box-for-apple), код хорошо прокомментирован. Но есть несколько
путей, где **туннель превращается в «чёрную дыру» при живом `NEVPNStatus.connected`**,
есть **окна утечки трафика мимо туннеля**, **полностью отсутствует on-demand/kill-switch**,
и **конфиг с креденшелами лежит открытым текстом сразу в трёх местах**.

## Статус на 2026-07-28

Сверено **по диффу** рабочего дерева ветки `fix/bff-audit-remediation`, а не по списку
задач. Влито в `master` fast-forward'ом (`011894a`) и запушено.

✅ **Codemagic `ios-release` прошёл зелёным — сборка 136 (2026-07-28).** Это снимает
главную оговорку документа: Swift **компилируется**. Заодно прошли два новых шага —
гейт `flutter analyze && flutter test` в обоих пакетах и проверка
`codesign -d --entitlements` по экспортированному `.ipa`, то есть **у App ID Runner'а
и расширения capability App Groups есть, и entitlement переживает пере-подпись**. Риск
из находок **1.9** и **2.5** («entitlement молча вырежут, `containerURL()` вернёт nil,
вся диагностика мертва») закрыт не рассуждением, а проверкой.

⚠️ **Что зелёная сборка НЕ доказывает — а это почти всё.** Компилятор не проверяет ни
одного утверждения этого документа: blackhole при `serviceStop`, окно утечки в
`clearDNSCache`, таймауты `runBlocking`, гонки на `tunnelOptions`, поведение
on-demand/kill-switch, IPv6-блокировку, `system`-стек, MTU 1280, счётчики трафика — всё
это компилируется одинаково хорошо и в правильном, и в сломанном виде. Статус
Swift-находок поднялся с «написано» до «написано и собирается», не выше.

⚠️ **На устройстве по-прежнему не проверено ничего.** Приёмка — блок **T-iOS** раздела
2a в `docs/release-test-checklist.md`: T12–T16, T23–T25 (находки аудита) и T26–T36
(изменения поведения, найденные вычиткой). Начинать разумно с **T15** и **T14** —
именно blackhole-баги прошлая валидация пропустила.

**Измерено (2026-07-28, после вычитки):** `flutter analyze` чист и в `app/`, и в
`app/packages/singbox_mm/`. Тесты: **`app/` — 175 прошло, 1 пропущен**;
**`app/packages/singbox_mm/` — 204 прошло**. Под iOS-часть аудита добавлено шесть файлов
(`app/test/ios_audit_*.dart`, `app/packages/singbox_mm/test/ios_audit_*.dart`), включая
`ios_audit_ipv6_leak_test.dart` — до вычитки находка **1.7 не была покрыта ничем**.

⚠️ **Из ~100 тестов в `ios_audit_*` дискриминирующих примерно 55.** Остальные пиннят
поведение, которое существовало **до** ремедиации, то есть на откате правки не покраснеют.
Целиком в этой категории — `ios_audit_memory_profile_test.dart` и группа §2.2 в
`clash_api_secret_test.dart`: логика `cache_file`/`store_fakeip` и посвежий секрет на каждый
старт были в `master` ещё до этих работ. Это не делает их бесполезными (они держат
контракт), но считать их «пинами ремедиации» нельзя — см. «Что осталось открытым».

**Легенда статусов** (её же читать в сводной таблице):

| Метка | Что значит |
|---|---|
| 🟡 **код (Swift)** | правка **компилируется** (сборка 136 зелёная); поведение на устройстве не проверялось |
| 🟡 **код (Dart)** | правка в общем Dart-коде; `flutter analyze` чист, есть хост-тесты; поведение за platform channel всё равно не проверено |
| ✅ **CI** | правка в `codemagic.yaml`; **прогон состоялся, шаг отработал** |
| 🟡 **частично** | сделана часть; что именно осталось — в тексте находки |
| ⬜ **не сделано** | — |

### Что важно знать до чтения таблицы

1. **Три Dart-правки намеренно платформенные, а не общие.** TUN-стек `system` (3.2),
   MTU 1280 (3.4) и IPv6-адрес интерфейса (1.7) включены **только на iOS**
   (`defaultTargetPlatform == TargetPlatform.iOS`, `singbox_feature_settings.dart:24-63`).
   Файл общий с Android, а released-сборка Android device-тестирована именно на
   gvisor/1100/IPv4-only — менять её тем же диффом значило бы обесценить её проверку.
   Перенос на Android — отдельная задача со своим прогоном.
2. **Аудит ошибся в четырёх местах.** Тексты находок **1.7**, **1.14**, **2.4** и **4.1/4.4**
   исправлены по факту, а не просто помечены. Сводка — раздел «Где ошибся сам аудит».
3. **Номера строк в аудите местами разошлись с рабочим деревом** — он писался по `master`
   2026-07-27, а Android-доработки успели переписать часть общего Dart-кода. Пример:
   `_waitForDisconnected` с окном 4 с (упоминается в 1.10) сейчас — публичный
   `waitForDisconnected` с окном 10 с (`vpn_controller.dart:950`). Ссылки в тексте
   находок оставлены как в аудите, чтобы номера находок оставались стабильными; сверяться
   надо по имени символа, а не по строке.

## Сводная таблица

| # | Файл:строка | Проблема | Крит. | Статус |
|---|---|---|---|---|
| 1.1 | `ExtensionPlatformInterface.swift:361-363` | `serviceStop` не отменяет туннель → blackhole при «connected» | **critical** | 🟡 код (Swift) |
| 1.2 | `ExtensionPlatformInterface.swift:180-188` | `clearDNSCache` снимает маршруты → утечка при смене сети; ошибки глотаются; `reasserting` залипает | **critical** | 🟡 код (Swift) |
| 1.3 | `SingboxMmPlugin.swift:598-608` | Нет on-demand / kill-switch: после jetsam-кила VPN не поднимается | **critical** | 🟡 код (Swift + Dart + UI) |
| 1.4 | `PacketTunnelProvider.swift:41-50` | `runBlocking` без таймаута → зависание `openTun`/`serviceReload` | high | 🟡 код (Swift) |
| 1.5 | `PacketTunnelProvider.swift:55,70,143,220,251` | Гонка данных на `tunnelOptions` из 3+ потоков | high | 🟡 код (Swift) |
| 1.6 | `PacketTunnelProvider.swift:199-208,228-235` | Персист конфига не чистится → подъём на устаревшем сервере | high | 🟡 код (Swift + Dart) |
| 1.7 | `ExtensionPlatformInterface.swift:64-72,83-91` | Default-маршрут IPv6 без адресов → утечка IPv6 | high | 🟡 код (Swift + Dart), **текст находки исправлен** |
| 1.8 | `ExtensionPlatformInterface.swift:51-53` | DNS через `try?` + нет `matchDomains` → DNS-утечка | high | 🟡 код (Swift) |
| 1.9 | `PacketTunnelProvider.swift:85-92` | `fatalError` в расширении → крэш-луп | high | 🟡 код (Swift) |
| 1.10 | `SingboxMmPlugin.swift:489-517` | Гонка teardown (0.6 с) + «отравление» `vpnManager` invalid-объектом | medium | 🟡 код (Swift) |
| 1.11 | `SingboxMmPlugin.swift:269-316` | Гонка на `payload` + утечка `NWConnection` в ветке `.failed` | medium | 🟡 код (Swift) |
| 1.12 | `SingboxMmPlugin.swift:59-60,811-834` | Статистика трафика всегда 0, таймер 1 Гц вхолостую | medium | 🟡 код (Swift) |
| 1.13 | `PacketTunnelProvider.swift:369-385` | `sleep` без парного `wake` → пауза навсегда; watchdog «лечит» паузу | medium | 🟡 код (Swift) |
| 1.14 | `ExtensionPlatformInterface.swift:146-161` | Скан fd 0…1024, берётся первый `utun*` | low | 🟡 частично — **вторая половина невыполнима, текст исправлен** |
| 1.15 | `PacketTunnelProvider.swift:237-263` | Невалидируемая plist-ветка `handleAppMessage` (мёртвый код) | low | 🟡 код (Swift) |
| 2.1 | `PacketTunnelProvider.swift:187-190`, `SingboxMmPlugin.swift:386` | Креденшелы открытым текстом, попадают в бэкап, не удаляются | **high** | 🟡 частично — файловый вариант сделан, **Keychain нет** |
| 2.2 | `singbox_config_builder.dart:129-134` | Clash API без `secret` на общем loopback:16756 | **high** | 🟡 частично — секрет есть, **порт фиксированный** |
| 2.3 | `TunnelHealthWatchdog.swift:329-354` | `external_controller` не валидируется → исходящий HTTP из NE | medium | 🟡 код (Swift) |
| 2.4 | `PacketTunnelProvider.swift:109-131`, `vpn_controller.dart:861-862` | Конфиг/домены утекают в UI-ошибку и support bundle | medium | 🟡 код (Swift); Dart-половина была закрыта **раньше** |
| 2.5 | `add_packet_tunnel_target.rb:47-52` vs `Runner.entitlements:9-12` | Комментарий противоречит entitlements (риск дрейфа профиля) | low | 🟡 код + CI |
| 3.1 | `PacketTunnelProvider.swift:124-129` | `Data(contentsOf:)` на неограниченном `stderr.log` → jetsam при ошибке | **high** | 🟡 код (Swift) |
| 3.2 | `singbox_inbound_builder.dart:68-75` | Стек всегда gvisor (настройка `system` не работает) → память/CPU | **high** | 🟡 код (Dart), **только iOS** |
| 3.3 | `singbox_config_builder.dart:122-127`, `PacketTunnelProvider.swift:149` | `cache_file` вкл. по умолчанию, `logMaxLines=3000` | medium | 🟡 код (Swift + Dart) |
| 3.4 | `singbox_inbound_builder.dart:32` | MTU 1100 захардкожен → −20% throughput | medium | 🟡 код (Dart), **только iOS** |
| 3.5 | `TunnelHealthWatchdog.swift:40`, `vpn_controller.dart:83` | Два health-контура, 60 с в фоне 24/7 → батарея | medium | 🟡 код (Swift + Dart) |
| 3.6 | `TunnelHealthWatchdog.swift:49,57` | 105 с до первого восстановления | low | 🟡 код (Swift) |
| 3.7 | `TunnelHealthWatchdog.swift:97-102` | `URLSession` без `urlCache = nil` в 50 МБ процессе | low | 🟡 код (Swift) |
| 4.1 | `codemagic.yaml:39-41,48,87-89,101` | `flutter: stable`, `xcode: latest`, gem без версии | medium | 🟡 частично — Flutter и gem закреплены, **Xcode сознательно нет** |
| 4.2 | `codemagic.yaml:37-70` | Нет `flutter analyze`/`test` перед публикацией в TestFlight | medium | 🟡 CI |
| 4.3 | `codemagic.yaml:50-57,103-110` | Отладочный `-showBuildSettings` в релизном пайплайне | low | 🟡 CI |
| 4.4 | `codemagic.yaml:26,84` | `max_build_duration: 60` при 260 МБ LFS | low | ⚠️ **находка была неверна** — уже закрыта до аудита; поднят третий воркфлоу |

---

## 1. БАГИ

### 🔴 1.1 `serviceStop()` останавливает ядро, но не туннель — полная потеря связи при «connected» — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `app/ios/PacketTunnel/ExtensionPlatformInterface.swift:361-363`

```swift
func serviceStop() throws {
    tunnel?.stopService()
}
```

`stopService()` (`PacketTunnelProvider.swift:214-217`) закрывает sing-box и сбрасывает
platform interface, но **не вызывает `cancelTunnelWithError(nil)`**. При этом
`NEPacketTunnelNetworkSettings` остаются применёнными: default route по-прежнему
указывает в utun, а читать из него уже некому.

**Почему плохо:** у пользователя пропадает интернет целиком (не «VPN отвалился», а
«сети нет»), при этом iOS и приложение показывают `connected`, таймер сессии тикает.
Health-watchdog не спасает: `recover()` идёт через `reloadService()` →
`commandServer?.startOrReloadService`, а `commandServer` жив, но сервис закрыт —
состояние неопределённое. Выйти можно только ручным тоглом.

**Фикс:** завершать сессию по-настоящему:

```swift
func serviceStop() throws {
    tunnel?.stopService()
    tunnel?.cancelTunnelWithError(nil)   // iOS корректно переведёт в .disconnected
}
```

Аналогично: сделать `stopService()` приватным для пути `stopTunnel`, а для внешних
запросов — отдельный `shutdownTunnel()`.

> **Сделано по второму, более аккуратному варианту.** Пути разведены: остановка «изнутри»
> (`serviceStop` из Go-рантайма и внешняя команда) теперь идёт через
> `shutdownTunnel()`, который **и** закрывает sing-box, **и** вызывает
> `cancelTunnelWithError(nil)` (`PacketTunnelProvider.swift:555`); путь самого
> `stopTunnel(with:)` этого не делает — там сессию уже отменяет система, и повторный
> `cancelTunnelWithError` оставил бы пользователя без корректного статуса
> (комментарий на `PacketTunnelProvider.swift:177`).
> **Проверяется T15** — «после выключения тоггла страницы открываются сразу».
> Пока Swift не собран и на устройстве не прогнан, находка **не закрыта**.

### 🔴 1.2 Окно утечки трафика в `clearDNSCache()` — срабатывает ровно при смене сети — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `app/ios/PacketTunnel/ExtensionPlatformInterface.swift:180-188`

```swift
tunnel.setTunnelNetworkSettings(nil) { _ in
    tunnel.setTunnelNetworkSettings(networkSettings) { _ in
        tunnel.reasserting = false
    }
}
```

Три проблемы в восьми строках:
1. **Утечка.** Между `setTunnelNetworkSettings(nil)` и повторным применением у туннеля
   нет маршрутов. Всё, что уходит в этот момент (сотни миллисекунд и больше на слабом
   устройстве), идёт мимо VPN по физическому интерфейсу — в открытую, с реальным IP и
   провайдерским DNS. sing-box дёргает `clearDNSCache()` именно на сетевых событиях:
   Wi-Fi↔LTE, ре-ассоциация AP, DHCP renew — самый частый сценарий.
2. **Ошибки проглатываются** (`{ _ in }` дважды). Если повторное применение упало,
   туннель остаётся **вообще без network settings** — полный blackhole при `connected`.
3. **`reasserting` залипает в `true`**, если внешний коллбэк не пришёл → приложение
   навсегда в «connecting» (`SingboxMmPlugin.swift:661` мапит `.reasserting` → `connecting`).

**Фикс:** не сбрасывать настройки в nil — для сброса DNS-кеша достаточно пере-применить
те же настройки одним вызовом (iOS сам переустановит резолверы), с обработкой ошибки:

```swift
func clearDNSCache() {
    guard let networkSettings, let tunnel else { return }
    tunnel.reasserting = true
    tunnel.setTunnelNetworkSettings(networkSettings) { error in
        tunnel.reasserting = false
        if let error { Self.log("clearDNSCache reapply failed: \(error)") }
    }
}
```

> **Сделано ровно так, все три пункта.** `setTunnelNetworkSettings(nil)` убран — настройки
> применяются одним вызовом; `reasserting` снимается **всегда**, в том числе на ошибке
> (иначе приложение остаётся в «Подключение» навсегда); ошибка повторного применения
> пишется в лог строкой `clearDNSCache re-apply failed:` — именно её и надо искать в
> Console.app при прогоне **T14**.
> ⚠️ Само окно утечки руками не измерить, поэтому критерий приёмки в T14 сформулирован
> **по логу**: пары «сброс в `nil` → применение» быть не должно.

### 🔴 1.3 Не настроены on-demand правила: нет ни автоподъёма, ни kill-switch — 🟡 Исправлено в коде (Swift + Dart + UI)
**Где:** `app/packages/singbox_mm/ios/Classes/SingboxMmPlugin.swift:598-608` (`configure(_:)`)

`manager.isOnDemandEnabled` и `manager.onDemandRules` не задаются нигде (grep по репо:
0 совпадений). `includeAllNetworks()` в расширении жёстко `false`
(`ExtensionPlatformInterface.swift:299-301`).

**Почему плохо:**
- Если расширение убито jetsam'ом (превышение ~50 МБ — см. 3.1, 3.2) или крэшнулось,
  iOS **не перезапустит его**. Пользователь остаётся без VPN, трафик идёт открыто.
  Приложение узнает об этом только когда его откроют.
- Нет kill-switch: между падением туннеля и ручным переподключением трафик течёт напрямую.
- После перезагрузки устройства туннель не поднимается сам, хотя `start_options.plist`
  для этого уже персистится (`PacketTunnelProvider.swift:187-190`) — механика есть,
  триггера нет.

**Фикс:** после `configure(_:)` (под пользовательским переключателем
«Автоподключение / Kill switch»):

```swift
manager.isOnDemandEnabled = enableOnDemand
let rule = NEOnDemandRuleConnect()
rule.interfaceTypeMatch = .any
manager.onDemandRules = [rule]
```

Для kill-switch вернуть `true` из `includeAllNetworks()` (или пробросить настройкой).
⚠️ При `includeAllNetworks = true` нужно аккуратно исключить loopback, иначе Clash API
из `TunnelHealthWatchdog` перестанет отвечать.

> **Сделано, и это самая объёмная правка документа — она прошла через все четыре слоя.**
> - **Настройки:** два новых переключателя в `ConnectionSettingsController` —
>   `autoReconnect` и `killSwitch` (`connection_settings_controller.dart:45-46,126-132,340-350`),
>   оба по умолчанию **выключены** и оба персистятся; строки EN/RU
>   («Переподключаться автоматически» / «Блокировать трафик без VPN»,
>   `app/lib/l10n/strings.dart`), UI — в `settings_screen.dart`.
> - **Dart→платформа:** новый метод `setTunnelPreferences({onDemandEnabled, killSwitchEnabled})`
>   в platform interface и method channel; `VpnController._connect` вызывает его **до**
>   старта туннеля (`vpn_controller.dart:686-693`) — именно тогда платформа пишет их в
>   VPN-профиль.
> - **Swift:** `manager.isOnDemandEnabled` + `NEOnDemandRuleConnect` с
>   `interfaceTypeMatch = .any` (`SingboxMmPlugin.swift:848-852`),
>   `proto.includeAllNetworks = killSwitchEnabled` (`:833`).
> - **Расширение:** `includeAllNetworks()` больше не константа `false`, а читает флаг из
>   start options (`ExtensionPlatformInterface.swift:386-387` ←
>   `PacketTunnelProvider.includeAllNetworksRequested:150-151` ← `SingboxMmPlugin.swift:634`).
>
> ⚠️ **Оговорка аудита про loopback осталась непроверенной.** `includeAllNetworks = true`
> может отрезать Clash API у `TunnelHealthWatchdog` — то есть включённый kill-switch
> способен «убить» собственный health-контур расширения. Проверять **обязательно** и
> **вместе**: включить kill-switch и убедиться, что watchdog продолжает получать ответы
> (T23).
>
> 🆕 **Побочная находка, которой в аудите не было — см. N1 в конце документа:** on-demand
> пришлось **снимать перед** `stopVPNTunnel()` (`SingboxMmPlugin.swift:693-694`), иначе
> правило немедленно поднимает туннель обратно и кнопка «Отключить» перестаёт работать
> вовсе. Аудит этого шага не предусматривал.

### 🟠 1.4 `runBlocking` без таймаута → детерминированное зависание старта — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `app/ios/PacketTunnel/PacketTunnelProvider.swift:41-50` (`semaphore.wait()` без
таймаута). Используется в `ExtensionPlatformInterface.swift:106-114` (`setTunnelNetworkSettings`
внутри `openTun`), `:345-358` (`serviceReload`), `:373-385` (`setSystemProxyEnabled`);
плюс отдельный блокирующий `wait()` в `startDefaultInterfaceMonitor` (`:195-210`).

**Почему плохо:** `openTun` вызывается из Go-рантайма синхронно. Если
`setTunnelNetworkSettings` не вызовет коллбэк (конфликт с другим NE-профилем, гонка с
`clearDNSCache`, отозванный профиль), поток Go блокируется навсегда → `completionHandler`
у `startTunnel` не вызывается → NE-фреймворк убивает расширение по своему таймауту,
а пользователь видит зависший «Connecting» до 60-секундного дедлайна
(`vpn_controller.dart:258`). Дополнительно `serviceReload` (`:344-358`) — потенциальный
реентрантный дедлок: Go-поток блокируется в `runBlocking`, а `Task.detached` внутри
вызывает `reloadService()`, который может ждать тот же заблокированный Go-поток.

**Фикс:** добавить таймаут (15 с) с `throw TunnelStartupError` при истечении; плюс
общий таймаут на весь `startTunnel0` (~30 с) с явным `completionHandler(error)`.

> **Сделано, оба уровня.** `runBlocking(timeout: TimeInterval = 15, …)`
> (`PacketTunnelProvider.swift:103-121`) бросает `TunnelStartupError` вместо вечного
> ожидания, плюс общий дедлайн на весь старт — `startupDeadline = 40 с` (`:158`,
> взведён на `:235`), после которого `completionHandler` получает явную ошибку. 40, а не
> 30: нижний предел определяется 15-секундным `runBlocking` внутри `openTun`, и 30 с
> оставляли слишком мало запаса на всё остальное.

### 🟠 1.5 Гонка данных на `tunnelOptions` — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `PacketTunnelProvider.swift:55` (объявление), запись — `:143` (`startTunnel0`,
`Task`) и `:251` (`handleAppMessage`, другой `Task`); чтение — `:70` (замыкание watchdog'а
на очереди `fatvpn.packet-tunnel.health`) и `:220` (`reloadService()`, вызывается и из
watchdog'а, и из `serviceReload()` на Go-потоке). Синхронизации нет.

**Почему плохо:** Swift-словарь не потокобезопасен → конкурентная запись/чтение даёт
повреждение памяти и крэш расширения (а крэш = потеря VPN без автоподъёма, см. 1.3).

**Фикс:** выделенная серийная очередь (или actor) для доступа к `tunnelOptions`:

```swift
private let stateQueue = DispatchQueue(label: "fatvpn.packet-tunnel.state")
private var _tunnelOptions: [String: NSObject]?
private var tunnelOptions: [String: NSObject]? {
    get { stateQueue.sync { _tunnelOptions } }
    set { stateQueue.sync { _tunnelOptions = newValue } }
}
```

> **Сделано ровно так** (`PacketTunnelProvider.swift:128-138`). Та же серийная очередь
> `fatvpn.packet-tunnel.state` заодно закрыла второе разделяемое поле — флаг паузы ядра
> `corePaused` из находки **1.13** (`:134,143-145`), который иначе пишется из `sleep()`
> и читается из watchdog'а на другом потоке.

### 🟠 1.6 `stopTunnel` не чистит персистентный снапшот → подключение к устаревшему серверу — 🟡 Исправлено в коде (Swift + Dart)
**Где:** `PacketTunnelProvider.swift:228-235` (нет удаления `start_options.plist`) +
`:199-208` (`resolveStartOptions` откатывается на персист).

**Почему плохо:** если iOS поднимет расширение без options (перезапуск после jetsam,
будущий on-demand, восстановление сессии), оно возьмёт **любой** ранее сохранённый
конфиг. Сценарии: пользователь разлогинился, подписка истекла, сменил сервер, нода
удалена — а туннель поднимется на старом сервере со старыми креденшелами. Плюс
`try? persistStartOptions(...)` на `:142` молча глотает ошибку записи → снапшот может
«застрять» на позапрошлом конфиге.

**Фикс:** удалять файл в `stopTunnel(with:)` при `reason ==
.userInitiated / .configurationRemoved / .userLogout` и по команде логаута через
`handleAppMessage`; добавить в снапшот версию/TTL и отклонять протухший.

> **Сделаны все три пункта, плюс четвёртый.**
> 1. `stopTunnel(with:)` чистит снапшот на `.userInitiated`, `.userLogout`, `.userSwitch`,
>    `.configurationRemoved`, `.configurationDisabled`, `.authenticationCanceled`
>    (`PacketTunnelProvider.swift:576-590`) — список шире предложенного аудитом, потому что
>    «пользователь ушёл» выражается в NE несколькими причинами сразу.
> 2. Снапшот получил версию и метку времени (`snapshotVersionKey`/`snapshotSavedAtKey`,
>    `:479-491`), `resolveStartOptions` отклоняет протухший.
> 3. `try? persistStartOptions(...)` больше не глотает ошибку — провал записи логируется
>    (`:488-490`): молча застрявший на позапрошлом конфиге снапшот хуже отсутствующего.
> 4. **Сверху:** путь логаута из приложения. Новый канал
>    `clearPersistedState` (`SingboxMmPlugin.swift:189-190,529`) и Dart-обёртка
>    `VpnController.forgetPersistedTunnelState()` (`vpn_controller.dart:1064-1090`),
>    вызываемая из `disconnect(endSession: true)`; она сносит `start_options.plist`,
>    `active-config.json`, `diagnostics.txt`, `stderr.log` и локальный секрет Clash API.
>    Это же закрывает файловую половину **2.1**.
>
> **Проверяется T16** (поднялся ли туннель после ребута — и не на устаревшем ли конфиге)
> и **T24** (что осталось на диске после logout).

### 🟠 1.7 `NEIPv6Settings` с default-маршрутом без адресов → утечка IPv6 — 🟡 Исправлено в коде; ⚠️ **предложенный аудитом фикс утечку не закрывал**
**Где:** `ExtensionPlatformInterface.swift:64-72` и `:83-91`

Конфиг по умолчанию идёт с `ipv6RouteMode = disable`
(`singbox_feature_settings.dart:152`) и `domain_strategy = ipv4_only`
(`singbox_config_builder.dart:67-69`), то есть sing-box вернёт пустой список
inet6-адресов. Тогда мы объявляем `::/0` без единого IPv6-адреса на интерфейсе.

**Почему плохо:** поведение недокументировано — iOS либо отвергает весь объект настроек
(тогда `openTun` падает), либо игнорирует IPv6-часть, и **весь IPv6-трафик идёт мимо
туннеля** на IPv6-enabled операторах. Это утечка реального адреса, которую тест
`dnsleaktest.com` из Фазы 7 спеки **не поймает** (он проверяет только DNS).

**Фикс, предложенный аудитом:**

```swift
settings.ipv6Settings = ipv6Addresses.isEmpty ? nil : ipv6Settings
settings.ipv4Settings = ipv4Addresses.isEmpty ? nil : ipv4Settings
```

> ❌ **Этот фикс утечку не закрывает — диагноз верен, лечение нет.** Он делает поведение
> iOS **определённым** (перестаём объявлять `::/0` без адреса, `openTun` больше не
> рискует упасть на отвергнутом объекте настроек) — и на этом всё. При `ipv6Settings = nil`
> iOS просто **не заводит IPv6 в туннель**, и весь v6-трафик по-прежнему уходит мимо, с
> реальным адресом пользователя. Утечка остаётся ровно той же, только теперь она
> документирована.
>
> **Настоящая причина в другом файле.** Правило `::/0 → block` в конфиге **уже
> существует** (`singbox_route_rules_builder.dart:44-49`, ветка
> `ipv6RouteMode == disable`) — но правило может подействовать только на пакет, который
> **дошёл до ядра**, а iOS не маршрутизирует в интерфейс семейство, адреса которого у
> этого интерфейса нет. То есть блокирующее правило было написано и никогда не
> исполнялось.
>
> **Сделано и то, и другое:**
> 1. nil-ветка из рецепта аудита (определённое поведение, `openTun` не падает);
> 2. **главное** — у TUN появился inet6-адрес: `defaultTunInet6Address`
>    (`singbox_feature_settings.dart:27-48`), `fdfe:dcba:9876::1/126` — документированный
>    TUN-дефолт sing-box из unique-local диапазона, подставляется в
>    `singbox_inbound_builder.dart:24-33`. Теперь `::/0` встаёт **перед** блокирующим
>    правилом, и v6-трафик доходит до ядра, чтобы быть заблокированным.
>
> ⚠️ **Только iOS.** Android остаётся IPv4-only: дыра там та же, но файл общий, а
> released-сборка Android device-тестирована именно в текущем виде — это отдельная
> задача со своим прогоном.
>
> **Проверяется T12.** Ожидаемое новое поведение — `test-ipv6.com` показывает
> **«нет IPv6»**, а не адрес выходной ноды: мы v6 блокируем, а не проксируем. Появление
> реального адреса оператора = находка не закрыта.
>
> Проверка `test-ipv6.com` в `docs/release-test-checklist.md` добавлена (T12).

### 🟠 1.8 DNS применяется «по возможности» и без `matchDomains` — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `ExtensionPlatformInterface.swift:51-53`

```swift
if let dnsServer = try? options.getDNSServerAddress() {
    settings.dnsSettings = NEDNSSettings(servers: [dnsServer.value])
}
```

1. `try?` молча глотает ошибку: если sing-box не отдал адрес DNS, `dnsSettings`
   остаётся `nil` → система использует резолверы физического интерфейса. DNS-утечка
   без лога и без ошибки.
2. Не выставлен `matchDomains = [""]` — канонический паттерн (WireGuard-iOS,
   sing-box-for-apple), который принуждает iOS слать *все* запросы в DNS туннеля.
   Без него часть системных резолверов (mDNS/Bonjour, «умные» пути iOS 17+) может
   обойти туннельный DNS.

**Фикс:** заменить `try?` на `do/catch` с `throw TunnelStartupError`, добавить
`dns.matchDomains = [""]`.

> **Сделано ровно так, оба пункта** (`ExtensionPlatformInterface.swift:60-73`): отсутствие
> адреса DNS теперь `throw TunnelStartupError` — туннель не поднимется молча без
> резолверов, — и выставлен `dnsSettings.matchDomains = [""]` (`:73`).
> **Проверяется T13**, причём именно прогонами «после смены сети» и «после возврата из
> фона»: одноразовый тест сразу после коннекта эту находку проходил и при живом баге.

### 🟠 1.9 `fatalError` в расширении при недоступности App Group — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `PacketTunnelProvider.swift:85-92`. Комментарий утверждает, что это build-time
баг, но контейнер бывает недоступен и в рантайме: дрейф provisioning-профиля (см. 2.5),
перевыпуск профиля, повреждённый контейнер.

**Почему плохо:** `fatalError` внутри NE = крэш-луп. iOS применяет к падающим
расширениям экспоненциальный backoff и в итоге перестаёт их запускать — VPN не
поднимется вообще, и диагностику записать некуда (писалка сама живёт в App Group).
Пользователь получает «Connecting» → таймаут без единой подсказки.

**Фикс:** fallback на `temporaryDirectory` для `basePath`/`workingPath` + нормальный
error-путь через `startTunnel`, чтобы туннель хотя бы поднялся.

> **Сделано ровно так.** `fatalError` убран: `sharedDirectory` откатывается на
> `FileManager.default.temporaryDirectory` (`PacketTunnelProvider.swift:210-213`), а
> недоступность App Group фиксируется отдельным флагом (`:220`) и строкой
> `APP_GROUP_UNAVAILABLE: <id> (diagnostics are local to this process)` в диагностике
> (`:272`) — то есть туннель поднимается, а приложение получает внятную причину, почему
> оно не видит логов расширения.
> **Первым это, скорее всего, поймает не устройство, а CI:** новый шаг
> `codesign -d --entitlements` в `codemagic.yaml` падает, если у App ID Runner'а нет
> capability App Groups (см. **2.5**).

### 🟡 1.10 `stopVpn`/`restartVpn`: гонка с `.disconnecting` и «отравление» `vpnManager` — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `SingboxMmPlugin.swift:489-517`

1. **Гонка teardown'а.** `stopVPNTunnel()` асинхронен, а `completion()` вызывается сразу;
   магические `asyncAfter(0.6)` — не гарантия (остановка sing-box на нагруженном
   соединении занимает больше). `startVPNTunnel` в состоянии `.disconnecting`
   игнорируется → смена сервера молча не срабатывает. В Dart это компенсируется
   костылём `_waitForDisconnected` на 4 с (`vpn_controller.dart:832-839`).
2. **`loadOrCreateManager` может вернуть фабрикованный `NETunnelProviderManager()`**
   (`:594`), который тут же уходит в `attachManager`. Его `connection.status` навсегда
   `.invalid` → `handleStatusChange` пишет `disconnected` (`:665-669`), и `resolveState`
   (`:531-536`) отвечает из этого «отравленного» кеша, **игнорируя реально работающий
   туннель**. Это ровно тот сценарий, от которого предостерегает комментарий к
   `loadExistingManager` (`:610-614`).

**Фикс:** в `stopTunnel` использовать `loadExistingManager` (нечего останавливать, если
менеджера нет), а завершение ждать по `NEVPNStatusDidChange` до `.disconnected`/`.invalid`
с таймаутом ~10 с вместо `asyncAfter(0.6)`.

> **Сделано ровно так, обе половины.** `stopTunnel` перешёл на `loadExistingManager`
> (`SingboxMmPlugin.swift:678-683`) — фабрикованный менеджер с вечным `.invalid` больше
> не попадает в `attachManager` и не «отравляет» `resolveState`; `asyncAfter(0.6)` заменён
> на `awaitDisconnected(_:completion:)` (`:701-715`), который ждёт `.disconnected`/`.invalid`
> с таймаутом. `restartVpn` благодаря этому запускает новый туннель только когда старый
> действительно ушёл из `.disconnecting` — состояния, из которого `startVPNTunnel` молча
> ничего не делает, и в котором смена сервера иногда просто не срабатывала.
> ⚠️ **Костыль на Dart-стороне снимать не стали:** `VpnController.waitForDisconnected()`
> (окно 10 с, `vpn_controller.dart:950`) закрывает Android и служит вторым рубежом на iOS.

### 🟡 1.11 `pingServer`: гонка данных на `payload` + утечка `NWConnection` — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `SingboxMmPlugin.swift:269-316`

`payload` пишется из `stateUpdateHandler` (очередь `singbox_mm.ping`) и одновременно из
глобальной очереди по таймауту — гонка на Swift-словаре. В ветке `.failed` нет
`connection.cancel()` → `NWConnection` живёт до `deinit`; при переборе всех нод в
`_pickBestNode` (`vpn_controller.dart:841-852`) это десятки подвисших соединений на
каждый цикл автопереключения.

**Фикс:** в расширении та же функция написана **правильно**
(`PacketTunnelProvider.swift:318-363`: единая серийная очередь, флаг `settled`,
`cancel()` в `settle`) — перенести эту реализацию сюда.

> **Сделано ровно так, как советовал аудит** — правильная реализация из расширения
> перенесена в плагин: единая серийная очередь, флаг `settled` без блокировок, потому что
> и обновления состояния, и таймаут живут на ней, и `connection.cancel()` во **всех**
> ветках, включая `.failed` (`SingboxMmPlugin.swift:341-367`). Десятки подвисших
> `NWConnection` на каждый цикл `_pickBestNode` больше не копятся.

### 🟡 1.12 Статистика трафика на iOS всегда нулевая, но таймер тикает каждую секунду — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `SingboxMmPlugin.swift:59-60, 811-824, 826-834`

`uplinkBytes`/`downlinkBytes` нигде не инкрементируются — только обнуляются в
`handleStatusChange` (`:668-669`). На iOS счётчик трафика в UI всегда 0, при этом канал
`singbox_mm/stats` гоняет событие каждую секунду, вечно, даже когда экран статистики
закрыт (`onListen` вызывается один раз, таймер не гасится в фоне).

**Фикс:** тянуть реальные цифры из Clash API расширения через `sendProviderMessage`
(команда `"stats"` рядом с `"measureLatency"`, `PacketTunnelProvider.swift:265-276`) —
sing-box отдаёт их на `/traffic` и `/connections`. Интервал поднять до 2–3 с, таймер
глушить по `applicationDidEnterBackground`.

> **Сделаны все три пункта.** Цифры тянутся из расширения командой `"stats"` через
> `sendProviderMessage` (`SingboxMmPlugin.swift:1147`, ответ разбирается на `:1167-1169`);
> `statsInterval = 3.0 с` (`:29`); таймер гасится по `didEnterBackgroundNotification` и
> поднимается по `willEnterForegroundNotification` (`:137-146`), а также по
> `onCancel` стрима (`:59`) — то есть закрытый экран статистики больше не оплачивается
> каждую секунду.
> ⚠️ **Проверять обязательно:** до этой правки счётчики были **структурно** нулевыми
> (поля просто никогда не инкрементировались), так что «на экране появились числа» —
> это новое поведение целиком, а не восстановленное.

### 🟡 1.13 `sleep()` может оставить ядро в паузе навсегда — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `PacketTunnelProvider.swift:369-372, 380-385`

`wake()` — best-effort со стороны системы, парность `sleep`/`wake` не гарантирована
(особенно если между ними расширение выгружалось из памяти). Если `wake()` не пришёл,
sing-box остаётся на паузе → туннель есть, трафика нет. Плюс watchdog в этот момент
**не остановлен**: получит таймаут → `.dead`, накрутит `consecutiveFailures` и через
2 неудачи запустит `attemptRecovery()` — перестроит ядро вместо того, чтобы просто
его разбудить.

**Фикс:** флаг `isPaused` в `sleep()`, в `runProbe` возвращать `.unknown` пока флаг
стоит, снимать в `wake()`; если после `checkSoon()` ядро всё ещё на паузе — повторный
`commandServer?.wake()`.

> **Сделано, и на один шаг дальше рецепта.** Флаг называется `corePaused`, живёт на той же
> серийной очереди, что и `tunnelOptions` из **1.5** (`PacketTunnelProvider.swift:134,143-145`),
> прокинут в watchdog замыканием `isCorePaused` (`:182`) — на паузе проба возвращает
> «неизвестно», а не «мёртв», и накрутить `consecutiveFailures` до перестройки ядра больше
> нельзя.
> **Сверх рецепта:** восстановление привязано не к `checkSoon()`, а к смене сетевого пути —
> `underlayDidChange()` (`:758-772`): сетевая активность при «ядро на паузе» означает, что
> обещанный `wake()` не пришёл (система обещает его только best-effort, а выгруженное из
> памяти расширение не услышит его вовсе), и тогда `wake()` вызывается принудительно.
> Это надёжнее, потому что не требует, чтобы watchdog вообще успел проснуться.

### 🟢 1.14 Скан fd 0…1024 и выбор первого `utun*` — 🟡 Частично: первая половина сделана, ⚠️ **вторая невыполнима**
**Где:** `ExtensionPlatformInterface.swift:146-161`. Метод канонический, но диапазон
захардкожен вместо `getdtablesize()`, и возвращается первый `utun*` без проверки, что
имя совпадает с только что созданным интерфейсом. **Фикс:** `getdtablesize()` + сверять
ожидаемое имя интерфейса, а не только префикс.

> ✅ **Первая половина сделана:** диапазон сканирования — `max(getdtablesize(), 1024)`
> (`ExtensionPlatformInterface.swift:198`), захардкоженного потолка больше нет.
>
> ❌ **Вторая половина рецепта невыполнима в принципе, и это ошибка аудита.** «Сверять
> ожидаемое имя интерфейса» предполагает, что мы это имя знаем — а `NEPacketTunnelProvider`
> его не сообщает: имя созданного `utunN` можно узнать **только** из уже открытого fd, тем
> самым `getsockopt(UTUN_OPT_IFNAME)`, ради которого весь скан и делается. Требование
> ссылается на данные, которых на этом шаге ещё не существует.
>
> **Сделано вместо этого** (`ExtensionPlatformInterface.swift:176-227`): диапазон
> `getdtablesize()`, а неоднозначность (найдено больше одного `utun*`) пишется в лог,
> чтобы у следующего разбирающегося был след.
>
> ⚠️ **Исправление текста (вычитка 2026-07-28).** Здесь раньше было написано «берётся
> **последний**, а не первый — самый свежий принадлежит только что созданной сессии».
> Это неверно и кодом не реализовано: в коде `matches.first`, и так сделано осознанно.
> Номер дескриптора **ничего не говорит о возрасте интерфейса** — ядро выдаёт наименьший
> свободный, поэтому переиспользованный низкий номер вполне может принадлежать самому
> новому utun. «Последний» был бы не более правильным выбором, чем «первый», зато отличался
> бы от того, на чём прогонялось device-тестирование build 18. Выбор оставлен прежним
> сознательно; на практике у packet-tunnel-провайдера открыт ровно один дескриптор
> (libbox закрывает предыдущий utun до повторного `openTun`, а закрытый не проходит
> `getsockopt`).

### 🟢 1.15 `handleAppMessage` не проверяет тип сообщения — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `PacketTunnelProvider.swift:237-263`. Не-JSON сообщение трактуется как plist со
start-options и **немедленно перезапускает сервис с новым конфигом**, без валидации.
Dart-слой этим путём не пользуется — мёртвый, но исполняемый код. **Фикс:** удалить
plist-ветку или обернуть в явную команду `{"command":"reload",...}` с проверкой через
`LibboxCheckConfig`.

> **Сделано по первому варианту — plist-ветка удалена.** `handleAppMessage`
> (`PacketTunnelProvider.swift:606`) принимает **только** JSON-конверт с полем `"command"`;
> всё остальное отвергается. Мёртвый код с живой дырой («пришли расширению произвольный
> plist — оно перезапустит ядро на твоём конфиге») закрыт целиком, а не обёрнут.

---

## 2. БЕЗОПАСНОСТЬ

### 🟠 2.1 Креденшелы открытым текстом в трёх местах, переживают logout — 🟡 Частично: файловый вариант сделан, **Keychain нет**

| Место | Файл:строка | Что лежит |
|---|---|---|
| App Group контейнер | `PacketTunnelProvider.swift:12, 187-190` | `start_options.plist` — binary plist с полным `configContent` |
| Application Support | `SingboxMmPlugin.swift:356, 386` | `active-config.json` — тот же конфиг в открытом JSON |
| App Group `Caches` | `PacketTunnelProvider.swift:158` | `stderr.log` — вывод sing-box |

В `configContent` — UUID VLESS/VMess, пароли Trojan/Shadowsocks/Hysteria2/TUIC,
приватные ключи WireGuard, Reality public/short-id, адреса нод. Ни один файл не
создаётся с явным `NSFileProtection`, не помечен `isExcludedFromBackup` и **ни один не
удаляется при отключении/логауте** (см. также 1.6).

**Почему плохо:** содержимое App Group и Application Support попадает в незашифрованный
Finder-бэкап и в iCloud Backup. Компрометация бэкапа = компрометация всех подписочных
креденшелов. Класс защиты по умолчанию не спасает от бэкап-эксфильтрации.

**Фикс:**
1. Хранить `configContent` в Keychain с `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   и `kSecAttrAccessGroup` = App Group (расширение читает оттуда), а не в plist/json.
2. Если файл всё же нужен — писать с
   `options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]` и
   `URLResourceValues.isExcludedFromBackup = true`.
3. Удалять все три артефакта в `disconnect(endSession: true)` и при логауте.

> **Сделаны пункты 2 и 3, пункт 1 — нет.**
>
> **Пункт 2 (защита файлов).** Все три артефакта пишутся с
> `options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]`
> (`PacketTunnelProvider.swift:282,486`, `SingboxMmPlugin.swift:472`) и помечаются
> `isExcludedFromBackup = true` (`PacketTunnelProvider.swift:311`,
> `SingboxMmPlugin.swift:1039`) — то есть уходят из незашифрованного Finder- и
> iCloud-бэкапа, а до первой разблокировки устройства нечитаемы.
>
> **Пункт 3 (удаление).** Новый канал `clearPersistedState`
> (`SingboxMmPlugin.swift:189-190,529`) сносит `active-config.json`,
> `start_options.plist`, `diagnostics.txt` и `stderr.log`; вызывается из
> `VpnController.forgetPersistedTunnelState()` (`vpn_controller.dart:1064-1090`) на
> `disconnect(endSession: true)` и при логауте. Расширение чистит снапшот и со своей
> стороны — по причине остановки (см. **1.6**).
>
> ❌ **Пункт 1 (Keychain) не сделан — осознанно, не забыт.** Перенос `configContent` в
> Keychain с `kSecAttrAccessGroup` = App Group требует entitlement
> `keychain-access-groups` в **обоих** `.entitlements`, а значит capability Keychain
> Sharing на обоих App ID и **перевыпуск provisioning-профилей**. Цена ошибки здесь
> несимметрична: неверный entitlement ломает не диагностику, а **старт самого туннеля**,
> и проверить это без устройства нельзя. Что нужно, чтобы доделать: включить Keychain
> Sharing на App ID Runner'а и расширения, перевыпустить профили, прогнать на девайсе.
> До тех пор защита — файловая, а не аппаратная.
>
> **Проверяется T24**, включая вторую половину: поиск тех же строк в **незашифрованном**
> локальном бэкапе — это и есть проверка `isExcludedFromBackup`.

### 🟠 2.2 Clash API слушает loopback **без `secret`** — любое приложение управляет VPN — 🟡 Частично: секрет есть, **порт фиксированный**
**Где:** `app/packages/singbox_mm/lib/src/config/singbox_config_builder.dart:129-134`

```dart
experimental['clash_api'] = <String, Object?>{
  'external_controller': '127.0.0.1:$clashApiPort',   // 16756 по умолчанию
};
```

Поле `secret` не задаётся. На iOS `127.0.0.1` — **общий для всего устройства** loopback,
а не приватный для процесса. Любое другое установленное приложение может:
- `GET /configs` — прочитать **весь конфиг**, включая пароли и UUID выходных нод;
- `GET /connections` — список всех соединений с доменами назначения (история активности
  в реальном времени);
- `PUT /proxies/<tag>` — переключить исходящий на произвольный;
- `GET /logs` (websocket) — читать логи ядра.

Порт фиксированный и предсказуемый (`singbox_feature_settings.dart:704`, тот же порт
захардкожен в `vpn_controller.dart:368`) — сканировать не нужно.

⚠️ **Файл общий с Android** — фикс закрывает обе платформы, см.
`docs/improvement-plan-app-android.md`.

**Фикс:** генерировать криптослучайный секрет на каждый запуск (32 байта из
`Random.secure()`, base64), класть в конфиг и передавать потребителям — добавить
`Authorization: Bearer $secret` в `TunnelHealthWatchdog.get`
(`TunnelHealthWatchdog.swift:311-323`) и в `vpn_controller._probeViaSingboxApi`
(`vpn_controller.dart:458-482`). Дополнительно — рандомизировать порт и передавать его
расширению через start options.

> **Сделано (2026-07-28, рабочее дерево, вместе с Android §1.6):** 128 бит из
> `Random.secure()` на каждый старт туннеля кладутся в `experimental.clash_api.secret`;
> `TunnelHealthWatchdog` читает секрет из конфига (`ControlAPI { address, secret }`) и
> шлёт `Authorization: Bearer` во всех запросах. Секрет доходит до **обоих** потребителей
> и работает end-to-end — это единственная находка документа, у которой есть хотя бы
> сквозная проверка (хост-тесты `app/packages/singbox_mm/test/clash_api_secret_test.dart`).
>
> ❌ **Не сделано: рандомизация порта.** `16756` по-прежнему захардкожен в трёх местах
> (`singbox_feature_settings.dart:704,772`, `vpn_controller.dart:407` и сам конфиг) и через
> start options не передаётся. Практический риск от этого невелик — порт защищён
> секретом, — но «сканировать не нужно» из текста находки остаётся правдой: чужое
> приложение по-прежнему знает, куда стучаться, и получает `401` вместо отказа
> соединения, то есть сам факт работающего VPN виден.
>
> ⚠️ **Незакрытая связка с 1.3:** при включённом kill-switch (`includeAllNetworks = true`)
> loopback может оказаться отрезан, и тогда собственный watchdog расширения перестанет
> получать ответы от Clash API. Проверять эти две находки **вместе** (T23).

### 🟡 2.3 `external_controller` из конфига не валидируется → исходящий HTTP из расширения — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `TunnelHealthWatchdog.swift:329-354` — `normalizeController` нормализует
wildcard-адреса, но `default:` принимает **любой хост как есть**.

Значение приходит из конфига, который строится из подписочной ссылки BFF
(`connectManualConfigLink`) и может быть перекрыт через `settings.rawConfigPatch`
(`singbox_config_builder.dart:160-162`). При скомпрометированной подписке
`external_controller: "attacker.example:80"` заставит **сетевое расширение** каждые
60 с слать HTTP-запросы на внешний хост — с утечкой тега активного outbound'а и факта
работы VPN, плюс готовый beacon-канал. Заодно sing-box забиндит Clash API на публичный
адрес, выставив управление ядром в локальную сеть.

**Фикс:** в расширении жёстко требовать loopback:

```swift
let loopback: Set<String> = ["127.0.0.1", "::1", "localhost"]
guard loopback.contains(host) else {
    log("(packet-tunnel) refusing non-loopback control API: \(host)")
    return nil
}
```

Симметрично валидировать `experimental.clash_api` на Dart-стороне перед `setConfig`.

> ✅ **Обновление 2026-07-28 (вычитка): закрыты обе половины, не одна.** Утверждение
> ниже про «не сделана Dart-сторона» **устарело** — `_enforceLoopbackControlApi`
> (`singbox_config_builder.dart:826-867`) вызывается **после** merge `rawConfigPatch`
> (`:177-182` — именно в этом порядке, потому что патч и есть то единственное, что может
> увести контроллер), переписывает `external_controller` в `127.0.0.1:$port`, а
> непарсящийся порт роняет `clash_api` целиком (health-пробы деградируют в «unknown» —
> безопасный вердикт). Секрет при этом подставляется, если его вырезали патчем.
> Покрыто пятью тестами: `clash_api_secret_test.dart:133-192`.
>
> **Сделана половина в расширении — ровно предложенным способом.**
> `loopbackHosts = ["127.0.0.1", "::1", "[::1]", "localhost"]`
> (`TunnelHealthWatchdog.swift:93`), `normalizeController` отвергает всё остальное
> (`:471-480`), а вызывающий пишет в лог `refusing non-loopback control API: <host>`
> (`:453-454`) и не делает запроса. Скомпрометированная подписка больше не превращает
> сетевое расширение в beacon.
> ~~❌ Симметричная валидация на Dart-стороне перед `setConfig` не сделана.~~ —
> **неверно, см. врезку выше.** Аргумент оставлен, потому что он объясняет, зачем она
> была нужна: без неё **ядро** при публичном адресе забиндило бы управляющий API наружу,
> в локальную сеть, и расширение просто перестало бы с ним разговаривать — порт остался
> бы открытым. Теперь такой конфиг до ядра не доходит.
>
> 🆕 **Найдено при вычитке (исправлено):** `"::1"` проходил валидацию в расширении, но
> возвращался без скобок, а `URL(string: "http://::1:16756/proxies")` = `nil` — то есть
> любая проба навсегда отвечала «unknown» и watchdog переставал что-либо чинить, **молча**
> (единственная строка лога на этом пути — про отказ хосту). Теперь нормализуется в
> `[::1]` (`TunnelHealthWatchdog.swift`).

### 🟡 2.4 Диагностика утекает конфиг и домены в UI и в support bundle — 🟡 Исправлено в коде; Dart-половина была закрыта **раньше**
**Где:** `PacketTunnelProvider.swift:109, 119-131, 183`; `SingboxMmPlugin.swift:706-732`;
`vpn_controller.dart:861-863`

Ошибки парсинга sing-box традиционно цитируют проблемный фрагмент JSON. Этот текст
(а) пишется в `diagnostics.txt` в App Group plain text без file protection,
(б) читается приложением и **показывается пользователю на экране**, (в) пишется в
app-лог и попадает в шаренный support bundle. Туда же уходит хвост `stderr.log`
(6000 байт, `SingboxMmPlugin.swift:759-766`), где при `debugMode`/`logLevel: debug`
(`singbox_config_builder.dart:1196-1207`) sing-box пишет **домены и адреса назначения
всех соединений пользователя**.

**Почему плохо:** пользователь, отправляя «лог для поддержки», может передать свои
VPN-креденшелы и историю посещённых доменов.

**Фикс:** прогонять текст перед записью в `diagnostics.txt`/support bundle через
редактор секретов (regex по `uuid`, `password`, `private_key`, `short_id`,
`pre_shared_key`, base64-подобным строкам ≥16 символов); запретить `logLevel: debug`
в release-сборке.

> ⚠️ **Уточнение к находке: Dart-половина была закрыта ещё до этих работ.**
> `app/lib/utils/sanitize.dart` (`sanitizeDiagnostics`) появился в Android-доработках
> (§1.9 того документа) и уже прогоняет текст перед `log.e` и перед показом
> пользователю (`vpn_controller.dart:998,1019`). Находка описывала три канала утечки;
> из них Dart-канал был чист к моменту, когда за iOS взялись.
>
> **Сделана нативная половина — та, что несёт домены.**
> - `PacketTunnelProvider.redactSecrets` (`:324-353`) прогоняет текст **перед записью**
>   в `diagnostics.txt` (`:280`) — то есть на диск секрет уже не попадает, а не только
>   в UI.
> - `SingboxMmPlugin.redactSecrets` (`:1050-1075`) чистит хвост `stderr.log` при сборке
>   support bundle (`:1015`).
> - Паттерны одинаковы во всех трёх реализациях (Dart + два Swift) и намеренно грубые:
>   UUID, `password=`/`pbk=`/`sid=`/`auth=`, `credential@host`, голые `ip:port`.
> - `logLevel: debug` в release запрещён (`singbox_config_builder.dart:1294`) —
>   `kReleaseMode` понижает `debug`/`trace` до безопасного уровня, так что домены всех
>   соединений в лог больше не пишутся в принципе.
>
> **Проверяется T25**, и именно приёмом с «маркерным» доменом: три редактора секретов
> ловят креденшелы, но домен без пароля не выглядит секретом ни для одного regex —
> единственная защита от него в том, что `logLevel: debug` больше не включается.

### 🟢 2.5 Комментарий в `add_packet_tunnel_target.rb` расходится с entitlements — 🟡 Исправлено в коде + CI
**Где:** `app/ios/tool/add_packet_tunnel_target.rb:47-52` утверждает «App Group
entitlement is deliberately NOT added here yet», а `app/ios/Runner/Runner.entitlements:9-12`
App Group **содержит**, и скрипт (`:59-61`) прописывает этот файл в
`CODE_SIGN_ENTITLEMENTS`. Если App ID Runner'а действительно не имеет capability App
Groups, подпись либо упадёт, либо entitlement тихо вырежут → `containerURL(...)` вернёт
nil → `readLastError` отдаст `"APP_GROUP_UNAVAILABLE"` (`SingboxMmPlugin.swift:714`) и
вся диагностика мертва. **Фикс:** привести комментарий в соответствие; в CI добавить
`codesign -d --entitlements :- build/.../Runner.app | grep application-groups`.

> **Сделаны оба пункта.** Комментарий (`add_packet_tunnel_target.rb:45-61`) переписан:
> App Group у Runner'а **есть** и нужен ему по делу — приложение читает
> `diagnostics.txt` и хвост stderr расширения и чистит снапшот при логауте, ничего из
> этого без entitlement невозможно. Заодно записана причина, по которой проверять надо
> сборку, а не файл: отсутствие capability на App ID **не обязано** валить подпись —
> entitlement может быть молча вырезан, и единственный симптом это `containerURL(...)`
> = nil.
> В CI добавлен шаг «Verify App Group entitlement survived signing» (`codemagic.yaml`),
> который прогоняет `codesign -d --entitlements :-` по `Runner.app` **и** по
> `PlugIns/PacketTunnel.appex` и падает, если `application-groups` не нашлось.
> ⚠️ **Реальный шанс, что этот шаг покажет проблему:** если capability на App ID
> Runner'а действительно нет, первый же прогон `ios-release` станет красным — и это
> будет не регрессия, а наконец обнаруженное расхождение (см. **1.9**).

### ✅ 2.6 Что проверено и претензий не имеет
- **`codemagic.yaml`: секретов в файле нет.** Подпись через
  `integrations: app_store_connect` (`:28-29`) и `ios_signing` (`:34-36`) — ключи на
  стороне Codemagic. Grep по `api_key|secret|token|password` — пусто.
- **В git нет чувствительных артефактов**: `.p12`, `.mobileprovision`, `.cer`, `.env`
  не трекаются; `backend/.env.example` — только пустые плейсхолдеры.
- **HTTP из расширения** идёт только на loopback Clash API (ATS не нарушен — Apple
  исключает loopback с iOS 10). `http://cp.cloudflare.com/generate_204`
  (`TunnelHealthWatchdog.swift:33`) не запрашивается напрямую, а передаётся параметром
  в delay-тест sing-box, то есть уходит уже внутри туннеля.

---

## 3. ПРОИЗВОДИТЕЛЬНОСТЬ И СТАБИЛЬНОСТЬ (лимит ~50 МБ jetsam)

### 🟠 3.1 Чтение `stderr.log` целиком в память ровно тогда, когда памяти уже нет — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `PacketTunnelProvider.swift:124-129`

```swift
if let data = try? Data(contentsOf: stderrURL),          // ← весь файл в RAM
    let tail = String(data: data.suffix(6000), ...)
```

`LibboxRedirectStderr` (`:158`) пишет в этот файл **без ротации и без ограничения
размера** — он растёт всю жизнь установки.

**Почему плохо:** вызывается из `writeDiagnostics`, то есть **на пути обработки ошибки
старта** и при health-recovery (`:78`). Файл на 30–40 МБ (реально за месяцы) →
мгновенный выход за jetsam-лимит → расширение убито при попытке записать причину, почему
оно не смогло стартовать. Чем чаще ошибки, тем больше лог, тем вернее крэш вместо
диагностики.

**Фикс:** читать только хвост через `FileHandle` (`seekToEnd` → `seek(toOffset:)` →
`readToEnd`); в `startTunnel0` перед `LibboxRedirectStderr` усекать файл, если он больше
~256 КБ. **Тот же паттерн** повторить в `SingboxMmPlugin.swift:719-721` и `:759-760`.

> **Сделано во всех трёх местах.** Хвост читается через `FileHandle` (`seekToEnd` →
> `seek(toOffset:)` → `readToEnd`) вместо `Data(contentsOf:)`, и `stderr.log` усекается
> перед `LibboxRedirectStderr`, если перерос порог. Смысл правки в том, **когда** она
> срабатывает: путь `writeDiagnostics` — это путь обработки ошибки старта и
> health-recovery, то есть момент, когда памяти уже нет, а расширение как раз пытается
> объяснить, почему не смогло стартовать.

### 🟠 3.2 TUN-стек жёстко `gvisor`, альтернативы нет — 🟡 Исправлено в коде (Dart), **только iOS**
**Где:** `app/packages/singbox_mm/lib/src/config/internal/singbox_inbound_builder.dart:68-75`
— `_toTunStack` возвращает `'gvisor'` для **обоих** значений, включая
`SingboxTunImplementation.system`. Пользовательская настройка «сетевой стек» на iOS не
работает; дефолт контроллера — тоже gvisor (`connection_settings_controller.dart:76`).

**Почему плохо:** gvisor — полный userspace TCP/IP-стек на Go, с буферами на каждое
соединение, отдельными горутинами и своим GC-давлением. Самый прожорливый по памяти
вариант, работающий внутри процесса с лимитом ~50 МБ. `system` (прямая передача пакетов)
потребляет в разы меньше и даёт больший throughput. Это вероятная первопричина
jetsam-килов под нагрузкой (браузер, стриминг = много соединений).

**Фикс:** вернуть честный маппинг `system` → `'system'` и сделать `system` дефолтом на
iOS; gvisor оставить опцией «совместимость». ⚠️ Проверить на Android, что маппинг
общий — файл шареный.

> **Сделаны оба пункта, и предупреждение про общий файл учтено.**
> `_toTunStack` (`singbox_inbound_builder.dart:78-85`) отдаёт `'system'` для `system` и
> `'gvisor'` для `gvisor` — переключатель «сетевой стек» в UI наконец что-то делает;
> дефолт вынесен в `defaultTunImplementation` (`singbox_feature_settings.dart:50-63`) и
> равен `system` **только на iOS**.
> ⚠️ **Android оставлен на gvisor намеренно.** Файл общий, а released-сборка Android
> device-тестирована именно на gvisor, где лимита в 50 МБ нет вовсе; менять её тем же
> диффом значило бы обесценить проведённый прогон. Перенос на Android — отдельная
> задача.
> ⚠️ **Это самая рискованная правка документа.** Меняется путь обработки **каждого
> пакета**: `system` отдаёт их ядру вместо userspace-стека. Проверять на устройстве
> надо не только «работает ли», а скорость, стабильность длинной сессии и — главное —
> **пропали ли jetsam-килы** по сравнению с gvisor (T23, отчёты `JetsamEvent-*`).

### 🟡 3.3 `cache_file` включён по умолчанию, `logMaxLines = 3000` — 🟡 Исправлено в коде (Swift + Dart)
**Где:** `singbox_config_builder.dart:122-127` (`'enabled': !settings.advanced.memoryLimit`)
+ `singbox_feature_settings.dart:107`. `buildFeatureSettings()`
(`connection_settings_controller.dart:414-438`) **не передаёт `advanced:` вообще** →
`memoryLimit = false` → `cache_file` и `store_fakeip` включены на iOS всегда. Плюс
`setupOptions.logMaxLines = 3000` (`PacketTunnelProvider.swift:149`) — libbox держит
3000 строк лога в памяти расширения. `LibboxSetMemoryLimit(true)` (`:159`) выставлен
правильно, но он лишь подстраивает GOGC, а не отменяет расходы выше.

**Фикс:** на iOS форсировать `AdvancedOptions(memoryLimit: true)` в
`buildFeatureSettings()` (по `defaultTargetPlatform`), снизить `logMaxLines` до 300–500.

> **Сделаны оба пункта ровно так.** `buildFeatureSettings()` теперь **передаёт**
> `advanced:` (раньше не передавал вовсе, отчего `memoryLimit` был `false` всегда) и
> ставит `memoryLimit: defaultTargetPlatform == TargetPlatform.iOS`
> (`connection_settings_controller.dart:492-499`) — на iOS `cache_file` и `store_fakeip`
> выключаются (`singbox_config_builder.dart:127-129`). `setupOptions.logMaxLines`
> снижен 3000 → **300** (`PacketTunnelProvider.swift:371`).
> ⚠️ Побочный эффект, который стоит помнить при проверке: без `cache_file` теряется
> кеш DNS и fake-ip между запусками — первый коннект после старта может быть чуть
> медленнее, зато в память ничего не тянется.

### 🟡 3.4 Жёстко зашитый MTU 1100 — 🟡 Исправлено в коде (Dart), **только iOS**
**Где:** `singbox_inbound_builder.dart:32`. 1100 очень консервативно (типовой безопасный
VPN MTU 1280–1420). ~20% полезной нагрузки теряется на заголовках относительно 1400;
больше пакетов → больше проходов через gvisor → выше CPU, ниже скорость, выше расход
батареи. **Фикс:** поднять дефолт до 1280 (безопасно и для IPv6-минимума), вывести в
настройки; для WireGuard считать по формуле от оверхеда транспорта.

> **Сделан первый пункт.** Дефолт вынесен в `defaultTunMtu`
> (`singbox_feature_settings.dart:11-25`): **1280 на iOS**, 1100 на Android. 1280 — это
> минимальный link MTU IPv6, ниже которого на v6-пути ничто не имеет права
> фрагментироваться, и он же оставляет запас на инкапсуляцию аутбаунда. Значение
> по-прежнему перекрывается через `InboundOptions.mtu` (валидация 576…9000).
> ❌ **Не сделано:** вывод MTU в пользовательские настройки и расчёт по формуле от
> оверхеда транспорта для WireGuard.
> ⚠️ Android остался на 1100 по той же причине, что и в 3.2: это значение, на котором
> released-сборку проверяли на устройстве.

### 🟡 3.5 Два независимых health-контура работают одновременно — 🟡 Исправлено в коде (Swift + Dart)

| Контур | Где | Период | Что делает |
|---|---|---|---|
| В расширении | `TunnelHealthWatchdog.swift:40` | **60 с** | Clash API `/proxies` + delay-тест наружу |
| В приложении | `vpn_controller.dart:83, 621-625` | **180 с** | `_verifyTunnelCarriesTraffic` → HTTPS на `gstatic.com` |

Плюс внеочередные `checkSoon()` на каждом изменении сетевого пути
(`ExtensionPlatformInterface.swift:237`) и на каждом `wake()` (дебаунс 8 с).

**Почему плохо:** watchdog в расширении работает 24/7, включая фон и заблокированный
экран — это единственный процесс, который iOS не усыпляет. Каждые 60 с: 1 HTTP к
loopback + 1–2 полных TLS-хендшейка наружу. За ночь ~480 циклов — заметный расход
батареи и трафика на LTE, при том что приложение параллельно делает свой контур.

**Фикс:** поднять `checkInterval` до 180–300 с (первичное обнаружение закрывается
событийным `checkSoon()` на смене сети/wake — это и есть реальные триггеры отвала);
адаптировать интервал при `path.isExpensive` (LTE) и Low Power Mode; отключить
app-контур на iOS, раз в расширении есть свой.

> **Сделаны все три пункта.**
> - Базовый интервал watchdog'а 60 → **180 с** (`TunnelHealthWatchdog.swift:57`).
> - Адаптация по цене канала: **300 с** на `path.isExpensive`/Low Power Mode
>   (`:62`), плюс backoff **600 с** после серии безуспешных восстановлений (`:66`);
>   перевзвод таймера идёт через `desiredInterval()`/`rescheduleIfNeeded` (`:335-352`),
>   а не пересозданием — иначе каждая перепланировка отодвигала бы следующую проверку
>   на полный интервал.
> - App-контур на iOS не выключен, а **разрежен**: `_sessionHealthInterval` стал
>   геттером и на iOS равен **6 мин** против 3 на Android
>   (`vpn_controller.dart:87-97`). Полностью убирать его не стали: он единственный
>   умеет показать пользователю плашку «туннель не пропускает трафик», а вердикт
>   нативного watchdog'а в Dart до сих пор не проброшен (то же отложено и на Android,
>   §3.13 того документа).
> - Событийные `checkSoon()` на смене пути и на `wake()` сохранены — они и есть
>   реальный триггер обнаружения, интервал лишь страховка.

### 🟢 3.6 105 секунд до первого восстановления — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `TunnelHealthWatchdog.swift:49` (`firstCheckDelay = 45`) и `:57`
(`failuresBeforeRecovery = 2`) → 45 + 60 = минимум 105 с от старта нерабочего туннеля
до восстановления, всё это время приложение показывает `connected`. **Фикс:** снизить
`firstCheckDelay` до 15–20 с — одного TLS-хендшейка достаточно, чтобы понять, работает
ли outbound, и проверка одноразовая (расход не растёт).

> **Сделано:** `firstCheckDelay` 45 → **20 с** (`TunnelHealthWatchdog.swift:86`).
>
> ⚠️ **Исправление арифметики (вычитка 2026-07-28).** Здесь было написано «20 + 180 =
> 200 с, хуже прежних 105». Это неверно: расчёт не учитывал `recheckInterval = 20 с`
> (`TunnelHealthWatchdog.swift:77`), который `desiredInterval()` возвращает **после первой
> же неудачи** — 180 с это интервал для здорового туннеля, а не для подозрительного.
> Реальный худший случай — **20 + 20 = 40 с**, то есть лучше и заявленных 200, и
> дореформенных 105. Плюс `expeditedCheckDelay = 8 с` (`:90`) и событийные `checkSoon()`
> на смене сети и пробуждении, а `minRecoveryInterval = 90 с` (`:97`) не даёт
> восстановлениям идти чередой.

### 🟢 3.7 `URLSession` в watchdog'е без ограничения кеша — 🟡 Исправлено в коде (собирается на CI; на устройстве не проверено)
**Где:** `TunnelHealthWatchdog.swift:97-102` — `URLSessionConfiguration.ephemeral`
создаёт in-memory URL-кеш (несколько МБ) внутри процесса с лимитом 50 МБ.
**Фикс:** `configuration.urlCache = nil`, `configuration.httpShouldSetCookies = false`.

> **Сделано ровно так, обе строки** (`TunnelHealthWatchdog.swift:145-146`).

---

## 4. CI / codemagic.yaml

### 🟡 4.1 Незакреплённый тулчейн — сборка нереспроизводима — 🟡 Частично; ⚠️ **рекомендация `xcode: 16.2` отклонена как вредная**
**Где:** `codemagic.yaml:39-41, 87-89` (`flutter: stable`, `xcode: latest`,
`cocoapods: default`) + `:48`, `:101` (`gem install xcodeproj --no-document` без версии).
Обновление Xcode или Flutter на стороне Codemagic ломает релизную сборку без изменений
в репозитории — для приложения с Network Extension особенно болезненно (ломается
подпись/entitlements, а не код). Незакреплённый `xcodeproj` gem правит
`Runner.xcodeproj` (`add_packet_tunnel_target.rb:151`) — смена мажорной версии молча
изменит структуру проекта. **Фикс:** `flutter: 3.35.x`, `xcode: 16.2`,
`gem install xcodeproj -v 1.27.0`.

> **Закреплено то, что зависит только от нас:** `flutter: 3.44.4` в обоих iOS-воркфлоу
> (`ios-release` и `ios-unsigned` — валидационная сборка обязана валидировать тот же
> тулчейн) и `gem install xcodeproj -v 1.27.0 --no-document`. Именно gem правит
> `Runner.xcodeproj`, и именно его мажорная версия способна молча изменить структуру
> проекта.
>
> ❌ **`xcode: 16.2` отклонено — это ошибка рекомендации, а не невыполненный пункт.**
> Apple раз в год (обычно в апреле) поднимает минимальный SDK, который App Store Connect
> принимает при загрузке. Зафиксированная версия Xcode поэтому перестаёт работать **в
> дату, о которой никто не поставил напоминание**, и падает не на сборке, а **на
> аплоаде** — то есть после того, как всё собралось, и, как правило, ровно тогда, когда
> релиз нужен. `latest` — единственное значение, которое продолжает удовлетворять этому
> правилу само. То же рассуждение про `cocoapods: default`: он обязан поспевать за
> Xcode.
> Пинить Xcode осмысленно ровно в одном случае — воспроизвести конкретную прошлую
> сборку; тогда надо сразу закладывать, что аплоад отклонят. Рассуждение записано
> комментарием прямо в `codemagic.yaml`, чтобы через полгода его никто не «починил».

### 🟡 4.2 Нет quality gate перед публикацией в TestFlight — 🟡 CI (проверится первым прогоном)
**Где:** `codemagic.yaml:37-70` (workflow `ios-release`) — шаги LFS pull → pub get →
add target → diagnose → pod install → use-profiles → build ipa → publish. **Нет ни
`flutter analyze`, ни `flutter test`.** Билд уезжает в TestFlight при любом состоянии
кода. **Фикс:** добавить перед сборкой `flutter analyze --fatal-infos && flutter test`.

> **Сделано, шаг «Analyze and test» перед сборкой** — и он прогоняет `flutter analyze` +
> `flutter test` **в двух пакетах**: `app/` и `app/packages/singbox_mm/` (аудит упоминал
> только первый, а половина изменённого Dart-кода живёт во втором).
> ⚠️ `--fatal-infos` **не** ставили: гейт должен ловить ошибки, а не превращать в блокер
> релиза очередной новый info-level линт при обновлении Flutter.
> Аргумент в пользу гейта записан комментарием на месте: номер сборки расходуется при
> загрузке и не возвращается, поэтому красный прогон здесь стоит дёшево, а плохая сборка
> на телефоне тестировщика — нет.

### 🟢 4.3 Отладочный шаг в релизном пайплайне — 🟡 CI (проверится первым прогоном)
`codemagic.yaml:50-57` (дубль `:103-110`) — `xcodebuild -showBuildSettings` с
`-configuration Debug`, ~30–60 с на каждый билд, всегда `|| true`. Убрать из
`ios-release` или вынести в отдельный debug-workflow.

> **Сделано по второму варианту:** шаг «Diagnose PacketTunnel target build settings»
> удалён из `ios-release` и **оставлен** в `ios-unsigned` — это и есть отладочный
> воркфлоу, там он полезен, а в пайплайне, который публикует в TestFlight, ему делать
> нечего. Причина оставления записана комментарием, чтобы дубль не «вычистили» заодно.

### 🟢 4.4 `max_build_duration: 60` при 260 МБ LFS — ⚠️ **находка была неверна: уже закрыта до аудита**
`codemagic.yaml:26, 84` — при холодном LFS-кеше (два бинаря по ~150 МБ) риск упереться
в лимит. Поднять до 90–120 для `ios-release`.

> ❌ **Находка описывала состояние, которого не было.** Оба iOS-воркфлоу — и
> `ios-release`, и `ios-unsigned` — на момент работ уже стояли на
> `max_build_duration: 120`; строка `:26`, на которую ссылается аудит, принадлежит
> **третьему** воркфлоу, `ios-libbox-xcframework`, — тому, который собирает
> `Libbox.xcframework` через gomobile.
>
> **Сделано:** поднят именно он, 60 → **120**. И причина у него другая, чем в тексте
> находки: дело не в холодном LFS-кеше (этот воркфлоу как раз **производит** бинари, а не
> тянет их), а в том, что gomobile собирает оба ядра из исходников ~20-30 минут, поверх
> чего может лечь холодная установка Homebrew/Go на раннере.

---

## Найдено при доработке — этого в аудите не было

### 🔴 N1. On-demand надо снимать **перед** остановкой, иначе кнопка «Отключить» перестаёт работать

Прямое следствие 1.3, которого рецепт находки не предусматривал. `NEOnDemandRuleConnect`
означает «поднимай туннель, когда есть подходящий интерфейс» — и система исполняет это
буквально, в том числе через секунду после того, как пользователь нажал «Отключить».
Первая версия правки давала ровно это: тоггл гаснет, туннель поднимается обратно сам,
выключить VPN из приложения невозможно вообще.

**Фикс:** `stopTunnel` сначала снимает `isOnDemandEnabled` и сохраняет профиль, и только
в коллбэке `saveToPreferences` вызывает `stopVPNTunnel()` (`SingboxMmPlugin.swift:687-698`).

**Мораль:** kill-switch и автоподъём — это не «настройка», а изменение того, кому
принадлежит решение о состоянии туннеля. Каждый путь остановки после их включения надо
пересматривать заново; T15 поэтому проверяет **не только** кнопку, но и sign-out, и 402.

---

## Вычитка ремедиации (2026-07-28) — что нашлось в самих правках

Правки аудита читались повторно, построчно, всеми четырьмя слоями. На момент вычитки
Swift ещё не компилировался — но это и не важно для списка ниже: **почти всё в нём
компилятор не поймал бы в принципе**, и зелёная сборка 136, состоявшаяся позже, ни одного
пункта не закрыла. Вызов `FlutterEventSink` с чужого потока, отсутствие `set -e`,
непроверенный `.ipa`, битый снапшот, срез UTF-8 посередине символа — всё это собирается
безупречно.

### Исправлено в ходе вычитки

| # | Где | Что было | Почему это важно |
|---|---|---|---|
| **V1** 🔴 | `SingboxMmPlugin.swift`, `emitState`/`emitStats` | `FlutterEventSink` дёргался с потока коллбэка NetworkExtension | Каналы Flutter можно трогать **только** с platform-thread: в debug это assert, в release — UB. В том же файле каждый `result(...)` уже был обёрнут в `DispatchQueue.main.async`, а два эмиттера — нет. Добавлен `onPlatformThread` |
| **V2** 🔴 | `codemagic.yaml`, шаг «Analyze and test» | Нет `set -e` | Код возврата скрипта = код **последней** команды, поэтому падение `flutter analyze` в `app/` печаталось и игнорировалось. **Гейт, написанный ради блокировки публикации, не блокировал** — из пяти проверок стопорить сборку могла только последняя |
| **V3** 🟠 | `codemagic.yaml`, шаг проверки entitlements | `find app/build/ios -name Runner.app`, `exit 0` если не нашлось | Проверялся архивный бандл, а **пере-подписывает** его экспорт по `export_options.plist` — то есть ровно тот шаг, на котором entitlement и может быть срезан. Плюс ненайденный бандл давал зелёный шаг. Теперь распаковывается экспортированный `.ipa`, отсутствие `.ipa` или `PacketTunnel.appex` — провал |
| **V4** 🟠 | `PacketTunnelProvider.swift` | `try commandServer!.start()` | gomobile-конструктор может вернуть nil, не выставив NSError. Форс-анврап внутри NE = крэш-луп с экспоненциальным backoff — ровно то, ради чего из этого файла убирали `fatalError` (**1.9**) |
| **V5** 🟠 | `PacketTunnelProvider.loadPersistedStartOptions` | Битый plist бросал наружу | Исключение валило старт. При включённом on-demand iOS поднимает расширение снова — и оно снова падает на том же файле, **бесконечно**. Теперь нечитаемый снапшот удаляется и трактуется как отсутствующий |
| **V6** 🟠 | `TunnelHealthWatchdog.normalizeController` | `"::1"` проходил, но возвращался без скобок | `URL(string: "http://::1:16756/...")` = `nil` → каждая проба «unknown» → **watchdog переставал чинить что-либо, молча**. Нормализуется в `[::1]` |
| **V7** 🟠 | `SingboxMmPlugin.tailOfFile` | Срез по смещению рвал UTF-8 | `String(data:encoding:.utf8)` возвращает `nil` для **всего** хвоста, если срез попал в середину многобайтового символа. Вызывающий читает это как «stderr пуст» — то есть jetsam-кил, единственная улика по которому и есть этот файл, отрапортовался бы как «ошибок нет» |
| **V8** 🟠 | `SingboxMmPlugin.stopTunnel` | Ошибка `saveToPreferences` проглочена | Туннель останавливался, но правило on-demand оставалось в профиле → iOS поднимал его обратно через секунду, а приложение уже отрапортовало успешное отключение. Симптом **N1**, вернувшийся молча. Теперь пишется в `lastError` и в лог |
| **V9** 🟠 | `SingboxMmPlugin.awaitDisconnected` | Тело функции выполнялось не на main | Обсервер регистрировался с фонового потока, а `finish()` читал переменную с main: смена статуса в этом окне оставляла обсервер зарегистрированным до конца процесса. Всё тело перенесено на platform-thread |
| **V10** 🟠 | `SingboxMmPlugin.clearPersistedState` | `active-config.json` удалялся только если в этом процессе успел отработать `initialize` | Логаут в процессе, который ни разу не подключался, **оставлял подписку в открытом виде на диске** — ровно то, что этот канал и должен предотвращать (**2.1** п.3). Добавлен безусловный фолбэк на дефолтный путь |
| **V11** 🟠 | `vpn_controller.dart:_connect` | `_clashApiSecret` присваивался **после** `connectManualConfigLink` | Бросок после старта туннеля (dual-core fallback это делает) оставлял работающий туннель с новым секретом, а поле — со старым: все пробы получали 401, тег аутбаунда читался как null, и **мёртвый туннель переставал детектироваться**. Присвоение перенесено до коннекта |
| **V12** 🟡 | `PacketTunnelProvider.startTunnel0` | `corePaused` не сбрасывался при старте | Процесс расширения переиспользуется между сессиями: сессия, закончившаяся на паузе, оставляла флаг, и watchdog отвечал «unknown» на здоровье **нового** туннеля до первого сетевого события |
| **V13** 🟡 | `PacketTunnelProvider` | `appGroupAvailable` вычислялся независимо от `sharedDirectory` | `sharedDirectory` — это `let`: один раз уехав в temp, он там и остаётся. Повторный опрос контейнера мог ответить «доступен», и маркер `APP_GROUP_UNAVAILABLE` не печатался, пока приложение искало файлы в App Group и не находило. Теперь резолвятся одним `let` |
| **V14** 🟡 | `PacketTunnelProvider.startTunnel0` | `Working/` и `Caches/` не hardened | Защищались три «наших» файла, а каталоги, которые отдаются libbox как `basePath`/`workingPath`, — нет. Всё, что ядро туда пишет, уходило в незашифрованный бэкап |
| **V15** 🟡 | `add_packet_tunnel_target.rb` | `gem install -v 1.27.0` без `gem` в скрипте | Установка версии **не выбирает** её: CocoaPods тянет xcodeproj следом, а RubyGems активирует новейшую. Пин в CI не действовал. Добавлен `gem 'xcodeproj', '~> 1.27'` перед `require` |
| **V16** 🟡 | `signbox_vpn_test.dart` ×3 | `expect(tunInbound.containsKey('inet6_address'), isFalse)` | Билдер такого ключа никогда не писал — ассерт не мог упасть **ни при каких изменениях кода**, и при этом назывался проверкой отсутствия IPv6. Заменён на проверку списка `address` |

### Найдено и **не** исправлено — это и есть новый список работ

| # | Где | Что | Почему не сделано сейчас |
|---|---|---|---|
| **V17** 🔴 ✅ **закрыт в коде (2026-07-29, не проверен на устройстве)** | `auth_controller.dart`, `home_screen.dart`, `vpn_controller.dart` | **Логаут по 401 и истечение подписки (402) обходят `forgetPersistedTunnelState()`.** При `!subscriptionActive` `HomeScreen` снимается с дерева, `onSessionDropped` обнуляется, а автоматический `signOut()` из `_doRefresh` выполняется уже без него. На 402 туннель вдобавок **не останавливался вовсе** | Закрыто без правки жизненного цикла экранов: у `VpnController` появился статический `stopAndForgetStandalone()` (стоп туннеля + тот же вайп, что `forgetPersistedTunnelState`, без живого контроллера), а `AuthController._dropTunnelWithSession()` идёт через `onSessionDropped`, когда экран смонтирован, и через standalone-фолбэк, когда нет. Вызывается из `signOut()` (ручной и авто-401), из `notifyExpired()` (402 — **до** `notifyListeners`, пока хендлер ещё привязан) и из `_doRefresh` при переходе подписки в «истекла». Дублирующий `_vpn.disconnect()` в 402-ветке `_loadServers` убран. Тесты: `audit_v17_session_death_teardown_test.dart` (6 шт., все пути смерти сессии). Проверка на устройстве — T15 (не-кнопочные пути: sign-out, 402) |
| **V18** 🟠 | `ExtensionPlatformInterface.swift` | Гонка на `nwMonitor`/`networkSettings`: пишутся из Go-потоков, читаются с очереди watchdog'а через `hasUsableUpstream`/`isUpstreamExpensive` — **обоих читателей добавила эта же ремедиация** | Тот же класс бага, что **1.5**, но в соседнем файле: там завели очередь `fatvpn.packet-tunnel.state`, здесь нет. Правка не однострочная, а проверить её без устройства нельзя |
| **V19** 🟠 | `PacketTunnelProvider.swift` | `lazy var healthWatchdog` / `platformInterface` не потокобезопасны; точки первого касания лежат на четырёх разных потоках | Команда `stats`, пришедшая до конца `startTunnel0`, может создать watchdog дважды (второй — с живым таймером) |
| **V20** 🟠 | `PacketTunnelProvider.swift` | **TTL снапшота 7 суток конфликтует с on-demand.** Метка времени пишется только при успешном старте; сессия живёт 90 дней | Туннель, проработавший дольше недели и убитый jetsam'ом, при автоподъёме получит «discarding expired» → «Missing start options» → отказ старта по кругу. TTL надо освежать или привязывать к логауту, а не к календарю |
| **V21** 🟠 | `SingboxMmPlugin.restartVpn` | Таймаут `awaitDisconnected` (10 с) трактуется как успех | Если соединение всё ещё `.disconnecting`, `startVPNTunnel` iOS проигнорирует молча, а `result(nil)` отрапортует успех. Баг «смена сервера иногда не срабатывает» из **1.10** *смягчён* (0.6 с → 10 с), но не устранён |
| **V22** 🟠 | `ExtensionPlatformInterface.clearDNSCache` | `reasserting` снимается **только если коллбэк пришёл** | Непришедший коллбэк оставляет приложение в «Подключение» навсегда — тот самый сценарий, ради которого в **1.4** появился `runBlocking`, только здесь таймаута нет вовсе. Плюс `tunnel` захвачен сильно |
| **V23** 🟠 | `PacketTunnelProvider.swift` | `harden(stderrURL)` вызывается сразу после `LibboxRedirectStderr` | Если Go создаёт файл лениво, оба вызова внутри `harden` уходят в `try?` вхолостую, и пересозданный `stderr.log` получает дефолтный класс защиты. Это единственный из трёх артефактов **2.1**, чьё создание мы не контролируем — а док числит его закрытым. Проверять на T24 |
| **V24** 🟡 | `connection_settings_controller.dart` | Снятие галки `autoReconnect`/`killSwitch` доходит до профиля **только при следующем ручном коннекте** | После jetsam-килла флаг в профиле остался `true`: пользователь снимает галку, а ОС продолжает поднимать туннель. Плюс любой флип этих настроек на живом туннеле рвёт сессию (`home_screen.dart` не различает настройки) |
| **V25** 🟡 | `PacketTunnelProvider.swift` | Строки `discarding expired / vN start options snapshot` пишутся **до** создания командного сервера | Уходят в никуда. Приёмка **T16** («не на устаревшем ли конфиге») останется без следа в логе — а именно по логу её и предлагается проверять |
| **V26** 🟡 | `redactSecrets` (оба Swift + Dart) | base64-строки ≥16 символов из рецепта **2.4** не реализованы; голый IPv4 без порта и **любой IPv6** не редактируются; `ss://<base64>@host` со слэшем внутри не ловится | Целая base64-подписка пройдёт через санитайзер нетронутой. Док перечисляет реализованное, но нигде не помечает выпавшее требование |
| **V27** 🟡 | `PluginMethodDispatcher.kt` | `clearPersistedState` на Android — тихий no-op (`notImplemented`, глотается) | Докстринг platform interface обещает «Erases the stored config». На Android конфиг с UUID подписки переживает логаут — это находка **Android**, а не iOS, но обнаружена здесь |
| **V28** 🟡 | `traffic_throttle_policy.dart` | **Адаптивный MTU на iOS фактически выключен**: дефолт 1280, кандидаты лестницы 1400…1320, понижаться некуда | Не баг, но §3.4 читается как «починили на обеих платформах». Лестница на iOS бесполезна, и это стоит либо признать в тексте, либо расширить кандидаты вниз |
| **V29** 🟡 | тесты | `ios_audit_memory_profile_test.dart` целиком и группа §2.2 в `clash_api_secret_test.dart` пиннят код, который был в `master` **до** ремедиации | На откате правок не покраснеют. Нужен сквозной тест `buildFeatureSettings() → SingboxConfigBuilder` (§3.2+3.3+3.4 разом) и вынос клэмпа release-лога в тестируемую функцию |
| **V30** 🟡 | CI | `pubspec.lock` не в git ни в `app/`, ни в `app/packages/singbox_mm/` | Тулчейн закреплён (`flutter: 3.44.4`), разрешение зависимостей — нет. Заявленная воспроизводимость достигнута наполовину. Правка затрагивает и Android-сборку, поэтому вынесена в решение, а не сделана молча |

**Замечание к 1.3 × 2.2 (T23).** По коду опасение «kill-switch отрежет Clash API» выглядит
завышенным: `includeAllNetworks` влияет на выбор интерфейса для исходящего трафика, а
watchdog ходит на `127.0.0.1`/`[::1]` внутри **того же процесса** и интерфейс не выбирает.
Проверять всё равно стоит, но как низкоприоритетное, а не как «обязательно и вместе».

**Замечание к номерам строк.** Ссылки в тексте находок разъехались с кодом на 10-20 строк
(для `TunnelHealthWatchdog.swift` — систематически ~13 строк начиная с 66-й; функция,
названная в доке `rescheduleIfNeeded`, в коде — `applyInterval`). Причина не только в дрейфе
`master`: часть текста писалась по промежуточной ревизии тех же правок. **Сверяться по имени
символа.**

---

## Где ошибся сам аудит

Исправлено в тексте самих находок, а не помечено сноской.

1. **1.7 — верный диагноз, неработающее лечение.** Предложенный
   `settings.ipv6Settings = ipv6Addresses.isEmpty ? nil : ipv6Settings` делает поведение
   iOS определённым, но утечку **не закрывает**: при `nil` v6-трафик так же идёт мимо
   туннеля. Настоящая причина — в другом файле: правило `::/0 → block` в конфиге уже
   существовало, но до него не доходил ни один пакет, потому что у TUN не было
   inet6-адреса. Понадобился `defaultTunInet6Address`.
2. **1.14 — вторая половина рецепта невыполнима.** «Сверять ожидаемое имя интерфейса»
   требует знать имя `utunN` до открытия fd, а iOS его не сообщает — узнать имя можно
   только тем самым `getsockopt`, ради которого скан и делается. Сделано то, что
   возможно: `getdtablesize()`, выбор самого свежего `utun*` и лог при неоднозначности.
3. **4.1 — рекомендация `xcode: 16.2` сегодня вредна.** Apple ежегодно поднимает
   минимальный SDK, принимаемый App Store Connect; закреплённая версия Xcode перестаёт
   работать в дату, о которой никто не помнит, и падает **на аплоаде**, после полной
   сборки. Закреплено только то, что от Apple не зависит: Flutter и gem `xcodeproj`.
4. **4.4 была закрыта до аудита.** Оба iOS-воркфлоу уже стояли на
   `max_build_duration: 120`; строка `codemagic.yaml:26` принадлежит третьему воркфлоу,
   `ios-libbox-xcframework`. Поднят он — и по другой причине, чем в тексте находки.
5. **2.4 наполовину закрыта до аудита.** Dart-санитайзер (`app/lib/utils/sanitize.dart`)
   появился в Android-доработках; открытой оставалась только нативная половина.
6. **Номера строк местами разошлись с рабочим деревом.** Аудит писался по `master`
   2026-07-27, а Android-доработки успели переписать часть общего Dart-кода: например,
   `_waitForDisconnected` с окном 4 с (упоминается в 1.10) — это уже публичный
   `waitForDisconnected` с окном 10 с (`vpn_controller.dart:950`). Сверяться по имени
   символа, а не по номеру строки.

---

## Что осталось открытым и почему

| Что | Находка | Почему не сделано |
|---|---|---|
| **Keychain для `configContent`** | 2.1 | Нужен entitlement `keychain-access-groups` в обоих `.entitlements` → capability Keychain Sharing на обоих App ID → **перевыпуск provisioning-профилей**. Ошибка там ломает не диагностику, а старт туннеля, и без устройства не проверяется. Файловая защита (`completeFileProtectionUntilFirstUserAuthentication` + `isExcludedFromBackup` + удаление при логауте) сделана |
| **Рандомизация порта Clash API** | 2.2 | `16756` захардкожен в трёх местах и не передаётся через start options. Порт защищён секретом, так что это про скрытность, а не про доступ |
| ~~Валидация `external_controller` на Dart-стороне~~ | 2.3 | ✅ **Закрыто** — строка держалась по ошибке. `_enforceLoopbackControlApi` вызывается после merge `rawConfigPatch`, покрыт пятью тестами |
| **MTU в настройках + формула для WireGuard** | 3.4 | Сделан только дефолт 1280 на iOS |
| **Проброс вердикта нативного watchdog'а в Dart** | 3.5 | Новая нативная поверхность на обеих платформах; то же отложено и на Android (§3.13 того документа). App-контур на iOS разрежен до 6 мин вместо выключения |
| **Перенос iOS-правок на Android** | 1.7, 3.2, 3.4 | `system`-стек, MTU 1280 и inet6-адрес TUN включены **только на iOS**. Файл общий, но released-сборка Android device-тестирована на gvisor/1100/IPv4-only — менять её тем же диффом значит обесценить её проверку |
| **Проверка kill-switch × Clash API** | 1.3 × 2.2 | `includeAllNetworks = true` может отрезать loopback и вместе с ним health-контур расширения. Не проверено (T23) — но по коду риск выглядит завышенным, см. замечание в разделе вычитки |
| **Логаут/402 не стирают persisted state** | V17 (⊃ 1.6, 2.1) | 🔴 **Самый тяжёлый открытый пункт.** Требует правки жизненного цикла экранов. На iOS с on-demand это значит подъём туннеля на отозванных кредах |
| **Гонки: `nwMonitor`, `lazy var healthWatchdog`** | V18, V19 | 1.5 закрыта в одном файле из двух; новых читателей с чужого потока добавила сама ремедиация |
| **TTL снапшота 7 суток vs on-demand** | V20 (⊃ 1.6) | Даёт отказ старта по кругу у сессии старше недели |
| **Таймаут `awaitDisconnected` = «успех»** | V21 (⊃ 1.10) | Смена сервера смягчена, но не починена |
| **`reasserting` без таймаута** | V22 (⊃ 1.2) | Непришедший коллбэк = «Подключение» навсегда |
| **`harden(stderr.log)` до создания файла** | V23 (⊃ 2.1) | Единственный артефакт, чьё создание мы не контролируем |
| **Тесты-плацебо и непокрытые правки** | V29 | ~45 из ~100 `ios_audit_*` тестов не покраснеют на откате; нужен сквозной тест app→plugin |
| **`pubspec.lock` не в git** | V30 | Затрагивает и Android-сборку — вынесено в решение, а не сделано молча |

---

## Рекомендуемый порядок работ

> **Статус на 2026-07-28:** все четыре спринта отработаны в коде (с оговорками выше).
> Осталось то, что перечислено в «Что осталось открытым», и вся проверка на устройстве.

**Спринт 1 (безопасность + blackhole-баги):** 2.2 (secret для Clash API) → 1.1 → 1.2 →
2.1 → 3.1. Пять точечных правок, закрывающих самые тяжёлые утечки и самые неприятные
для пользователя отказы.
— 🟡 в коде; 2.1 частично (Keychain нет), 2.2 частично (порт фиксированный).

**Спринт 2 (устойчивость):** 1.3 (on-demand) → 1.4 → 1.5 → 1.6 → 1.9.
— 🟡 в коде. 1.3 потребовала правок в четырёх слоях и породила находку **N1**.

**Спринт 3 (утечки трафика + производительность):** 1.7 → 1.8 → 3.2 → 3.3 → 3.4.
Обязательно расширить `docs/release-test-checklist.md` проверками IPv6-leak и
«выключить Wi-Fi во время активной загрузки»: текущая валидация Фазы 7
(`docs/ios-vpn-tunnel-spec.md:241-253`) проверяла только DNS-leak и сам факт выживания
при смене сети, поэтому пункты 1.2 и 1.7 через неё прошли незамеченными.
— 🟡 в коде; 3.2 и 3.4 — только на iOS. ✅ Чек-лист расширен: T12 (IPv6),
T14 (смена сети под нагрузкой) и ещё три новых пункта, см. «Критерий приёмки».

**Спринт 4 (гигиена):** 1.10–1.15, 2.3–2.5, 3.5–3.7, 4.1–4.4.
— 🟡 в коде; 1.14 частично (вторая половина невыполнима), 2.3 частично (Dart-сторона),
4.1 частично (Xcode сознательно не закреплён), 4.4 оказалась неверной находкой.

**Критерий приёмки:** сборка в Codemagic зелёная; на реальном устройстве —
DNS-leak тест, IPv6-leak тест, смена Wi-Fi↔LTE под нагрузкой без разрыва, отключение
через UI действительно возвращает интернет, туннель поднимается после перезагрузки
устройства (если включён on-demand).

> **Состояние критерия на 2026-07-28: выполнена первая часть из двух.**
>
> - ✅ **Сборка в Codemagic зелёная — build 136.** Прошли и три новых шага: `flutter:
>   3.44.4` доступен на раннере, гейт `flutter analyze && flutter test` отработал в обоих
>   пакетах, `codesign -d --entitlements` нашёл `application-groups` и в `Runner.app`, и
>   в `PlugIns/PacketTunnel.appex` экспортированного `.ipa`. Последнее закрывает
>   опасение из **1.9** и **2.5**: capability у обоих App ID есть, и entitlement
>   переживает пере-подпись при экспорте.
> - ⬜ **На устройстве не проверено ничего.** Компилятор не проверяет ни одного
>   поведенческого утверждения этого документа — и правильный, и сломанный туннель
>   собираются одинаково.
>
> **Что именно гонять на устройстве** — блок **T-iOS** раздела 2a в
> `docs/release-test-checklist.md`, восемь пунктов:
>
> | Пункт | Находки | На что смотреть в первую очередь |
> |---|---|---|
> | **T12** IPv6-leak | 1.7 | Ожидается **«нет IPv6»**, а не адрес ноды: v6 блокируется, а не проксируется. Самая заметная смена поведения — у TUN появился inet6-адрес |
> | **T13** DNS-leak | 1.8 | Ценность имеют прогоны **после смены сети** и **после фона**, а не сразу после коннекта |
> | **T14** Wi-Fi↔LTE под нагрузкой | 1.2 | Критерий по логу расширения, окно утечки руками не поймать |
> | **T15** отключение возвращает интернет | 1.1, N1 | Не только кнопка: sign-out и 402 идут тем же путём. При включённом on-demand это ещё и проверка N1 |
> | **T16** подъём после перезагрузки | 1.3, 1.6 | И что поднялся, и что **не на устаревшем конфиге** |
> | **T23** кил расширения (jetsam) | 1.3, 3.1, 3.2 | Сравнить частоту `JetsamEvent-*` с gvisor: `system`-стек ради этого и менялся. Здесь же проверять kill-switch × Clash API |
> | **T24** что осталось на диске | 2.1, 1.6 | Плюс поиск в **незашифрованном** бэкапе — это проверка `isExcludedFromBackup` |
> | **T25** support bundle | 2.4 | Приём с «маркерным» доменом: домен без пароля не выглядит секретом ни для одного regex |
>
> Отдельно, вне списка находок, но меняется поведение и без проверки на устройстве
> утверждать ничего нельзя: **скорость и стабильность на `system`-стеке** (3.2) и
> **MTU 1280** (3.4); **смена сервера** без прежней задержки 0.6 с (1.10); **счётчики
> трафика** на экране статистики (1.12) — они были структурно нулевыми, так что это
> новое поведение целиком, а не восстановленное.

> **Дополнено 2026-07-28 (вычитка):** восьми пунктов не хватало. Изменения поведения из
> **1.4, 1.5, 1.10, 1.11, 1.12, 1.13, 1.15, 2.2 (iOS), 2.3, 3.3, 3.4, 3.5, 3.6, 3.7** не
> были покрыты ни одним пунктом приёмки — включая те четыре, которые этот же документ
> абзацем выше называет непроверяемыми без устройства. Добавлены **T26–T36**: смена
> сервера, счётчики трафика, скорость на `system`-стеке, таймауты старта, sleep/wake за
> ночь, Clash API снаружи, первый коннект без `cache_file`, батарея и интервалы
> watchdog'а, kill-switch, fallback App Group, долгая сессия под гонками.
>
> Эти проверки оформлены пунктами **T12–T16, T23–T25 и T26–T36** в
> `docs/release-test-checklist.md` (раздел «2a. Приёмка технического аудита», блок
> «T-iOS»). Каждый пункт содержит явные «как проверить» и «что считается провалом»;
> T23 (кил расширения), T24 (что осталось на диске после logout) и T25 (support
> bundle) добавлены 2026-07-28 — под находки 1.3, 2.1/1.6 и 2.4 соответственно.
> Там же разобрано, почему довалидация Фазы 7 (`docs/ios-vpn-tunnel-spec.md`)
> пропустила 1.1, 1.2, 1.3, 1.6 и 2.1.
