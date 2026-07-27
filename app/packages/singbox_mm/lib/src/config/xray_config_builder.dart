import 'dart:convert';

/// Local SOCKS port the bundled Xray core listens on when it terminates a
/// transport sing-box cannot speak.
///
/// Deliberately not 10808: that is [SingboxInboundBuilder]'s default mixed
/// inbound, and the two would fight over the port whenever both are enabled.
const int kXrayBridgeSocksPort = 11080;

/// Tag of the single outbound in a bridge config, referenced by nothing else —
/// the bridge has no routing beyond "everything out through the node".
const String _kProxyTag = 'proxy';

/// Whether [configLink] describes a node this build can only reach through the
/// bundled Xray core.
///
/// Today that means Xray's XHTTP: the panel serves it in `packet-up` mode with
/// padding obfuscation (uplink over `DELETE`, data in the body, padding hidden
/// in a query parameter), and sing-box implements no part of that. Everything
/// else in the subscription is a transport sing-box speaks natively, and going
/// through a second core for those would only add a hop.
bool linkNeedsXrayCore(String configLink) {
  final Uri? uri = Uri.tryParse(configLink.trim());
  if (uri == null) {
    return false;
  }
  if (uri.scheme.toLowerCase() != 'vless') {
    return false;
  }
  final String type =
      uri.queryParameters['type']?.trim().toLowerCase() ?? '';
  return type == 'xhttp' || type == 'splithttp';
}

/// Builds the Xray configuration that terminates [configLink] and offers the
/// result as a plain SOCKS5 server on `127.0.0.1:[socksPort]`, which sing-box
/// then uses as its proxy outbound.
///
/// The transport block is copied from the link rather than interpreted: the
/// padding parameters in `extra` are a contract with the server's inbound
/// (which HTTP method carries the uplink, where the padding hides), so
/// anything this builder "normalizes" is a way for the connection to fail.
/// The one addition is `xPaddingBytes` when the link omits it — the panel's
/// links are trimmed against its own full template, and Xray's built-in
/// default breaks the contract instead of completing it (see below).
///
/// Routing is deliberately absent. This instance sees only what sing-box hands
/// it, and sing-box has already applied the user's split tunnelling, DNS and
/// bypass rules by then — a second set of rules here could only contradict the
/// first.
Map<String, Object?> buildXraySocksBridgeConfig({
  required String configLink,
  int socksPort = kXrayBridgeSocksPort,
  String logLevel = 'warning',
}) {
  final Uri uri = Uri.parse(configLink.trim());
  if (uri.scheme.toLowerCase() != 'vless') {
    throw FormatException(
      'Only vless links can be bridged through Xray, got "${uri.scheme}".',
    );
  }
  final String host = uri.host;
  if (host.isEmpty) {
    throw const FormatException('Link has no server address.');
  }
  final String uuid = Uri.decodeComponent(uri.userInfo);
  if (uuid.isEmpty) {
    throw const FormatException('Link has no user id.');
  }
  final Map<String, String> params = uri.queryParameters;

  return <String, Object?>{
    'log': <String, Object?>{'loglevel': logLevel},
    'inbounds': <Object?>[
      <String, Object?>{
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': socksPort,
        'protocol': 'socks',
        'settings': <String, Object?>{'udp': true, 'auth': 'noauth'},
        // sing-box already sniffed and routed by the time a connection gets
        // here; sniffing it again would cost a copy of every first packet and
        // change nothing.
        'sniffing': <String, Object?>{'enabled': false},
      },
    ],
    'outbounds': <Object?>[
      <String, Object?>{
        'tag': _kProxyTag,
        'protocol': 'vless',
        'settings': <String, Object?>{
          'vnext': <Object?>[
            <String, Object?>{
              'address': host,
              'port': uri.hasPort ? uri.port : 443,
              'users': <Object?>[
                <String, Object?>{
                  'id': uuid,
                  'encryption': _param(params, 'encryption') ?? 'none',
                  'flow': _param(params, 'flow') ?? '',
                },
              ],
            },
          ],
        },
        'streamSettings': _buildStreamSettings(params, serverHost: host),
      },
    ],
  };
}

