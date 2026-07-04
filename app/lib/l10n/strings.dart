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
    required this.connected,
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
    required this.splitTunneling,
    required this.appsBypassVpn,
    required this.selectedInList,
    required this.bypassingTunnel,
    required this.add,
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
  final String connected;
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

  final String splitTunneling;
  final String appsBypassVpn;
  final String selectedInList;
  final String bypassingTunnel;
  final String add;
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
  connected: 'Connected',
  disconnected: 'Disconnected',
  sessionTime: 'SESSION TIME',
  connectionNotProtected: 'Your connection is not protected',
  bestServers: 'Best servers',
  seeAll: 'See all',
  chooseLocation: 'Choose location',
  allLocations: 'ALL LOCATIONS',
  serversCount: _enServersCount,
  unreachable: 'unreachable',
  openBotTitle: 'Open FatVPN bot in Telegram',
  openBotSubtitle: 'Tap the link the bot sends you to sign in automatically.',
  splitTunneling: 'Split tunneling',
  appsBypassVpn: 'Apps that bypass the VPN',
  selectedInList: 'SELECTED IN LIST',
  bypassingTunnel: 'Bypassing tunnel',
  add: 'Add',
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
  connected: 'Подключено',
  disconnected: 'Отключено',
  sessionTime: 'ВРЕМЯ СЕССИИ',
  connectionNotProtected: 'Ваше соединение не защищено',
  bestServers: 'Лучшие серверы',
  seeAll: 'Смотреть все',
  chooseLocation: 'Выбор локации',
  allLocations: 'ВСЕ ЛОКАЦИИ',
  serversCount: (n) => '$n ${_ruPluralServers(n)}',
  unreachable: 'недоступен',
  openBotTitle: 'Откройте бота FatVPN в Telegram',
  openBotSubtitle:
      'Нажмите на ссылку, которую пришлёт бот, чтобы войти автоматически.',
  splitTunneling: 'Раздельное туннелирование',
  appsBypassVpn: 'Приложения, которые обходят VPN',
  selectedInList: 'ВЫБРАНО В СПИСКЕ',
  bypassingTunnel: 'Обход туннеля',
  add: 'Добавить',
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
