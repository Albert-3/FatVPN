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
    required this.appliesOnNextConnection,
    required this.customDnsHint,
    required this.routing,
    required this.splitTunnelingSettings,
    required this.splitTunnelingSubtitle,
    required this.system,
    required this.language,
    required this.account,
    required this.signOut,
    required this.logsManagement,
    required this.applicationLogs,
    required this.shareDiagnostics,
    required this.clear,
    required this.send,
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
    required this.bestServers,
    required this.seeAll,
    required this.chooseLocation,
    required this.allLocations,
    required this.serversCount,
    required this.unreachable,
    required this.openBotTitle,
    required this.openBotSubtitle,
    required this.connectWithTelegram,
    required this.pairingWaiting,
    required this.pairingScanHint,
    required this.pairingCodeExpired,
    required this.getNewCode,
    required this.haveKeyTitle,
    required this.enterKeyHint,
    required this.submitKey,
    required this.tryFreeTrial,
    required this.settingUpFreeAccess,
    required this.trialAlreadyUsed,
    required this.trialNoCapacity,
    required this.trialFailed,
    required this.splitTunneling,
    required this.appsBypassVpn,
    required this.selectedInList,
    required this.bypassingTunnel,
    required this.add,
    required this.searchApps,
    required this.loadingApps,
    required this.splitTunnelDisabledHint,
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
  final String appliesOnNextConnection;
  final String customDnsHint;
  final String routing;
  final String splitTunnelingSettings;
  final String splitTunnelingSubtitle;
  final String system;
  final String language;
  final String account;
  final String signOut;
  final String logsManagement;
  final String applicationLogs;
  final String shareDiagnostics;
  final String clear;
  final String send;
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
  final String bestServers;
  final String seeAll;

  final String chooseLocation;
  final String allLocations;
  final String Function(int count) serversCount;
  final String unreachable;

  final String openBotTitle;
  final String openBotSubtitle;
  final String connectWithTelegram;
  final String pairingWaiting;
  final String pairingScanHint;
  final String pairingCodeExpired;
  final String getNewCode;
  final String haveKeyTitle;
  final String enterKeyHint;
  final String submitKey;
  final String tryFreeTrial;
  final String settingUpFreeAccess;
  final String trialAlreadyUsed;
  final String trialNoCapacity;
  final String trialFailed;

  final String splitTunneling;
  final String appsBypassVpn;
  final String selectedInList;
  final String bypassingTunnel;
  final String add;
  final String searchApps;
  final String loadingApps;
  final String splitTunnelDisabledHint;
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
  appliesOnNextConnection: 'Changes apply automatically',
  customDnsHint: 'Custom resolver (DoH URL, tls:// or IP)',
  routing: 'ROUTING',
  splitTunnelingSettings: 'Split tunneling settings',
  splitTunnelingSubtitle: 'Choose apps that bypass the VPN',
  system: 'SYSTEM',
  language: 'Language',
  account: 'ACCOUNT',
  signOut: 'Sign out',
  logsManagement: 'LOGS MANAGEMENT',
  applicationLogs: 'Application logs',
  shareDiagnostics: 'Share diagnostics with support',
  clear: 'Clear',
  send: 'Send',
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
  bestServers: 'Best servers',
  seeAll: 'See all',
  chooseLocation: 'Choose location',
  allLocations: 'ALL LOCATIONS',
  serversCount: _enServersCount,
  unreachable: 'unreachable',
  openBotTitle: 'Connect your account',
  openBotSubtitle: 'Sign in through the FatVPN Telegram bot. Buy or activate a trial there — the app connects automatically.',
  connectWithTelegram: 'Connect with Telegram',
  pairingWaiting: 'Waiting for the bot to confirm…',
  pairingScanHint: 'On another device? Scan this code or open the bot and send:',
  pairingCodeExpired: 'Pairing code expired.',
  getNewCode: 'Get a new code',
  haveKeyTitle: 'I already have a key',
  enterKeyHint: 'Paste your key code',
  submitKey: 'Connect',
  tryFreeTrial: 'Try 3 days free',
  settingUpFreeAccess: 'Setting up your free access…',
  trialAlreadyUsed: 'A trial was already used on this device.',
  trialNoCapacity: 'No trial slots available right now. Please try later.',
  trialFailed: 'Could not start the trial. Check your connection and try again.',
  splitTunneling: 'Split tunneling',
  appsBypassVpn: 'Apps that bypass the VPN',
  selectedInList: 'SELECTED IN LIST',
  bypassingTunnel: 'Bypassing tunnel',
  add: 'Add',
  searchApps: 'Search apps',
  loadingApps: 'Loading apps…',
  splitTunnelDisabledHint: 'Turn on the switch above to pick apps that bypass the VPN.',
);

