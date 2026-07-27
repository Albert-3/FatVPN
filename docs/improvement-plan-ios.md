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

## Сводная таблица

| # | Файл:строка | Проблема | Критичность |
|---|---|---|---|
| 1.1 | `ExtensionPlatformInterface.swift:361-363` | `serviceStop` не отменяет туннель → blackhole при «connected» | **critical** |
| 1.2 | `ExtensionPlatformInterface.swift:180-188` | `clearDNSCache` снимает маршруты → утечка при смене сети; ошибки глотаются; `reasserting` залипает | **critical** |
| 1.3 | `SingboxMmPlugin.swift:598-608` | Нет on-demand / kill-switch: после jetsam-кила VPN не поднимается | **critical** |
| 1.4 | `PacketTunnelProvider.swift:41-50` | `runBlocking` без таймаута → зависание `openTun`/`serviceReload` | high |
| 1.5 | `PacketTunnelProvider.swift:55,70,143,220,251` | Гонка данных на `tunnelOptions` из 3+ потоков | high |
| 1.6 | `PacketTunnelProvider.swift:199-208,228-235` | Персист конфига не чистится → подъём на устаревшем сервере | high |
| 1.7 | `ExtensionPlatformInterface.swift:64-72,83-91` | Default-маршрут IPv6 без адресов → утечка IPv6 | high |
| 1.8 | `ExtensionPlatformInterface.swift:51-53` | DNS через `try?` + нет `matchDomains` → DNS-утечка | high |
| 1.9 | `PacketTunnelProvider.swift:85-92` | `fatalError` в расширении → крэш-луп | high |
| 1.10 | `SingboxMmPlugin.swift:489-517` | Гонка teardown (0.6 с) + «отравление» `vpnManager` invalid-объектом | medium |
| 1.11 | `SingboxMmPlugin.swift:269-316` | Гонка на `payload` + утечка `NWConnection` в ветке `.failed` | medium |
| 1.12 | `SingboxMmPlugin.swift:59-60,811-834` | Статистика трафика всегда 0, таймер 1 Гц вхолостую | medium |
| 1.13 | `PacketTunnelProvider.swift:369-385` | `sleep` без парного `wake` → пауза навсегда; watchdog «лечит» паузу | medium |
| 1.14 | `ExtensionPlatformInterface.swift:146-161` | Скан fd 0…1024, берётся первый `utun*` | low |
| 1.15 | `PacketTunnelProvider.swift:237-263` | Невалидируемая plist-ветка `handleAppMessage` (мёртвый код) | low |
| 2.1 | `PacketTunnelProvider.swift:187-190`, `SingboxMmPlugin.swift:386` | Креденшелы открытым текстом, попадают в бэкап, не удаляются | **high** |
| 2.2 | `singbox_config_builder.dart:129-134` | Clash API без `secret` на общем loopback:16756 | **high** |
| 2.3 | `TunnelHealthWatchdog.swift:329-354` | `external_controller` не валидируется → исходящий HTTP из NE | medium |
| 2.4 | `PacketTunnelProvider.swift:109-131`, `vpn_controller.dart:861-862` | Конфиг/домены утекают в UI-ошибку и support bundle | medium |
| 2.5 | `add_packet_tunnel_target.rb:47-52` vs `Runner.entitlements:9-12` | Комментарий противоречит entitlements (риск дрейфа профиля) | low |
| 3.1 | `PacketTunnelProvider.swift:124-129` | `Data(contentsOf:)` на неограниченном `stderr.log` → jetsam при ошибке | **high** |
| 3.2 | `singbox_inbound_builder.dart:68-75` | Стек всегда gvisor (настройка `system` не работает) → память/CPU | **high** |
| 3.3 | `singbox_config_builder.dart:122-127`, `PacketTunnelProvider.swift:149` | `cache_file` вкл. по умолчанию, `logMaxLines=3000` | medium |
| 3.4 | `singbox_inbound_builder.dart:32` | MTU 1100 захардкожен → −20% throughput | medium |
| 3.5 | `TunnelHealthWatchdog.swift:40`, `vpn_controller.dart:83` | Два health-контура, 60 с в фоне 24/7 → батарея | medium |
| 3.6 | `TunnelHealthWatchdog.swift:49,57` | 105 с до первого восстановления | low |
| 3.7 | `TunnelHealthWatchdog.swift:97-102` | `URLSession` без `urlCache = nil` в 50 МБ процессе | low |
| 4.1 | `codemagic.yaml:39-41,48,87-89,101` | `flutter: stable`, `xcode: latest`, gem без версии | medium |
| 4.2 | `codemagic.yaml:37-70` | Нет `flutter analyze`/`test` перед публикацией в TestFlight | medium |
| 4.3 | `codemagic.yaml:50-57,103-110` | Отладочный `-showBuildSettings` в релизном пайплайне | low |
| 4.4 | `codemagic.yaml:26,84` | `max_build_duration: 60` при 260 МБ LFS | low |

