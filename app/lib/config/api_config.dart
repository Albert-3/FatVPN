/// Base URL of the FatVPN BFF.
///
/// HTTPS since 2026-07-30: Caddy terminates TLS in front of the BFF with a
/// Let's Encrypt certificate. The old `http://87.121.221.229:5030` is still
/// served — builds already on people's phones point at it — but nothing new
/// should: a session token and a subscription id travelled in the clear over
/// every public Wi-Fi the app was used on, and both stores flag it.
const bffBaseUrl = 'https://api.fatklyuchi.space';

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

/// Opens the FatVPN bot (e.g. from Settings "Buy via Telegram"). The user buys
/// a subscription there and receives a key to paste back into the app.
Uri telegramBotLink() => Uri.parse('https://t.me/$telegramBotUsername');

/// The privacy policy, served by Caddy beside the API (backend/legal/*.html,
/// backend/Caddyfile). Reachable from inside the app on purpose, not only from
/// the store listings: Google Play expects an app that holds the VPN permission
/// to show the user where its policy is without sending them to Play first, and
/// Apple's reviewer opens it from wherever it is easiest to find.
Uri privacyPolicyLink({required bool russian}) =>
    Uri.parse('$bffBaseUrl/privacy${russian ? '/ru' : ''}');

/// Telegram support handle opened from the settings screen (without `@`).
const telegramSupportUsername = 'fatvpn_support';

/// Builds the Telegram link to the support chat.
Uri telegramSupportLink() => Uri.parse('https://t.me/$telegramSupportUsername');