String _enExpiresInDays(int n) => 'Expires in $n day${n == 1 ? '' : 's'}';
String _enExpiresInHours(int n) => 'Expires in $n hour${n == 1 ? '' : 's'}';
String _enServersCount(int n) => '$n server${n == 1 ? '' : 's'}';

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
  appliesOnNextConnection: 'Изменения применяются автоматически',
  customDnsHint: 'Свой резолвер (DoH-URL, tls:// или IP)',
  routing: 'МАРШРУТИЗАЦИЯ',
  splitTunnelingSettings: 'Настройки раздельного туннелирования',
  splitTunnelingSubtitle: 'Выберите приложения, которые обходят VPN',
  system: 'СИСТЕМА',
  language: 'Язык',
  account: 'АККАУНТ',
  signOut: 'Выйти',
  logsManagement: 'УПРАВЛЕНИЕ ЛОГАМИ',
  applicationLogs: 'Логи приложения',
  shareDiagnostics: 'Поделиться диагностикой с поддержкой',
  clear: 'Очистить',
  send: 'Отправить',
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
  bestServers: 'Лучшие серверы',
  seeAll: 'Смотреть все',
  chooseLocation: 'Выбор локации',
  allLocations: 'ВСЕ ЛОКАЦИИ',
  serversCount: (n) => '$n ${_ruPluralServers(n)}',
  unreachable: 'недоступен',
  openBotTitle: 'Подключите аккаунт',
  openBotSubtitle:
      'Войдите через Telegram-бота FatVPN. Оформите подписку или пробный период там — приложение подключится автоматически.',
  connectWithTelegram: 'Подключить через Telegram',
  pairingWaiting: 'Ожидаем подтверждения от бота…',
  pairingScanHint: 'На другом устройстве? Отсканируйте код или откройте бота и отправьте:',
  pairingCodeExpired: 'Код подключения истёк.',
  getNewCode: 'Получить новый код',
  haveKeyTitle: 'У меня уже есть ключ',
  enterKeyHint: 'Вставьте код ключа',
  submitKey: 'Подключить',
  tryFreeTrial: 'Попробовать 3 дня бесплатно',
  settingUpFreeAccess: 'Настраиваем бесплатный доступ…',
  trialAlreadyUsed: 'Пробный период уже был использован на этом устройстве.',
  trialNoCapacity: 'Сейчас нет свободных пробных слотов. Попробуйте позже.',
  trialFailed: 'Не удалось запустить пробный период. Проверьте соединение и повторите.',
  splitTunneling: 'Раздельное туннелирование',
  appsBypassVpn: 'Приложения, которые обходят VPN',
  selectedInList: 'ВЫБРАНО В СПИСКЕ',
  bypassingTunnel: 'Обход туннеля',
  add: 'Добавить',
  searchApps: 'Поиск приложений',
  loadingApps: 'Загрузка приложений…',
  splitTunnelDisabledHint: 'Включите переключатель выше, чтобы выбрать приложения в обход VPN.',
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