Map<String, Object?> _buildStreamSettings(
  Map<String, String> params, {
  required String serverHost,
}) {
  final Map<String, Object?> stream = <String, Object?>{'network': 'xhttp'};

  final Map<String, Object?> xhttp = <String, Object?>{};
  final String? mode = _param(params, 'mode');
  if (mode != null) {
    xhttp['mode'] = mode;
  }
  final String? path = _param(params, 'path');
  if (path != null) {
    xhttp['path'] = path;
  }
  final String? hostHeader = _param(params, 'host');
  if (hostHeader != null) {
    xhttp['host'] = hostHeader;
  }
  final Map<String, Object?>? extra = _decodeExtra(params['extra']);
  if (extra != null) {
    // The panel's link carries a trimmed `extra`: its own Happ template for
    // the same host also sets `xPaddingBytes: "16-64"`, but the link omits it.
    // Xray then pads with its default 100-1000 bytes, the inbound validates
    // the token-shaped padding it expects in the query and answers 400 to
    // every uplink — verified against the live "Белые списки #1" host. A link
    // that declares padding obfuscation without a size gets the panel's range;
    // one that states its own size keeps it.
    if (extra['xPaddingObfsMode'] == true &&
        !extra.containsKey('xPaddingBytes')) {
      extra['xPaddingBytes'] = '16-64';
    }
    xhttp['extra'] = extra;
  }
  stream['xhttpSettings'] = xhttp;

  final String security =
      _param(params, 'security')?.toLowerCase() ?? 'none';
  switch (security) {
    case 'tls':
      stream['security'] = 'tls';
      stream['tlsSettings'] = _buildTlsSettings(
        params,
        serverHost: serverHost,
        hostHeader: hostHeader,
      );
    case 'reality':
      stream['security'] = 'reality';
      stream['realitySettings'] = _buildRealitySettings(
        params,
        serverHost: serverHost,
      );
    default:
      stream['security'] = 'none';
  }
  return stream;
}

Map<String, Object?> _buildTlsSettings(
  Map<String, String> params, {
  required String serverHost,
  required String? hostHeader,
}) {
  // With a CDN in front, the name to present is the fronted host, not the
  // address dialled — falling back to the address would offer an IP as SNI and
  // the CDN would not know which resource is meant.
  final Map<String, Object?> tls = <String, Object?>{
    'serverName': _param(params, 'sni') ?? hostHeader ?? serverHost,
  };
  final String? fingerprint = _param(params, 'fp');
  if (fingerprint != null) {
    tls['fingerprint'] = fingerprint;
  }
  final List<String>? alpn = _splitList(params['alpn']);
  if (alpn != null) {
    tls['alpn'] = alpn;
  }
  if (_isTruthy(params['allowInsecure']) || _isTruthy(params['insecure'])) {
    tls['allowInsecure'] = true;
  }
  return tls;
}

Map<String, Object?> _buildRealitySettings(
  Map<String, String> params, {
  required String serverHost,
}) {
  final Map<String, Object?> reality = <String, Object?>{
    'serverName': _param(params, 'sni') ?? serverHost,
    'publicKey': _param(params, 'pbk') ?? '',
  };
  final String? fingerprint = _param(params, 'fp');
  if (fingerprint != null) {
    reality['fingerprint'] = fingerprint;
  }
  final String? shortId = _param(params, 'sid');
  if (shortId != null) {
    reality['shortId'] = shortId;
  }
  final String? spiderX = _param(params, 'spx');
  if (spiderX != null) {
    reality['spiderX'] = spiderX;
  }
  return reality;
}

/// The `extra` parameter carries a JSON object of stream options that have no
/// place in the query string. A malformed one is dropped rather than fatal:
/// the rest of the link still describes a reachable node, and a hard failure
/// here would take out a server the user can see in the list.
Map<String, Object?>? _decodeExtra(String? raw) {
  final String? value = raw?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  try {
    final Object? decoded = jsonDecode(value);
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

String? _param(Map<String, String> params, String key) {
  final String? value = params[key]?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

List<String>? _splitList(String? raw) {
  final String? value = raw?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  final List<String> parts = value
      .split(',')
      .map((String item) => item.trim())
      .where((String item) => item.isNotEmpty)
      .toList();
  return parts.isEmpty ? null : parts;
}

bool _isTruthy(String? raw) {
  final String value = raw?.trim().toLowerCase() ?? '';
  return value == '1' || value == 'true';
}
