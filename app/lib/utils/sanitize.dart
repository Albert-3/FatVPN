/// Redacts credentials and infrastructure detail out of tunnel diagnostics.
///
/// sing-box's stderr tail is pulled into the app log and from there into the
/// support bundle, which the user shares over whatever messenger they like. It
/// routinely quotes the outbound it was dialling — `vless://<uuid>@host:port`,
/// Reality public keys, trojan passwords — so an untouched line hands the
/// reader a working copy of the subscription. Session tokens were already
/// masked in the bundle header; this closes the other half.
///
/// Deliberately blunt: over-redacting costs a support engineer some context,
/// under-redacting costs the user their subscription.
library;

final _patterns = <(RegExp, String)>[
  // UUIDs — the vless/vmess user id.
  (
    RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    ),
    '<redacted-uuid>'
  ),
  // Query-style secrets: password=, pbk= (Reality public key), sid= (short id).
  (
    RegExp(r'\b(password|pbk|sid|obfs-password|auth)=[^\s&"' r"']+",
        caseSensitive: false),
    r'$1=<redacted>'
  ),
  // `user:secret@host` / `<credential>@host:port` — everything before the `@`
  // is a credential in every link scheme the app parses.
  (RegExp(r'(?<=[/:@])[^\s/:@]{6,}@'), '<redacted>@'),
  // Bare `host:port` endpoints, so a shared log isn't a map of the panel.
  (
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}\b'),
    '<redacted-endpoint>'
  ),
];

/// Returns [raw] with credentials and node addresses replaced by placeholders.
String sanitizeDiagnostics(String raw) {
  var out = raw;
  for (final (pattern, replacement) in _patterns) {
    out = out.replaceAllMapped(
      pattern,
      (m) => replacement.replaceAllMapped(
        RegExp(r'\$(\d)'),
        (ref) => m.group(int.parse(ref.group(1)!)) ?? '',
      ),
    );
  }
  return out;
}
