/// Converts a 2-letter ISO country code (e.g. "DE") into its flag emoji by
/// mapping each letter to a Regional Indicator Symbol. Falls back to the
/// raw code if it isn't a plausible 2-letter code (the BFF doesn't always
/// have one, e.g. for unrecognized Remnawave node locations).
String countryCodeToFlagEmoji(String code) {
  final normalized = code.trim().toUpperCase();
  if (normalized.length != 2 ||
      !RegExp(r'^[A-Z]{2}$').hasMatch(normalized)) {
    return code;
  }
  final base = 0x1F1E6 - 'A'.codeUnitAt(0);
  return String.fromCharCodes(
    normalized.codeUnits.map((c) => base + c),
  );
}

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
