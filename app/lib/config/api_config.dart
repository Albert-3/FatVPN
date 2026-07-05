import 'dart:io' show Platform;

/// Base URL of the FatVPN BFF. `10.0.2.2` is the Android emulator's alias
/// for the host machine's `localhost`; physical devices/iOS simulator need
/// this pointed at the host's real LAN IP or the production BFF URL.
String get bffBaseUrl {
  if (Platform.isAndroid) {
    return 'http://10.0.2.2:5030';
  }
  return 'http://localhost:5030';
}

/// URI scheme the Telegram bot uses to deep-link a short token into the app,
/// e.g. `fatvpn://token/AB12CD34`. Legacy path — kept for the transition.
const deepLinkScheme = 'fatvpn';

/// Telegram bot username (without `@`) the app opens for pairing.
/// Test bot for now; switch to the prod bot when migrating environments.
const telegramBotUsername = 'testfatvpnnbot';

/// Builds the Telegram deep link that carries the pairing code into the bot's
/// `/start` handler as `pair<code>`.
Uri telegramPairLink(String pairCode) =>
    Uri.parse('https://t.me/$telegramBotUsername?start=pair$pairCode');
