# FatVPN — план технических доработок (сводка)

> **Что это.** Полный технический аудит проекта от 2026-07-27 по коду ветки `master`,
> оформленный как техзадание для исполнителя (Claude Opus). Охвачены три части системы:
> BFF (.NET 10), Flutter-приложение с Android-нативом, iOS (Network Extension + sing-box).
>
> **Как пользоваться.** Каждая находка имеет номер, файл со строкой, объяснение «почему
> это плохо» и предлагаемое исправление. Номера стабильны — на них можно ссылаться в
> задачах и коммитах. Порядок работ предложен в конце каждого документа.

| Документ | Область | Находок |
|---|---|---|
| [improvement-plan-bff.md](improvement-plan-bff.md) | Backend .NET 10 (`backend/`) | 6 critical, 9 high, 10 medium + low |
| [improvement-plan-app-android.md](improvement-plan-app-android.md) | Flutter + Android (`app/lib`, `app/android`, `app/packages/singbox_mm`) | 5 critical, 12 high, 20 medium, 8 low |
| [improvement-plan-ios.md](improvement-plan-ios.md) | iOS (`app/ios`, PacketTunnel NE) | 3 critical, 7 high, 12 medium, 8 low |

> ⚠️ Ранее существовавший `docs/security-audit.md` (2026-07-25) **добавлен в `.gitignore`**
> и не попадает в репозиторий. Все его пункты учтены и перенесены в
> `improvement-plan-bff.md` (S1–S10), так что для работы он не нужен.

---

## Топ-10: что чинить в первую очередь

Отсортировано по «ущерб × вероятность», а не по формальной критичности.

| # | Что | Где | Почему первым |
|---|---|---|---|
| 1 | **HTTP вместо HTTPS** | `api_config.dart:4`, `Program.cs:61-65` | Refresh-токен на 90 дней и вся подписка (UUID, пароли) идут открытым текстом. Перехват = полный угон аккаунта. Для VPN-продукта разрушает саму модель угроз |
| 2 | **Release подписан debug-ключом** | `build.gradle.kts:31-34` | Публично известный ключ: подмена приложения через sideload + доступ к signature-permission. В Google Play не загрузить |
| 3 | **APK ~236 МБ** | `app/android/app/build.gradle.kts` | Лимит Play — 100 МБ APK / 200 МБ AAB. Сборка физически не публикуется. x86/x86_64 = 54% веса и нужны только эмулятору |
| 4 | **Clash API без секрета на loopback** | `singbox_config_builder.dart:129-133` | Любое приложение на устройстве читает историю доменов пользователя в реальном времени и может выключить проксирование. Общая дыра Android + iOS |
| 5 | **Потеря ротированного refresh-токена** | `auth_controller.dart:204` + `AuthController.cs:62-113` | `unawaited(save)` + reuse-detection на сервере = пользователь теряет платную подписку после неудачно совпавшего kill процесса. Чинится с обеих сторон |
| 6 | **`serviceStop` не отменяет туннель (iOS)** | `ExtensionPlatformInterface.swift:361-363` | Интернет пропадает целиком, приложение показывает «connected». Выход только ручным тоглом |
| 7 | **`clearDNSCache` снимает маршруты (iOS)** | `ExtensionPlatformInterface.swift:180-188` | Окно утечки трафика мимо VPN ровно при смене Wi-Fi↔LTE — самый частый сценарий |
| 8 | **Гонки на BFF: `/pair/status`, `/auth/refresh`** | `PairController.cs:78-93`, `AuthController.cs:62-113` | Одноразовый код выдаёт две сессии; reuse-detection обходится гонкой. Проявляется как «случайные разлогины» |
| 9 | **Нет rate limiting** | `Program.cs` | `/trial` создаёт реального пользователя в панели на каждый вызов, без лимита и с обходимым anti-abuse. Порт публичный |
| 10 | **Пустой `attestationToken` = чужой триал** | `TrialController.cs:25` | `{"attestationToken":""}` даёт валидную сессию к триалу первого клиента. Одна строка валидации |

---

## Сквозные темы (чинить согласованно на двух сторонах)

Три пары находок нельзя закрывать по отдельности — иначе фикс на одной стороне ломает
или не даёт эффекта на другой:

**HTTPS.** BFF S2 (`UseHttpsRedirection` включён только в Development — условие
инвертировано) + Android §1.1 (`usesCleartextTraffic="true"`) + iOS (в `Info.plist` нет
`NSAppTransportSecurity`, то есть **iOS-сборка вообще не достучится до BFF по HTTP** —
скрытый блокер релиза). Плюс BFF S8: без `ForwardedHeaders` за Caddy редирект даст цикл,
а per-IP rate limiter схлопнет всех клиентов в один бакет.

