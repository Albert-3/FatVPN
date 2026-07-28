enum AppLanguage { en, ru }

class Strings {
  const Strings({
    required this.notSignedIn,
    required this.couldNotReachServer,
    required this.retry,
    required this.select,
    required this.settingsTitle,
    required this.manageAccount,
    required this.connectionSettings,
    required this.dnsServer,
    required this.networkStack,
    required this.autoReconnect,
    required this.autoReconnectSubtitle,
    required this.killSwitch,
    required this.killSwitchSubtitle,
    required this.appliesOnNextConnection,
    required this.customDnsHint,
    required this.routing,
    required this.splitTunnelingSettings,
    required this.splitTunnelingSubtitle,
    required this.system,
    required this.language,
    required this.account,
    required this.signOut,
    required this.currentKey,
    required this.keyCopied,
    required this.connectKey,
    required this.connectKeyHint,
    required this.buySubscription,
    required this.contactSupport,
    required this.logsManagement,
    required this.applicationLogs,
    required this.shareDiagnostics,
    required this.clear,
    required this.send,
    required this.logsCleared,
    required this.noLogsToShare,
    required this.active,
    required this.expired,
    required this.expiresInDays,
    required this.expiresInHours,
    required this.connectedTo,
    required this.location,
    required this.bestServer,
    required this.bestServerAuto,
    required this.activeBadge,
    required this.connected,
    required this.connecting,
    required this.disconnected,
    required this.sessionTime,
    required this.connectionNotProtected,
    required this.tunnelNotPassingTraffic,
    required this.noUsableServers,
    required this.bestServers,
    required this.seeAll,
    required this.chooseLocation,
    required this.allLocations,
    required this.serversCount,
    required this.unreachable,
    required this.whitelistLocations,
    required this.switchedToFasterServer,
    required this.openBotTitle,
    required this.openBotSubtitle,
    required this.trialUsedTitle,
    required this.trialUsedSubtitle,
    required this.trialResumableTitle,
    required this.trialResumableSubtitle,
    required this.connectWithTelegram,
    required this.pairingWaiting,
    required this.pairingScanHint,
    required this.pairingCodeExpired,
    required this.getNewCode,
    required this.haveKeyTitle,
    required this.enterKeyHint,
    required this.submitKey,
    required this.tryFreeTrial,
    required this.continueTrial,
    required this.settingUpFreeAccess,
    required this.trialAlreadyUsed,
    required this.trialNoCapacity,
    required this.trialFailed,
    required this.keyBoundToOtherDevice,
    required this.keyNotFound,
    required this.deepLinkKeyTitle,
    required this.deepLinkKeyBody,
    required this.subscriptionExpiredTitle,
    required this.subscriptionExpiredSubtitle,
    required this.renewViaTelegram,
    required this.checkAgain,
    required this.splitTunneling,
    required this.appsBypassVpn,
    required this.selectedInList,
    required this.bypassingTunnel,
    required this.add,
    required this.cancel,
    required this.searchApps,
    required this.loadingApps,
    required this.splitTunnelDisabledHint,
    required this.splitTunnelingSubtitleHosts,
    required this.hostsBypassVpn,
    required this.addBypassHost,
    required this.bypassHostHint,
    required this.invalidBypassHost,
    required this.bypassHostExists,
    required this.splitTunnelHostsDisabledHint,
    required this.noBypassHosts,
    required this.splitTunnelAppsTab,
    required this.splitTunnelHostsTab,
    required this.splitTunnelModeLabel,
    required this.splitTunnelModeExclude,
    required this.splitTunnelModeInclude,
    required this.appsUseVpnOnly,
    required this.hostsUseVpnOnly,
    required this.splitTunnelIncludeDisabledHint,
    required this.splitTunnelHostsIncludeDisabledHint,
    required this.splitTunnelIncludeEmptyNotice,
    required this.notifExpiringSoonTitle,
    required this.notifExpiresInDays,
    required this.notifExpiresInMinutes,
    required this.notifExpiredTitle,
    required this.notifExpiredBody,
  });

  final String notSignedIn;
  final String couldNotReachServer;
  final String retry;
  final String select;

