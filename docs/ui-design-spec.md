# FatVPN — UI-спека (Claude Design)

> Источник: `Designe/FatVPN.pdf` (экспорт из Claude Design).
> Соответствует экранам из раздела 7 `VPN-App-Project.md`. Используется как
> референс для вёрстки Flutter-экранов в День 3.

## 1. Home — Disconnected

- Шапка: логотип **FatVPN** (слева), иконка настроек-шестерёнки (справа)
- Селектор локации: иконка глобуса, «LOCATION» / «Best server», индикатор
  сигнала, шеврон `>`
- Центр: круглая кнопка power — серая (неактивна)
- Под кнопкой: «● Disconnected», подпись «Your connection is not protected»
- Низ: «Best servers» + «See all», горизонтальный ряд флагов
  (Germany, Netherlands, Japan)

## 2. Home — Connected

- Селектор локации превращается в плашку с текущим сервером:
  флаг + «Connected to» / «Germany · Frankfurt» + индикатор сигнала
- Кнопка power — мятно-зелёная (`#34D399`-подобный), со свечением
- Под кнопкой: «● Connected», таймер сессии (`00:12:48`), подпись
  «SESSION TIME»
- Ряд «Best servers» — текущая страна подсвечена (Germany, зелёный текст)

## 3. Choose location

- Заголовок «Choose location», кнопка назад, иконка refresh справа
- Верхний блок: «Best server», бейдж **ACTIVE** (зелёный), подпись
  «Automatic · fastest & nearest», шеврон раскрытия
- Секция «ALL LOCATIONS»: список стран — флаг, название, кол-во серверов
  (мелким шрифтом под названием), индикатор сигнала справа
  (Netherlands, Sweden, Finland, Germany и т.д.)
- Germany развёрнута — под ней список конкретных нод с пингом в мс:
  `de-fra-01 76ms`, `de-fra-02 84ms`, `de-fra-03 83ms`, `de-fra-04 86ms`,
  `de-fra-05 87ms`

## 4. Settings

- Заголовок «Settings», кнопка назад
- **MANAGE ACCOUNT**: строка с ключом/токеном (обрезанный вид,
  `20e4f21d-54B7-4425-9112-...`), иконка копирования; подпись
  «Expires in 5 days»
- **CONNECTION SETTINGS**:
  - DNS Server → «Cloudflare (1.1.1.1)»
  - Network stack → «Mixed» (терминология sing-box, подтверждает референс)
- **ROUTING**:
  - «Split tunneling settings» — «Choose apps that bypass the VPN» →
    отдельный экран (см. п.5)
- **SYSTEM**:
  - Language → «English»
- **LOGS MANAGEMENT**:
  - «Application logs» — «Share diagnostics with support»
  - Кнопки «Clear» / «Send» (Send — акцентная зелёная)
- **Кнопка «Sign out»** (красная, во всю ширину) — **закреплена у нижнего края экрана
  поверх** прокручиваемого контента (фон + верхняя разделительная линия), всегда видна;
  секция логов скроллится под ней. `signOut()` → возврат на первый экран (онбординг).

## 5. Split tunneling

- Заголовок «Split tunneling», тумблер вкл/выкл в шапке (включён)
- Подпись «Apps that bypass the VPN»
- Список «SELECTED IN LIST»: «Bypassing tunnel» с шевроном
- Пример записи: «Russian services» с иконкой удаления (корзина)
- Низ экрана: кнопка «+ Add» (акцентная зелёная, во всю ширину)

## Цвета / стиль (по скриншотам)

- Фон: тёмно-синий/почти чёрный (`#0B1622`-подобный)
- Акцент: мятно-зелёный (соответствует логотипу, `#86F0C4` → `#34D399`)
- Карточки: чуть светлее фона, скруглённые углы
- Активные бейджи/кнопки — заливка акцентным зелёным с тёмным текстом
- Статус-бар в стиле iOS (9:41, сигнал, батарея) — макеты сделаны под iPhone

## Как это ложится на реализацию (День 3, Flutter)

- 4 экрана из спеки → 4 маршрута: `HomeScreen`, `ChooseLocationScreen`,
  `SettingsScreen`, `SplitTunnelingScreen`
- Поля `Settings` напрямую мапятся на функциональность sing-box:
  DNS → блок `dns`, Split tunneling → `route.rules`, Network stack →
  `system/gvisor/mixed` (см. раздел 7 основного документа)
- Таймер сессии и статус подключения — состояние из platform channel
  (нативный мост, День 4-5)
- Список нод с пингом (`de-fra-01 76ms`) — требует замера пинга на
  клиенте по адресам из `GET /servers` (см. `api-contract.md`)
