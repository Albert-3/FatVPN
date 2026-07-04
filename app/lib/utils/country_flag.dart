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