  final String settingsTitle;
  final String manageAccount;
  final String connectionSettings;
  final String dnsServer;
  final String networkStack;
  final String autoReconnect;
  final String autoReconnectSubtitle;
  final String killSwitch;
  final String killSwitchSubtitle;
  final String appliesOnNextConnection;
  final String customDnsHint;
  final String routing;
  final String splitTunnelingSettings;
  final String splitTunnelingSubtitle;
  final String system;
  final String language;
  final String account;
  final String signOut;
  final String currentKey;
  final String keyCopied;
  final String connectKey;
  final String connectKeyHint;
  final String buySubscription;
  final String contactSupport;
  final String logsManagement;
  final String applicationLogs;
  final String shareDiagnostics;
  final String clear;
  final String send;
  final String logsCleared;
  final String noLogsToShare;
  final String active;
  final String expired;
  final String Function(int days) expiresInDays;
  final String Function(int hours) expiresInHours;

  final String connectedTo;
  final String location;
  final String bestServer;
  final String bestServerAuto;
  final String activeBadge;
  final String connected;
  final String connecting;
  final String disconnected;
  final String sessionTime;
  final String connectionNotProtected;

  /// Shown while the tunnel is up but nothing gets through it — the state the
  /// app used to render as a plain green "connected" with no internet.
  final String tunnelNotPassingTraffic;

  /// Shown when the subscription lists nothing this build can connect to —
  /// previously surfaced as a raw `Bad state: …` from a StateError.
  final String noUsableServers;
  final String bestServers;
  final String seeAll;

  final String chooseLocation;
  final String allLocations;
  final String Function(int count) serversCount;
  final String unreachable;

  /// Label for the group of servers that belong to no country — the panel's
  /// bypass hosts, which front a whitelisted address instead of a location.
  /// Named after what the panel itself calls them, so the user recognizes the
  /// entry they were told to look for.
  final String whitelistLocations;

  /// Told to the user after the app moved a live session to a faster node on
  /// its own — without it, the reconnect blip looks like a fault.
  final String Function(String location) switchedToFasterServer;

  final String openBotTitle;
  final String openBotSubtitle;
  final String trialUsedTitle;
  final String trialUsedSubtitle;
  final String trialResumableTitle;
  final String trialResumableSubtitle;
  final String connectWithTelegram;
  final String pairingWaiting;
  final String pairingScanHint;
  final String pairingCodeExpired;
  final String getNewCode;
  final String haveKeyTitle;
  final String enterKeyHint;
  final String submitKey;
  final String tryFreeTrial;

  /// Button on the sign-out/recovery screen for a device whose earlier trial
  /// may still be running — asks the BFF to resume it instead of requiring
  /// Telegram/a key.
  final String continueTrial;
  final String settingUpFreeAccess;
  final String trialAlreadyUsed;
  final String trialNoCapacity;
  final String trialFailed;
  final String keyBoundToOtherDevice;

  /// A key the BFF doesn't know (404) — a typo, or a code that has run out.
  /// Kept apart from [couldNotReachServer]: telling someone who mistyped their
  /// key that the server is down sends them looking for the wrong problem.
  final String keyNotFound;

  /// Confirmation shown before a key that arrived over the `fatvpn://`
  /// deep link is exchanged — any app on the device can send one, and a
  /// key the user didn't ask for moves their traffic to a stranger's exit.
  final String deepLinkKeyTitle;
  final String Function(String keyCode) deepLinkKeyBody;
  final String subscriptionExpiredTitle;
  final String subscriptionExpiredSubtitle;
  final String renewViaTelegram;
  final String checkAgain;

  final String splitTunneling;
  final String appsBypassVpn;
  final String selectedInList;
  final String bypassingTunnel;
  final String add;

  /// The app hand-rolls its localization and never registers
  /// `flutter_localizations`, so `MaterialLocalizations` falls back to its
  /// English defaults — `cancelButtonLabel` showed "Cancel" under RU.
  final String cancel;
  final String searchApps;
  final String loadingApps;
  final String splitTunnelDisabledHint;

  // Host-based split tunneling (iOS): bypass by domain / IP instead of per-app.
  final String splitTunnelingSubtitleHosts;
  final String hostsBypassVpn;
  final String addBypassHost;
  final String bypassHostHint;
  final String invalidBypassHost;
  final String bypassHostExists;
  final String splitTunnelHostsDisabledHint;
  final String noBypassHosts;
  final String splitTunnelAppsTab;
  final String splitTunnelHostsTab;

  // Whitelist mode: the same two lists, read the other way round — only what
  // they name uses the VPN. Each mode keeps its own entries, so these labels
  // are what tells the user which set they are editing.
  final String splitTunnelModeLabel;
  final String splitTunnelModeExclude;
  final String splitTunnelModeInclude;
  final String appsUseVpnOnly;
  final String hostsUseVpnOnly;
  final String splitTunnelIncludeDisabledHint;
  final String splitTunnelHostsIncludeDisabledHint;

