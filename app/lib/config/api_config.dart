/// Base URL of the FatVPN BFF.
/// Test deployment: public BFF on the bot server over HTTP. Switch to the
/// HTTPS domain once one is set up (see the project deploy plan).
const bffBaseUrl = 'http://87.121.221.229:5030';

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
