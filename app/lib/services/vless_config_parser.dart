import 'dart:convert';

import '../models/server_country.dart';

/// Config-link schemes the `singbox_mm` plugin can parse and connect
/// (`VpnConfigParser.supportedSchemes`). `/config` may list any of these — not
/// just vless — so we keep every supported line and let the plugin build the
/// right outbound (vless, hysteria2, trojan, …).
const _supportedSchemes = <String>{
  'sbmm',
  'vless',
  'vmess',
  'ss',
  'shadowsocks',
  'trojan',
  'hysteria',
  'hysteria2',
  'hy2',
  'tuic',
  'wireguard',
  'wg',
  'ssh',
};

/// Decodes the raw `/config` response into individual proxy config links.
///
/// Remnawave returns the whole subscription as a single base64 blob that
/// decodes into one link per line. We keep every line whose scheme the tunnel
/// plugin understands (see [_supportedSchemes]), so nodes on any protocol in
/// the subscription — not only vless — become usable.
List<String> parseConfigUris(String rawConfigContent) {
  final String decoded;
  try {
    decoded = utf8.decode(base64.decode(rawConfigContent.trim()));
  } catch (_) {
    return [];
  }
  return decoded
      .split('\n')
      .map((line) => line.trim())
      .where((line) => _supportedSchemes.contains(_schemeOf(line)))
      .toList();
}

/// Lowercased URI scheme of [line] (`vless://…` → `vless`), or null if the line
/// isn't a `scheme://…` link.
String? _schemeOf(String line) {
  final match = RegExp(r'^([a-zA-Z0-9+.-]+)://').firstMatch(line);
  return match?.group(1)?.toLowerCase();
}

/// One connectable entry from the subscription: the raw link plus the bits the
/// server list needs to render it.
///
/// These come from Remnawave *hosts*, which are a different entity from the
/// *nodes* `GET /servers` returns — a host carries the client-facing address
/// (often a domain, or a CDN front) and its own remark, and a node can back
/// several of them. Anything the subscription lists is connectable by
/// definition, so this is the authoritative list of what the user can reach.
class ConfigEntry {
  const ConfigEntry({
    required this.uri,
    required this.host,
    required this.port,
    required this.tag,
  });

  /// The full config link, ready to hand to the tunnel plugin.
  final String uri;

  /// Client-facing address (`vless://…@HOST:port`).
  final String host;

  /// Client-facing inbound port — the real one to connect to, unlike the
  /// management port `/servers` reports.
  final int port;

  /// The link's `#fragment`, URL-decoded: the host remark set in the panel,
  /// e.g. "🇫🇷 Франция • H2". Empty when the link carries no fragment.
  final String tag;
}

/// Decodes `/config` into structured [ConfigEntry] records. Same filtering as
/// [parseConfigUris]; lines that don't parse as a URI are skipped.
List<ConfigEntry> parseConfigEntries(String rawConfigContent) {
  final entries = <ConfigEntry>[];
  for (final uri in parseConfigUris(rawConfigContent)) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.host.isEmpty) continue;
    entries.add(ConfigEntry(
      uri: uri,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : 443,
      tag: _decodeFragment(parsed.fragment),
    ));
  }
  return entries;
}

/// Fragments arrive percent-encoded (the augmenter and Remnawave both escape
/// them). A malformed escape must not cost us the whole entry, so fall back to
/// the raw text.
String _decodeFragment(String fragment) {
  if (fragment.isEmpty) return '';
  try {
    return Uri.decodeComponent(fragment);
  } catch (_) {
    return fragment;
  }
}

/// Finds the config URI whose host matches [node]'s address.
///
/// Matching is address-only: `GET /servers` exposes the Remnawave agent's
/// management port (always 2222), not the client-facing inbound port, and a
/// single node can have several inbounds on different ports — the port from
/// `/servers` can't be used to disambiguate them.
String? findUriForNode(List<String> uris, ServerNode node) {
  for (final uri in uris) {
    final parsed = Uri.tryParse(uri);
    if (parsed != null && parsed.host == node.address) {
      return uri;
    }
  }
  return null;
}