  /// Shown while the whitelist is empty, where the safe fallback — leaving the
  /// full tunnel up — is the opposite of what "only these" sounds like.
  final String splitTunnelIncludeEmptyNotice;

  /// Title of the "subscription ending soon" reminder notification.
  final String notifExpiringSoonTitle;

  /// Body of the reminder N days before expiry (handles pluralization).
  final String Function(int days) notifExpiresInDays;

  /// Short-notice reminder body ("… expires in N minutes") fired shortly before
  /// the subscription/trial lapses.
  final String Function(int minutes) notifExpiresInMinutes;

  /// Title/body shown at the moment the subscription/trial has lapsed.
  final String notifExpiredTitle;
  final String notifExpiredBody;
}

String _ruPluralDays(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return 'день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
  return 'дней';
}

String _ruPluralHours(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return 'час';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'часа';
  return 'часов';
}

String _ruPluralMinutes(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return 'минуту';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'минуты';
  return 'минут';
}

const Strings enStrings = Strings(
  notSignedIn: 'Not signed in',
  couldNotReachServer: 'Could not reach the server.',
  retry: 'Retry',
  select: 'Select',
  settingsTitle: 'Settings',
  manageAccount: 'MANAGE ACCOUNT',
  connectionSettings: 'CONNECTION SETTINGS',
  dnsServer: 'DNS Server',
  networkStack: 'Network stack',
  autoReconnect: 'Reconnect automatically',
  autoReconnectSubtitle:
      'Let the system bring the VPN back after a crash or a restart',
  killSwitch: 'Block traffic without VPN',
  killSwitchSubtitle:
      'Nothing leaves the device while the tunnel is down',
  appliesOnNextConnection: 'Changes apply automatically',
  customDnsHint: 'Custom resolver (DoH URL, tls:// or IP)',
  routing: 'ROUTING',
  splitTunnelingSettings: 'Split tunneling settings',
  splitTunnelingSubtitle: 'Choose which apps, domains and IPs use the VPN',
  system: 'SYSTEM',
  language: 'Language',
  account: 'ACCOUNT',
  signOut: 'Sign out',
  currentKey: 'Current key',
  keyCopied: 'Key copied',
  connectKey: 'CONNECT A KEY',
  connectKeyHint: 'Have a key from the bot? Paste it to connect.',
  buySubscription: 'Buy via Telegram',
  contactSupport: 'Contact support',
  logsManagement: 'LOGS MANAGEMENT',
  applicationLogs: 'Application logs',
  shareDiagnostics: 'Share diagnostics with support',
  clear: 'Clear',
  send: 'Send',
  logsCleared: 'Logs cleared',
  noLogsToShare: 'No logs to share yet',
  active: 'Active',
  expired: 'Expired',
  expiresInDays: _enExpiresInDays,
  expiresInHours: _enExpiresInHours,
  connectedTo: 'Connected to',
  location: 'LOCATION',
  bestServer: 'Best server',
  bestServerAuto: 'Automatic · fastest & nearest',
  activeBadge: 'ACTIVE',
  connected: 'Connected',
  connecting: 'Connecting…',
  disconnected: 'Disconnected',
  sessionTime: 'SESSION TIME',
  connectionNotProtected: 'Your connection is not protected',
  tunnelNotPassingTraffic: 'This server is not responding. Pick another one.',
  noUsableServers: 'No servers are available on this subscription. Try again or contact support.',
  bestServers: 'Best servers',
  seeAll: 'See all',
  chooseLocation: 'Choose location',
  allLocations: 'ALL LOCATIONS',
  serversCount: _enServersCount,
  unreachable: 'unreachable',
  whitelistLocations: 'Whitelists',
  switchedToFasterServer: _enSwitchedToFasterServer,
  openBotTitle: 'Start for free',
  openBotSubtitle: 'Get 2 days free, or enter your key right away if you already have one. A subscription is bought in the FatVPN Telegram bot.',
  trialUsedTitle: 'Connect a subscription',
  trialUsedSubtitle: 'Your free trial has ended. Buy a subscription in the FatVPN Telegram bot, or enter your key if you already have one.',
  trialResumableTitle: 'Session interrupted',
  trialResumableSubtitle: 'You signed out, but your free trial may still be running. Continue it, buy a subscription in the FatVPN Telegram bot, or enter your key.',
  connectWithTelegram: 'Connect with Telegram',
  pairingWaiting: 'Waiting for the bot to confirm…',
  pairingScanHint: 'On another device? Scan this code or open the bot and send:',
  pairingCodeExpired: 'Pairing code expired.',
  getNewCode: 'Get a new code',
  haveKeyTitle: 'I already have a key',
  enterKeyHint: 'Paste your key code',
  submitKey: 'Connect',
  tryFreeTrial: 'Try 2 days free',
  continueTrial: 'Continue trial',
  settingUpFreeAccess: 'Setting up your free access…',
  trialAlreadyUsed: 'A trial was already used on this device.',
  trialNoCapacity: 'No trial slots available right now. Please try later.',
  trialFailed: 'Could not start the trial. Check your connection and try again.',
  keyBoundToOtherDevice: 'This key is already linked to another phone. Change your key in the bot to move it to this device.',
  keyNotFound: 'No such key, or it has expired. Check the code in the bot.',
  deepLinkKeyTitle: 'Use this key?',
  deepLinkKeyBody: _enDeepLinkKeyBody,
  subscriptionExpiredTitle: 'Subscription expired',
  subscriptionExpiredSubtitle: 'Renew in Telegram to keep using FatVPN — the app reconnects automatically once your subscription is active again.',
  renewViaTelegram: 'Renew via Telegram',
  checkAgain: 'I renewed — check again',
  splitTunneling: 'Split tunneling',
  appsBypassVpn: 'Apps that bypass the VPN',
  selectedInList: 'SELECTED IN LIST',
  bypassingTunnel: 'Bypassing tunnel',
  add: 'Add',
  cancel: 'Cancel',
  searchApps: 'Search apps',
  loadingApps: 'Loading apps…',
  splitTunnelDisabledHint: 'Turn on the switch above to pick apps that bypass the VPN.',
  splitTunnelingSubtitleHosts: 'Choose which domains and IPs use the VPN',
  hostsBypassVpn: 'Domains and IP ranges that bypass the VPN',
  addBypassHost: 'Add domain or IP',
  bypassHostHint: 'example.com, *.ru or 10.0.0.0/8',
  invalidBypassHost: 'Enter a domain (example.com) or an IP/CIDR (10.0.0.0/8).',
  bypassHostExists: 'This rule is already in the list.',
  splitTunnelHostsDisabledHint: 'Turn on the switch above to add domains and IPs that bypass the VPN.',
  noBypassHosts: 'No rules yet. Tap “Add domain or IP” to create one.',
  splitTunnelAppsTab: 'Apps',
  splitTunnelHostsTab: 'Domains / IP',
  splitTunnelModeLabel: 'Mode',
  splitTunnelModeExclude: 'Around the VPN',
  splitTunnelModeInclude: 'Only these',
  appsUseVpnOnly: 'Only these apps use the VPN',
  hostsUseVpnOnly: 'Only these domains and IP ranges use the VPN',
  splitTunnelIncludeDisabledHint:
      'Turn on the switch above to pick the only apps that use the VPN.',
  splitTunnelHostsIncludeDisabledHint:
      'Turn on the switch above to pick the only domains and IPs that use the VPN.',
  splitTunnelIncludeEmptyNotice:
      'This list is empty, so everything still goes through the VPN.',
  notifExpiringSoonTitle: 'Subscription ending soon',
  notifExpiresInDays: _enNotifExpiresInDays,
  notifExpiresInMinutes: _enNotifExpiresInMinutes,
  notifExpiredTitle: 'Subscription expired',
  notifExpiredBody: 'Renew in Telegram to keep using FatVPN.',
);