---

## 1. БАГИ

### 🔴 1.1 `serviceStop()` останавливает ядро, но не туннель — полная потеря связи при «connected»
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

### 🔴 1.2 Окно утечки трафика в `clearDNSCache()` — срабатывает ровно при смене сети
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

### 🔴 1.3 Не настроены on-demand правила: нет ни автоподъёма, ни kill-switch
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

### 🟠 1.4 `runBlocking` без таймаута → детерминированное зависание старта
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

### 🟠 1.5 Гонка данных на `tunnelOptions`
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

### 🟠 1.6 `stopTunnel` не чистит персистентный снапшот → подключение к устаревшему серверу
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

### 🟠 1.7 `NEIPv6Settings` с default-маршрутом без адресов → утечка IPv6
**Где:** `ExtensionPlatformInterface.swift:64-72` и `:83-91`

Конфиг по умолчанию идёт с `ipv6RouteMode = disable`
(`singbox_feature_settings.dart:152`) и `domain_strategy = ipv4_only`
(`singbox_config_builder.dart:67-69`), то есть sing-box вернёт пустой список
inet6-адресов. Тогда мы объявляем `::/0` без единого IPv6-адреса на интерфейсе.

**Почему плохо:** поведение недокументировано — iOS либо отвергает весь объект настроек
(тогда `openTun` падает), либо игнорирует IPv6-часть, и **весь IPv6-трафик идёт мимо
туннеля** на IPv6-enabled операторах. Это утечка реального адреса, которую тест
`dnsleaktest.com` из Фазы 7 спеки **не поймает** (он проверяет только DNS).

**Фикс:**

```swift
settings.ipv6Settings = ipv6Addresses.isEmpty ? nil : ipv6Settings
settings.ipv4Settings = ipv4Addresses.isEmpty ? nil : ipv4Settings
```

Плюс добавить в `docs/release-test-checklist.md` проверку `test-ipv6.com`.

### 🟠 1.8 DNS применяется «по возможности» и без `matchDomains`
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

### 🟠 1.9 `fatalError` в расширении при недоступности App Group
**Где:** `PacketTunnelProvider.swift:85-92`. Комментарий утверждает, что это build-time
баг, но контейнер бывает недоступен и в рантайме: дрейф provisioning-профиля (см. 2.5),
перевыпуск профиля, повреждённый контейнер.

**Почему плохо:** `fatalError` внутри NE = крэш-луп. iOS применяет к падающим
расширениям экспоненциальный backoff и в итоге перестаёт их запускать — VPN не
поднимется вообще, и диагностику записать некуда (писалка сама живёт в App Group).
Пользователь получает «Connecting» → таймаут без единой подсказки.

**Фикс:** fallback на `temporaryDirectory` для `basePath`/`workingPath` + нормальный
error-путь через `startTunnel`, чтобы туннель хотя бы поднялся.

### 🟡 1.10 `stopVpn`/`restartVpn`: гонка с `.disconnecting` и «отравление» `vpnManager`
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

### 🟡 1.11 `pingServer`: гонка данных на `payload` + утечка `NWConnection`
**Где:** `SingboxMmPlugin.swift:269-316`

`payload` пишется из `stateUpdateHandler` (очередь `singbox_mm.ping`) и одновременно из
глобальной очереди по таймауту — гонка на Swift-словаре. В ветке `.failed` нет
`connection.cancel()` → `NWConnection` живёт до `deinit`; при переборе всех нод в
`_pickBestNode` (`vpn_controller.dart:841-852`) это десятки подвисших соединений на
каждый цикл автопереключения.

**Фикс:** в расширении та же функция написана **правильно**
(`PacketTunnelProvider.swift:318-363`: единая серийная очередь, флаг `settled`,
`cancel()` в `settle`) — перенести эту реализацию сюда.

### 🟡 1.12 Статистика трафика на iOS всегда нулевая, но таймер тикает каждую секунду
**Где:** `SingboxMmPlugin.swift:59-60, 811-824, 826-834`

