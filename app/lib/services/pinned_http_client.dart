import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/api_config.dart';
import '../config/ca_pins.dart';
import 'app_logger.dart';

/// The HTTP client every call to the BFF goes through.
///
/// Identical to `http.Client()` in every respect but one: it trusts the four
/// ISRG roots in [letsEncryptRootsPem] and *nothing else* — not the device's
/// ~150 built-in CAs, and on iOS not the ones a configuration profile can add.
/// The reasoning, and what may and may not change on the server without
/// shipping a build first, is in `lib/config/ca_pins.dart`.
///
/// [baseUrl] decides whether pinning applies at all: it is a claim about one
/// server, and turning it on for a plain-HTTP endpoint would pin nothing while
/// reading as protection. Any `https://` URL gets it.
http.Client createBffHttpClient({String? baseUrl}) {
  final url = baseUrl ?? bffBaseUrl;
  if (!url.startsWith('https://')) {
    // The old `http://87.121.221.229:5030` and local development. Nothing to
    // pin: there is no certificate. Said out loud because a build that quietly
    // stopped pinning looks exactly like one that pins.
    log.w('BFF base URL is not https ($url) — certificate pinning is off');
    return http.Client();
  }
  return IOClient(pinnedHttpClient());
}

/// The `dart:io` client underneath [createBffHttpClient]. Separate so tests can
/// point it at a server of their own.
HttpClient pinnedHttpClient() {
  return HttpClient(context: pinnedSecurityContext())
    // Only called when validation has already failed, and only to write down
    // *why*: without this the failure reaches the user as an ordinary "no
    // network", which is the one diagnosis that sends everybody looking in the
    // wrong place. Returning true here would undo the pin entirely.
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      log.e(
        'Rejected the certificate offered for $host:$port — it does not chain '
        'to a pinned root',
        'subject=${cert.subject} issuer=${cert.issuer} '
            'valid=${cert.startValidity.toIso8601String()}..'
            '${cert.endValidity.toIso8601String()}',
      );
      return false;
    };
}

/// A trust store containing the pinned roots and nothing else.
///
/// `withTrustedRoots: false` is the whole point: leave it at the default and the
/// platform's own store is added to these, which is the behaviour being replaced.
SecurityContext pinnedSecurityContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(letsEncryptRootsPem));