String _enNotifExpiresInDays(int n) =>
    'Your access expires in $n day${n == 1 ? '' : 's'}. '
    'Renew in Telegram to stay connected.';

String _enNotifExpiresInMinutes(int n) =>
    'Your access expires in $n minute${n == 1 ? '' : 's'}. '
    'Renew in Telegram to stay connected.';

String _enExpiresInDays(int n) => 'Expires in $n day${n == 1 ? '' : 's'}';
String _enExpiresInHours(int n) => 'Expires in $n hour${n == 1 ? '' : 's'}';
String _enServersCount(int n) => '$n server${n == 1 ? '' : 's'}';

String _enDeepLinkKeyBody(String keyCode) =>
    'Another app asked FatVPN to connect with the key $keyCode. '
    'Only accept it if you opened this link yourself.';

String _ruDeepLinkKeyBody(String keyCode) =>
    'Другое приложение просит FatVPN подключиться по ключу $keyCode. '
    'Соглашайтесь, только если вы сами открыли эту ссылку.';

String _enSwitchedToFasterServer(String location) =>
    'Switched to a faster server: $location';

final Strings ruStrings = Strings(
  notSignedIn: 'Вы не авторизованы',
  couldNotReachServer: 'Не удалось подключиться к серверу.',
  retry: 'Повторить',
  select: 'Выбрать',
  settingsTitle: 'Настройки',
  manageAccount: 'УПРАВЛЕНИЕ АККАУНТОМ',
  connectionSettings: 'НАСТРОЙКИ ПОДКЛЮЧЕНИЯ',
  dnsServer: 'DNS-сервер',
  networkStack: 'Сетевой стек',
  autoReconnect: 'Переподключаться автоматически',
  autoReconnectSubtitle:
      'Система сама поднимет VPN после сбоя или перезагрузки',
  killSwitch: 'Блокировать трафик без VPN',
  killSwitchSubtitle: 'Пока туннель не работает, ничего не уходит с устройства',
  appliesOnNextConnection: 'Изменения применяются автоматически',
  customDnsHint: 'Свой резолвер (DoH-URL, tls:// или IP)',
  routing: 'МАРШРУТИЗАЦИЯ',
  splitTunnelingSettings: 'Настройки раздельного туннелирования',
  splitTunnelingSubtitle: 'Выберите, какие приложения, домены и IP идут через VPN',
  system: 'СИСТЕМА',
  language: 'Язык',
  account: 'АККАУНТ',
  signOut: 'Выйти',
  currentKey: 'Текущий ключ',
  keyCopied: 'Ключ скопирован',
  connectKey: 'ПОДКЛЮЧИТЬ КЛЮЧ',
  connectKeyHint: 'Есть ключ из бота? Вставьте, чтобы подключиться.',
  buySubscription: 'Купить через Telegram',
  contactSupport: 'Написать в поддержку',
  logsManagement: 'УПРАВЛЕНИЕ ЛОГАМИ',
  applicationLogs: 'Логи приложения',
  shareDiagnostics: 'Поделиться диагностикой с поддержкой',
  clear: 'Очистить',
  send: 'Отправить',
  logsCleared: 'Логи очищены',
  noLogsToShare: 'Пока нет логов для отправки',
  active: 'Активна',
  expired: 'Истекла',
  expiresInDays: (n) => 'Истекает через $n ${_ruPluralDays(n)}',
  expiresInHours: (n) => 'Истекает через $n ${_ruPluralHours(n)}',
  connectedTo: 'Подключено к',
  location: 'ЛОКАЦИЯ',
  bestServer: 'Лучший сервер',
  bestServerAuto: 'Автоматически · быстрейший',
  activeBadge: 'АКТИВНО',
  connected: 'Подключено',
  connecting: 'Подключение…',
  disconnected: 'Отключено',
  sessionTime: 'ВРЕМЯ СЕССИИ',
  connectionNotProtected: 'Ваше соединение не защищено',
  tunnelNotPassingTraffic: 'Сервер не отвечает. Выберите другой.',
  noUsableServers: 'На этой подписке нет доступных серверов. Повторите попытку или напишите в поддержку.',
  bestServers: 'Лучшие серверы',
  seeAll: 'Смотреть все',
  chooseLocation: 'Выбор локации',
  allLocations: 'ВСЕ ЛОКАЦИИ',
  serversCount: (n) => '$n ${_ruPluralServers(n)}',
  unreachable: 'недоступен',
  whitelistLocations: 'Белые списки',
  switchedToFasterServer: (location) =>
      'Переключились на более быстрый сервер: $location',
  openBotTitle: 'Начните бесплатно',
  openBotSubtitle:
      'Получите 2 дня бесплатно или сразу введите ключ, если он у вас уже есть. Подписка покупается в Telegram-боте FatVPN.',
  trialUsedTitle: 'Подключите подписку',
  trialUsedSubtitle:
      'Ваш бесплатный период закончился. Купите подписку в Telegram-боте FatVPN или введите ключ, если он у вас уже есть.',
  trialResumableTitle: 'Сессия прервана',
  trialResumableSubtitle:
      'Вы вышли из аккаунта, но пробный период может быть ещё активен. Продолжите его, подключите подписку в Telegram-боте FatVPN или введите ключ.',
  connectWithTelegram: 'Подключить через Telegram',
  pairingWaiting: 'Ожидаем подтверждения от бота…',
  pairingScanHint: 'На другом устройстве? Отсканируйте код или откройте бота и отправьте:',
  pairingCodeExpired: 'Код подключения истёк.',
  getNewCode: 'Получить новый код',
  haveKeyTitle: 'У меня уже есть ключ',
  enterKeyHint: 'Вставьте код ключа',
  submitKey: 'Подключить',
  tryFreeTrial: 'Попробовать 2 дня бесплатно',
  continueTrial: 'Продолжить пробный период',
  settingUpFreeAccess: 'Настраиваем бесплатный доступ…',
  trialAlreadyUsed: 'Пробный период уже был использован на этом устройстве.',
  trialNoCapacity: 'Сейчас нет свободных пробных слотов. Попробуйте позже.',
  trialFailed: 'Не удалось запустить пробный период. Проверьте соединение и повторите.',
  keyBoundToOtherDevice: 'Этот ключ уже привязан к другому телефону. Смените ключ в боте, чтобы перенести его на это устройство.',
  keyNotFound: 'Такого ключа нет или он истёк. Проверьте код в боте.',
  deepLinkKeyTitle: 'Использовать этот ключ?',
  deepLinkKeyBody: _ruDeepLinkKeyBody,
  subscriptionExpiredTitle: 'Подписка истекла',
  subscriptionExpiredSubtitle: 'Продлите подписку в Telegram, чтобы продолжить пользоваться FatVPN — приложение переподключится автоматически, как только подписка снова станет активной.',
  renewViaTelegram: 'Продлить через Telegram',
  checkAgain: 'Я продлил — обновить',
  splitTunneling: 'Раздельное туннелирование',
  appsBypassVpn: 'Приложения, которые обходят VPN',
  selectedInList: 'ВЫБРАНО В СПИСКЕ',
  bypassingTunnel: 'Обход туннеля',
  add: 'Добавить',
  cancel: 'Отмена',
  searchApps: 'Поиск приложений',
  loadingApps: 'Загрузка приложений…',
  splitTunnelDisabledHint: 'Включите переключатель выше, чтобы выбрать приложения в обход VPN.',
  splitTunnelingSubtitleHosts: 'Выберите, какие домены и IP идут через VPN',
  hostsBypassVpn: 'Домены и подсети, которые обходят VPN',
  addBypassHost: 'Добавить домен или IP',
  bypassHostHint: 'example.com, *.ru или 10.0.0.0/8',
  invalidBypassHost: 'Введите домен (example.com) или IP/подсеть (10.0.0.0/8).',
  bypassHostExists: 'Это правило уже в списке.',
  splitTunnelHostsDisabledHint: 'Включите переключатель выше, чтобы добавить домены и IP в обход VPN.',
  noBypassHosts: 'Пока нет правил. Нажмите «Добавить домен или IP».',
  splitTunnelAppsTab: 'Приложения',
  splitTunnelHostsTab: 'Домены / IP',
  splitTunnelModeLabel: 'Режим',
  splitTunnelModeExclude: 'Мимо VPN',
  splitTunnelModeInclude: 'Только эти',
  appsUseVpnOnly: 'Через VPN идут только эти приложения',
  hostsUseVpnOnly: 'Через VPN идут только эти домены и подсети',
  splitTunnelIncludeDisabledHint:
      'Включите переключатель выше, чтобы выбрать приложения, которым разрешён VPN.',
  splitTunnelHostsIncludeDisabledHint:
      'Включите переключатель выше, чтобы выбрать домены и IP, которым разрешён VPN.',
  splitTunnelIncludeEmptyNotice:
      'Список пуст, поэтому весь трафик по-прежнему идёт через VPN.',
  notifExpiringSoonTitle: 'Подписка скоро закончится',
  notifExpiresInDays: (n) =>
      'Доступ истекает через $n ${_ruPluralDays(n)}. Продлите в Telegram, чтобы остаться на связи.',
  notifExpiresInMinutes: (n) =>
      'Доступ истекает через $n ${_ruPluralMinutes(n)}. Продлите в Telegram, чтобы остаться на связи.',
  notifExpiredTitle: 'Подписка истекла',
  notifExpiredBody: 'Продлите в Telegram, чтобы продолжить пользоваться FatVPN.',
);

String _ruPluralServers(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return 'сервер';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'сервера';
  }
  return 'серверов';
}

Strings stringsFor(AppLanguage language) {
  switch (language) {
    case AppLanguage.en:
      return enStrings;
    case AppLanguage.ru:
      return ruStrings;
  }
}