`uplinkBytes`/`downlinkBytes` нигде не инкрементируются — только обнуляются в
`handleStatusChange` (`:668-669`). На iOS счётчик трафика в UI всегда 0, при этом канал
`singbox_mm/stats` гоняет событие каждую секунду, вечно, даже когда экран статистики
закрыт (`onListen` вызывается один раз, таймер не гасится в фоне).

**Фикс:** тянуть реальные цифры из Clash API расширения через `sendProviderMessage`
(команда `"stats"` рядом с `"measureLatency"`, `PacketTunnelProvider.swift:265-276`) —
sing-box отдаёт их на `/traffic` и `/connections`. Интервал поднять до 2–3 с, таймер
глушить по `applicationDidEnterBackground`.

### 🟡 1.13 `sleep()` может оставить ядро в паузе навсегда
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

### 🟢 1.14 Скан fd 0…1024 и выбор первого `utun*`
**Где:** `ExtensionPlatformInterface.swift:146-161`. Метод канонический, но диапазон
захардкожен вместо `getdtablesize()`, и возвращается первый `utun*` без проверки, что
имя совпадает с только что созданным интерфейсом. **Фикс:** `getdtablesize()` + сверять
ожидаемое имя интерфейса, а не только префикс.

### 🟢 1.15 `handleAppMessage` не проверяет тип сообщения
**Где:** `PacketTunnelProvider.swift:237-263`. Не-JSON сообщение трактуется как plist со
start-options и **немедленно перезапускает сервис с новым конфигом**, без валидации.
Dart-слой этим путём не пользуется — мёртвый, но исполняемый код. **Фикс:** удалить
plist-ветку или обернуть в явную команду `{"command":"reload",...}` с проверкой через
`LibboxCheckConfig`.

---

## 2. БЕЗОПАСНОСТЬ

### 🟠 2.1 Креденшелы открытым текстом в трёх местах, переживают logout

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

### 🟠 2.2 Clash API слушает loopback **без `secret`** — любое приложение управляет VPN
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

### 🟡 2.3 `external_controller` из конфига не валидируется → исходящий HTTP из расширения
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

### 🟡 2.4 Диагностика утекает конфиг и домены в UI и в support bundle
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

### 🟢 2.5 Комментарий в `add_packet_tunnel_target.rb` расходится с entitlements
**Где:** `app/ios/tool/add_packet_tunnel_target.rb:47-52` утверждает «App Group
entitlement is deliberately NOT added here yet», а `app/ios/Runner/Runner.entitlements:9-12`
App Group **содержит**, и скрипт (`:59-61`) прописывает этот файл в
`CODE_SIGN_ENTITLEMENTS`. Если App ID Runner'а действительно не имеет capability App
Groups, подпись либо упадёт, либо entitlement тихо вырежут → `containerURL(...)` вернёт
nil → `readLastError` отдаст `"APP_GROUP_UNAVAILABLE"` (`SingboxMmPlugin.swift:714`) и
вся диагностика мертва. **Фикс:** привести комментарий в соответствие; в CI добавить
`codesign -d --entitlements :- build/.../Runner.app | grep application-groups`.

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

### 🟠 3.1 Чтение `stderr.log` целиком в память ровно тогда, когда памяти уже нет
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

### 🟠 3.2 TUN-стек жёстко `gvisor`, альтернативы нет
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

### 🟡 3.3 `cache_file` включён по умолчанию, `logMaxLines = 3000`
**Где:** `singbox_config_builder.dart:122-127` (`'enabled': !settings.advanced.memoryLimit`)
+ `singbox_feature_settings.dart:107`. `buildFeatureSettings()`
(`connection_settings_controller.dart:414-438`) **не передаёт `advanced:` вообще** →
`memoryLimit = false` → `cache_file` и `store_fakeip` включены на iOS всегда. Плюс
`setupOptions.logMaxLines = 3000` (`PacketTunnelProvider.swift:149`) — libbox держит
3000 строк лога в памяти расширения. `LibboxSetMemoryLimit(true)` (`:159`) выставлен
правильно, но он лишь подстраивает GOGC, а не отменяет расходы выше.

**Фикс:** на iOS форсировать `AdvancedOptions(memoryLimit: true)` в
`buildFeatureSettings()` (по `defaultTargetPlatform`), снизить `logMaxLines` до 300–500.

### 🟡 3.4 Жёстко зашитый MTU 1100
**Где:** `singbox_inbound_builder.dart:32`. 1100 очень консервативно (типовой безопасный
VPN MTU 1280–1420). ~20% полезной нагрузки теряется на заголовках относительно 1400;
больше пакетов → больше проходов через gvisor → выше CPU, ниже скорость, выше расход
батареи. **Фикс:** поднять дефолт до 1280 (безопасно и для IPv6-минимума), вывести в
настройки; для WireGuard считать по формуле от оверхеда транспорта.

