/// Group key for subscription entries that belong to no country: the panel's
/// bypass hosts ("🌍 Белые списки #1", "Авто 🔥 [GRPC]") front a whitelisted
/// address rather than a location, so their remark carries no flag.
const String unknownCountryCode = '??';

/// Emoji shown for [unknownCountryCode] — the panel names those hosts with a
/// globe too, so the app matches what the user sees there.
const String unknownCountryEmoji = '🌍';

/// Converts a 2-letter ISO country code (e.g. "DE") into its flag emoji by
/// mapping each letter to a Regional Indicator Symbol. Anything that isn't a
/// plausible 2-letter code — [unknownCountryCode], or a Remnawave node location
/// the BFF couldn't resolve — renders as the globe rather than as raw text.
String countryCodeToFlagEmoji(String code) {
  final normalized = code.trim().toUpperCase();
  if (normalized.length != 2 ||
      !RegExp(r'^[A-Z]{2}$').hasMatch(normalized)) {
    return unknownCountryEmoji;
  }
  final base = 0x1F1E6 - 'A'.codeUnitAt(0);
  return String.fromCharCodes(
    normalized.codeUnits.map((c) => base + c),
  );
}

/// Label for a country group: the code itself, or [unknownLabel] (a localized
/// "Other") for the flagless bucket, which has no code worth showing.
String countryLabel(String code, String unknownLabel) =>
    code == unknownCountryCode ? unknownLabel : code;

/// Inverse of [countryCodeToFlagEmoji]: pulls the 2-letter ISO code out of the
/// first flag emoji found anywhere in [text], or null when there is none.
///
/// Subscription entries name themselves with a leading flag (Remnawave's host
/// remarks, e.g. "🇫🇷 Франция • H2"), and that flag is the only machine-readable
/// country signal on a node the panel's `/api/nodes` list doesn't cover — so it
/// is what groups such nodes into the right country in the UI.
String? countryCodeFromFlagEmoji(String text) {
  const first = 0x1F1E6; // 🇦
  const last = 0x1F1FF; // 🇿
  final runes = text.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    if (a >= first && a <= last && b >= first && b <= last) {
      final base = 'A'.codeUnitAt(0) - first;
      return String.fromCharCodes([a + base, b + base]);
    }
  }
  return null;
}
