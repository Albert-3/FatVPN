import 'dart:convert';

import '../models/server_country.dart';

/// Decodes the raw `/config` response into individual `vless://` links.
///
/// Remnawave returns the whole subscription as a single base64 blob that
/// decodes into one link per line.
List<String> parseVlessUris(String rawConfigContent) {
  final String decoded;
  try {
    decoded = utf8.decode(base64.decode(rawConfigContent.trim()));
  } catch (_) {
    return [];
  }
  return decoded
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('vless://'))
      .toList();
}

/// Finds the `vless://` URI whose host matches [node]'s address.
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