### 🟡 3.5 Два независимых health-контура работают одновременно

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

### 🟢 3.6 105 секунд до первого восстановления
**Где:** `TunnelHealthWatchdog.swift:49` (`firstCheckDelay = 45`) и `:57`
(`failuresBeforeRecovery = 2`) → 45 + 60 = минимум 105 с от старта нерабочего туннеля
до восстановления, всё это время приложение показывает `connected`. **Фикс:** снизить
`firstCheckDelay` до 15–20 с — одного TLS-хендшейка достаточно, чтобы понять, работает
ли outbound, и проверка одноразовая (расход не растёт).

### 🟢 3.7 `URLSession` в watchdog'е без ограничения кеша
**Где:** `TunnelHealthWatchdog.swift:97-102` — `URLSessionConfiguration.ephemeral`
создаёт in-memory URL-кеш (несколько МБ) внутри процесса с лимитом 50 МБ.
**Фикс:** `configuration.urlCache = nil`, `configuration.httpShouldSetCookies = false`.

---

## 4. CI / codemagic.yaml

### 🟡 4.1 Незакреплённый тулчейн — сборка нереспроизводима
**Где:** `codemagic.yaml:39-41, 87-89` (`flutter: stable`, `xcode: latest`,
`cocoapods: default`) + `:48`, `:101` (`gem install xcodeproj --no-document` без версии).
Обновление Xcode или Flutter на стороне Codemagic ломает релизную сборку без изменений
в репозитории — для приложения с Network Extension особенно болезненно (ломается
подпись/entitlements, а не код). Незакреплённый `xcodeproj` gem правит
`Runner.xcodeproj` (`add_packet_tunnel_target.rb:151`) — смена мажорной версии молча
изменит структуру проекта. **Фикс:** `flutter: 3.35.x`, `xcode: 16.2`,
`gem install xcodeproj -v 1.27.0`.

### 🟡 4.2 Нет quality gate перед публикацией в TestFlight
**Где:** `codemagic.yaml:37-70` (workflow `ios-release`) — шаги LFS pull → pub get →
add target → diagnose → pod install → use-profiles → build ipa → publish. **Нет ни
`flutter analyze`, ни `flutter test`.** Билд уезжает в TestFlight при любом состоянии
кода. **Фикс:** добавить перед сборкой `flutter analyze --fatal-infos && flutter test`.

### 🟢 4.3 Отладочный шаг в релизном пайплайне
`codemagic.yaml:50-57` (дубль `:103-110`) — `xcodebuild -showBuildSettings` с
`-configuration Debug`, ~30–60 с на каждый билд, всегда `|| true`. Убрать из
`ios-release` или вынести в отдельный debug-workflow.

### 🟢 4.4 `max_build_duration: 60` при 260 МБ LFS
`codemagic.yaml:26, 84` — при холодном LFS-кеше (два бинаря по ~150 МБ) риск упереться
в лимит. Поднять до 90–120 для `ios-release`.

---

## Рекомендуемый порядок работ

**Спринт 1 (безопасность + blackhole-баги):** 2.2 (secret для Clash API) → 1.1 → 1.2 →
2.1 → 3.1. Пять точечных правок, закрывающих самые тяжёлые утечки и самые неприятные
для пользователя отказы.

**Спринт 2 (устойчивость):** 1.3 (on-demand) → 1.4 → 1.5 → 1.6 → 1.9.

**Спринт 3 (утечки трафика + производительность):** 1.7 → 1.8 → 3.2 → 3.3 → 3.4.
Обязательно расширить `docs/release-test-checklist.md` проверками IPv6-leak и
«выключить Wi-Fi во время активной загрузки»: текущая валидация Фазы 7
(`docs/ios-vpn-tunnel-spec.md:241-253`) проверяла только DNS-leak и сам факт выживания
при смене сети, поэтому пункты 1.2 и 1.7 через неё прошли незамеченными.

**Спринт 4 (гигиена):** 1.10–1.15, 2.3–2.5, 3.5–3.7, 4.1–4.4.

**Критерий приёмки:** сборка в Codemagic зелёная; на реальном устройстве —
DNS-leak тест, IPv6-leak тест, смена Wi-Fi↔LTE под нагрузкой без разрыва, отключение
через UI действительно возвращает интернет, туннель поднимается после перезагрузки
устройства (если включён on-demand).
