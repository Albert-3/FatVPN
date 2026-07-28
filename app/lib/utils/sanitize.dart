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

/// Field names that carry a credential, in whichever notation the diagnostic
/// happens to use.
///
/// Kept as one list because the two shapes below must never drift apart: a key
/// added to one and forgotten in the other is a secret that leaks through
/// whichever path the platform happens to take.
const _secretKeys = r'uuid|password|pbk|sid|short_id|obfs[-_]?password|'
    r'auth|auth_str|secret|private_key|pre_shared_key|public_key';

final _patterns = <(RegExp, String)>[
  // UUIDs — the vless/vmess user id.
  (
    RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    ),
    '<redacted-uuid>'
  ),
  // URI form — how a config *link* spells its credentials: `?password=…&sid=…`.
  (
    RegExp('\\b($_secretKeys)=[^\\s&"\']+', caseSensitive: false),
    r'$1=<redacted>'
  ),
  // JSON form — how sing-box spells them, which is what actually reaches this
  // function on iOS. The core quotes the fragment of the config it could not
  // load ("decode config at 12: json: cannot unmarshal {…}"), and that config
  // is JSON: `{"password":"…"}` matched none of the URI patterns above, so the
  // whole outbound went to the user's screen and into the support bundle they
  // share. The value alternation covers a quoted string (escapes included) and
  // a bare literal, so a number or an unquoted token is redacted too.
  (
    RegExp(
      '"($_secretKeys)"\\s*:\\s*("(?:[^"\\\\]|\\\\.)*"|[^,}\\s\\]]+)',
      caseSensitive: false,
    ),
    r'"$1": "<redacted>"'
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
