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
  // `scheme://<credential>@` where the credential itself contains `/` — an
  // ss:// userinfo is base64 and '/' is in the base64 alphabet, so the
  // general rule below (which stops at '/') walked straight past it.
  (RegExp(r'(?<=://)[^\s@]{6,}@'), '<redacted>@'),
  // `user:secret@host` / `<credential>@host:port` — everything before the `@`
  // is a credential in every link scheme the app parses.
  (RegExp(r'(?<=[/:@])[^\s/:@]{6,}@'), '<redacted>@'),
  // Bare `host:port` endpoints, so a shared log isn't a map of the panel.
  (
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}\b'),
    '<redacted-endpoint>'
  ),
];

// ── The blunter passes below run after the structured ones ─────────────────
// (so `password=<redacted>` keeps its label instead of being swallowed
// whole), and each carries a filter the structured rules don't need.

/// Bare IPv4, no port — a node address is a node address with or without one.
final _bareIpv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');

/// Loopback and the empty address identify the phone, not the panel, and the
/// watchdog's `127.0.0.1` / `[::1]` probes are half of every tunnel log —
/// redacting them makes the bundle unreadable for nothing.
const _localAddresses = {'127.0.0.1', '0.0.0.0', '::1', '::'};

/// Anything that could be an IPv6 literal. Deliberately loose — the real
/// decision is [_isIpv6]: a timestamp's `12:00:00` has the same shape, so the
/// candidates are filtered by what only an address has (a `::`, or four-plus
/// groups' worth of colons).
final _ipv6Candidate = RegExp(r'(?<![\w.:])[0-9a-fA-F:]*:[0-9a-fA-F:]+(?![\w.:])');

bool _isIpv6(String s) =>
    !_localAddresses.contains(s) &&
    (s.contains('::') || ':'.allMatches(s).length >= 3);

/// Long hex runs — device keys, session ids, undashed uuids. 32 hex chars in
/// a row is never prose.
final _longHex = RegExp(r'\b[0-9a-fA-F]{32,}\b');

/// Base64-ish runs — the shape of an entire encoded subscription, which used
/// to pass through this file untouched (V26).
final _base64Run = RegExp(r'[A-Za-z0-9+/]{20,}={0,2}');

/// What separates a blob from a long word or an `outbound/vless…` tag: real
/// base64 of real config material mixes cases and digits (or uses the `+` and
/// `=` that never appear in prose). `initialize` and `outbound/shadowsocks`
/// stay; `dmxlc3M6Ly8xMTExMTEx…` goes.
bool _looksLikeBlob(String s) {
  if (s.contains('+') || s.endsWith('=')) return true;
  return s.contains(RegExp(r'\d')) &&
      s.contains(RegExp(r'[a-z]')) &&
      s.contains(RegExp(r'[A-Z]'));
}

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
  out = out.replaceAllMapped(_longHex, (_) => '<redacted-hex>');
  out = out.replaceAllMapped(
    _bareIpv4,
    (m) => _localAddresses.contains(m[0]) ? m[0]! : '<redacted-ip>',
  );
  out = out.replaceAllMapped(
    _ipv6Candidate,
    (m) => _isIpv6(m[0]!) ? '<redacted-ip>' : m[0]!,
  );
  out = out.replaceAllMapped(
    _base64Run,
    (m) => _looksLikeBlob(m[0]!) ? '<redacted-blob>' : m[0]!,
  );
  return out;
}
