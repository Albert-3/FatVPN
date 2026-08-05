# Подача в App Store — рабочий документ

> Начат 2026-08-06 по команде «начинаем деплой в App Store». Источник требований —
> `store-compliance.md` (правило трёх мест: политика = форма стора = код); этот
> документ — про сам процесс подачи и его материалы. Google Play — отдельным
> заходом, здесь только Apple.
>
> Текущее состояние доставки: Codemagic `ios-release` → TestFlight, **только
> внутренняя группа** (ASC: Hakob Abgaryan, app id 6792885157, `submit_to_testflight`
> см. `codemagic.yaml`). Для App Store внешний TestFlight не обязателен — подача
> идёт с того же билда.

---

## 0. Два вопроса, без ответа на которые подача не начинается (Роберту)

1. ⛔ **Тип аккаунта Apple Developer — только Organization.** Guideline 5.4 прямым
   текстом: приложения-VPN принимаются только от аккаунтов-организаций. Individual —
   гарантированный отказ, и это не лечится текстами. **Связка со вчерашним
   вопросом про гражданина Армении:** если нового человека регистрируют под
   стор — регистрировать надо юрлицо (Organization, нужен D-U-N-S номер, процесс
   занимает недели), а не физлицо. Проверить и текущий аккаунт (Hakob Abgaryan —
   имя физлица, что настораживает): Membership в developer.apple.com → Entity Type.
   Если Individual — публиковать VPN с него нельзя, TestFlight работал потому,
   что внутреннее тестирование 5.4 не проходит.
2. ⛔ **Данные оператора для политики конфиденциальности.** На живом
   `https://api.fatklyuchi.space/privacy` до сих пор плейсхолдеры `[[ОПЕРАТОР]]`,
   `[[КОНТАКТ]]`, `[[ЮРИСДИКЦИЯ]]` — ревьюер увидит документ, который сам себя
   объявляет незаполненным. Нужны: юридическое имя владельца сервиса, контактный
   e-mail, юрисдикция. Час работы после ответа: вписать в оба языка + редеплой
   Caddy.

Ещё два решения заказчика — не блокируют начало, но нужны до кнопки Submit:

3. **География.** Apple по требованию РКН удаляет VPN из российского App Store.
   Если целевой рынок Россия — решить: подаёмся во все страны и принимаем риск
   снятия в РФ, или строим распространение на TestFlight/веб. Ответ влияет на
   список стран в ASC → Pricing and Availability.
4. **Guideline 3.1.1.** Ссылка на Telegram-бота (где оплата) осталась в
   приложении. Риск на усмотрение ревьюера; полностью снимает его только IAP.
   Вариант «оставляем и смотрим на первый отзыв ревью» — легитимный, но решение
   за заказчиком.

---

## 1. Порядок подачи (когда §0 отвечен)

| # | Шаг | Кто |
|---|---|---|
| 1 | Ответы §0.1–0.2 → политика без плейсхолдеров на проде | Роберт → мы |
| 2 | Проверить «no logs» узлов (§1 `store-compliance.md`) — глазами посмотреть логи хотя бы одной ноды и настройки Xray; при расхождении править политику | нужен SSH к ноде (Роберт) |
| 3 | Демо-ключ для ревьюера (§4) — завести, проверить путь «вставить ключ» на чистой установке | мы |
| 4 | Скриншоты (§5) | владелец iPhone + мы |
| 5 | Заполнить листинг в ASC (§2), App Privacy (§3), Review Notes (§4) | мы (нужен доступ в ASC) |
| 6 | Формально прогнать TA17 на устройстве (пиннинг: приложение работает на живом домене) — де-факто уже работает во всех device-прогонах виджета с build ≥ 245, но в чек-листе галочки нет | владелец устройства |
| 7 | `codemagic.yaml`: релизный workflow на подачу (см. §6) | мы |
| 8 | Submit for Review | мы/Роберт |

---

## 2. Листинг — черновики текстов

**Имя:** `FatVPN` (уже стоит в бандле).
**Subtitle (30 симв., RU):** `Быстрый и приватный VPN`
**Категория:** Utilities (вторичная — Productivity). **Возраст:** 4+ (по анкете
рейтинга «неограниченный доступ в интернет» может поднять до 17+ — отвечать
честно, у VPN это штатно).

**Описание (RU), с обязательной по 5.4 фразой о данных:**

> FatVPN — быстрый VPN без лишнего.
>
> • Подключение одной кнопкой; приложение само выбирает быстрейший сервер, или выберите страну вручную.
> • Сплит-туннелинг: выбирайте, какие приложения идут через VPN (по доменам и адресам на iOS).
> • Защита от трекинга: одним переключателем блокируются домены трекеров и аналитики внутри туннеля.
> • Виджет на домашнем экране: подключение и отключение, не открывая приложение.
> • Никакой рекламы, аналитики и сторонних SDK.
>
> Конфиденциальность: приложение не ведёт журнал посещённых сайтов и содержимого трафика. Единственные данные, которые мы обрабатываем, — случайный идентификатор установки (для пробного периода и лимита устройств), данные вашего ключа доступа и объём трафика. Подробности: https://api.fatklyuchi.space/privacy/ru
>
> Для работы приложения нужен ключ доступа или пробный период (2 дня).

