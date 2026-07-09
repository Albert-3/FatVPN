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