**Refresh-токены.** Приложение §2.1 (сохранять на диск до смены состояния в памяти) +
BFF B2 (атомарный claim + **grace window ~10-30 с** для повторного предъявления только
что отротированного токена). Без grace window гонки мобильного клиента будут и дальше
приводить к отзыву семьи. Сюда же приложение §3.4: `AuthSession.expiresAt` — это срок
**подписки**, а не токена, поэтому приложение рефрешит по десятку раз в день на ровном
месте; BFF должен отдавать `accessTokenExpiresAt` отдельным полем.

**Clash API.** Один фикс в общем Dart-файле `singbox_config_builder.dart` закрывает
Android §1.6 и iOS 2.2, но требует парных правок в трёх потребителях:
`VpnTunnelHealthProbe.kt:154`, `TunnelHealthWatchdog.swift:311-323` и
`vpn_controller.dart:458-482`. Плюс iOS 2.3 — валидировать, что `external_controller`
указывает на loopback (иначе сетевое расширение шлёт запросы на произвольный хост).

Отдельно: файл `singbox_inbound_builder.dart` тоже общий — правка TUN-стека (iOS 3.2,
`system` молча превращается в `gvisor`) затронет Android, это нужно проверить отдельно.

---

## Порядок работ

**Этап 1 — блокеры релиза.** Всё, без чего приложение нельзя опубликовать:
HTTPS-домен для BFF (BFF S2, S4, S8), release keystore, AAB с `abiFilters`,
`allowBackup="false"`, `await` при сохранении refresh-токена.

**Этап 2 — безопасность.** Clash API secret, rate limiting на BFF, валидация
`attestationToken`, certificate pinning, `stderr.log` из внешнего хранилища, хранение
конфига iOS в Keychain, санитайзер диагностики перед показом и шарингом.

**Этап 3 — корректность.** Гонки на BFF (`ExecuteUpdateAsync` вместо read-modify-write),
iOS blackhole-баги (1.1, 1.2, 1.4, 1.5), Android `_ensureInitialized` и disconnect при
sign-out, нормализация `DateTimeOffset` от бота.

**Этап 4 — производительность.** Кеш `/servers` и индексы БД на BFF, параллельные пинги
и единый `ApiClient` в приложении, TUN-стек и MTU на iOS, тик уведомления и перерисовки UI.

**Этап 5 — гигиена и долг.** Локализация сообщений, Testcontainers для тестов на
параллелизм, закрепление тулчейна в Codemagic, quality gate перед TestFlight,
адаптивные интервалы health-check.

---

## Что уже сделано хорошо (не переделывать)

Аудит отдельно зафиксировал сильные места, чтобы исполнитель не «улучшил» работающее:

- **BFF:** refresh-токены хранятся хэшами, ротация + reuse-detection, constant-time
  сравнение bot-секрета, CSPRNG везде, одноразовые pairing-коды, чистая семантика
  401 vs 402, `CancellationToken` пробрасывается сквозь все слои.
- **Android:** защита broadcast'ов signature-permission + `RECEIVER_NOT_EXPORTED`,
  `VpnServiceLiveness` (решает «на диске connected, а процесс убит»), атомарная запись
  конфига с `fsync` + 0600, `AutoSwitchPolicy` со strikes и cooldown (покрыта тестами),
  различение `UNKNOWN` и `DEAD` в health-probe, watchdog на `Handler` а не `AlarmManager`
  (устройство не будится), `WakeLock` не используется вовсе.
- **iOS:** архитектура канонически верная (NEPacketTunnelProvider + Libbox CommandServer
  + `getsockopt(UTUN_OPT_IFNAME)`), `tcpLatencyMs` в расширении написан правильно
  (серийная очередь, `settled`-guard, `cancel()` во всех ветках) — его и надо перенести
  в плагин. Секретов в `codemagic.yaml` и в git нет: подпись через интеграцию Codemagic.

---

## Проверка результата

- **BFF:** `dotnet build` + `dotnet test` зелёные; добавлены интеграционные тесты на
  параллельные `/pair/status`, `/auth/refresh`, `/trial` (текущие тесты на EF InMemory
  **не ловят ни одну гонку** — см. BFF B11).
- **Приложение:** `flutter analyze` без ошибок, `flutter test` зелёный, release-сборка
  укладывается в лимиты Play.
- **На устройстве:** подключение, смена сервера, sign-out при активном туннеле (туннель
  должен опуститься), холодный старт после kill процесса во время рефреша.
- **iOS на устройстве:** DNS-leak, **IPv6-leak** (новый пункт — текущая валидация Фазы 7
  его не проверяла, поэтому находки 1.2 и 1.7 прошли незамеченными), смена Wi-Fi↔LTE под
  нагрузкой, отключение через UI действительно возвращает интернет.
- Соответственно расширить `docs/release-test-checklist.md`.