**Описание (EN)** — перевод того же, фраза о данных обязательна:

> FatVPN is a fast, no-nonsense VPN.
>
> • One-tap connect; the app picks the fastest server, or choose a country manually.
> • Split tunneling: decide which traffic goes through the VPN (by domain/IP on iOS).
> • Tracker protection: a single switch blocks tracker and analytics domains inside the tunnel.
> • Home-screen widget: connect and disconnect without opening the app.
> • No ads, no analytics, no third-party SDKs.
>
> Privacy: the app does not log the sites you visit or the contents of your traffic. The only data we process is a random installation identifier (for the free trial and the device limit), your access-key data, and traffic volume. Details: https://api.fatklyuchi.space/privacy
>
> An access key or the 2-day free trial is required.

**Ключевые слова (100 симв.):** `vpn,впн,прокси,proxy,безопасность,приватность,трекеры,fast vpn,secure,private`

**URLs:**
- Privacy Policy: `https://api.fatklyuchi.space/privacy` (RU-версия указывается в описании);
- Support URL: ⬜ страницы нет — сделать `https://api.fatklyuchi.space/support`
  (статическая страница рядом с privacy: контакт e-mail + Telegram; полчаса работы,
  Caddy наш);
- Marketing URL: необязателен, пропускаем.

---

## 3. App Privacy в ASC — ответы (из `store-compliance.md` §2.2, менять нельзя)

- Data Used to Track You: **ничего**.
- Data Linked to You: **Identifiers → Device ID**, purpose **App Functionality**.
- Data Not Linked to You: **ничего**.
- Всё остальное: Not Collected.

Совпадает с `PrivacyInfo.xcprivacy` всех трёх бандлов — проверено CI.

---

## 4. App Review Notes + демо-доступ

У ревьюера нет Telegram — путь «вставить ключ» должен работать автономно.
Механика демо-ключа: ключ создаётся в боте/BFF (`/internal/tokens`) на подписку
с далёким сроком; проверить на чистой установке, что вставка кода даёт доступ
без Telegram. Завести **перед самой подачей** (не сейчас — чтобы не протух
контроль его существования) и записать сюда код.

Черновик Review Notes (EN):

> FatVPN is a subscription VPN service; keys are normally purchased through our
> Telegram bot. For review, use the demo access key below — no Telegram account
> or purchase is needed:
>
> 1. Launch the app → tap "I have a key" → paste: `<DEMO-KEY>`.
> 2. Tap the power button to connect. The app selects the fastest server; you
>    can also pick a country from the list.
> 3. A free 2-day trial is also available from the same screen ("Try for free").
>
> The app uses NetworkExtension (NEPacketTunnelProvider). No account creation,
> no personal data is collected beyond a random installation identifier (see
> App Privacy). Payments happen outside the app and the app contains no
> purchase functionality.

---

## 5. Скриншоты (нужен iPhone)

ASC требует наборы 6.9″ (iPhone 16 Pro Max / 15 Pro Max) и 6.5″; 6.9″ можно
переиспользовать для 6.5″. Минимум 3, лучше 5:

1. Главный экран, подключено (зелёное состояние, страна, таймер);
2. Список серверов со странами и пингом;
3. Сплит-туннелинг;
4. Настройки с «Защитой от трекинга»;
5. Виджет на домашнем экране (жив и подтверждён устройством).

Русские скриншоты для RU-локали листинга, английские для EN. Снимать на
iPhone 15 (6.1″ тоже принимается, но 6.9″ обязателен — если ни у кого нет
Max-устройства, снять в симуляторе на Mac у Codemagic нельзя интерактивно;
практичный путь — попросить владельца iPhone 15 Pro Max/16 Pro Max из
тестировщиков, либо собрать через `simctl` скрипт в CI и забрать артефактами).

---

## 6. Codemagic: что меняется для подачи

Сейчас `ios-release` публикует только в TestFlight (внутренняя группа). Для
подачи в App Store добавить в publishing-секцию releаse-workflow
`submit_to_app_store: true` (Codemagic сам создаст версию в ASC) **или** — что
проще контролировать в первый раз — оставить как есть, выбрать готовый билд в
ASC руками и заполнить всё в веб-интерфейсе. Рекомендация: первый релиз — руками
в ASC, автоматизация — после первого одобрения.

---

## 7. Риски ревью, принятые осознанно

| Риск | Статус |
|---|---|
| 5.4 Organization | ⛔ вопрос §0.1 — до ответа подача невозможна |
| Политика с плейсхолдерами | ⛔ вопрос §0.2 |
| 3.1.1 ссылка на бота | решение заказчика, §0.4 |
| «No logs» не проверено на узлах | шаг §1.2 |
| РКН / доступность в РФ | решение заказчика, §0.3 |
| Отсутствие Support URL | закрывается страницей /support, §2 |
