// Regression tests for the /config parser findings in
// docs/improvement-plan-app-android.md:
//
//   §2.7 — base64 arrives in shapes `base64.decode` alone rejects: the URL-safe
//          alphabet, missing padding, and lines wrapped at 76 characters. Each
//          one currently costs the whole subscription (empty list → the user is
//          shown "No available node in this subscription").
//   §2.8 — `findUriForNode` matches on host only, so a host publishing both a
//          vless and a hysteria2 inbound resolves to whichever line the panel
//          happened to emit first — a non-deterministic protocol choice.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/models/server_country.dart';
import 'package:fatvpn_app/services/vless_config_parser.dart';

const _lines = <String>[
  'vless://11111111-2222-3333-4444-555555555555@de1.example.com:443?security=tls#DE-1',
  'hysteria2://11111111-2222-3333-4444-555555555555@h2-fr.example.com:8443?alpn=h3#FR-H2',
];

/// The plain subscription text Remnawave base64s.
String get _plain => _lines.join('\n');

/// Standard-alphabet base64, the happy path that already works.
String get _standard => base64.encode(utf8.encode(_plain));

/// Pads the payload until its base64 actually contains `+`/`/`, so the
/// URL-safe variant below is genuinely different and the test can't pass
/// vacuously.
String _payloadWithNonAlphanumericBase64() {
  var text = _plain;
  for (var i = 0; i < 64; i++) {
    final encoded = base64.encode(utf8.encode(text));
    if (encoded.contains('+') || encoded.contains('/')) return text;
    // A comment line the parser filters out anyway (no `scheme://`).
    text = '$text\n#${'~' * (i + 1)}';
  }
  fail('could not construct a payload whose base64 uses + or /');
}

void main() {
  group('§2.7 /config decoding survives the shapes a CDN or panel can emit', () {
    // NOTE: Dart's `base64.decode` already accepts the URL-safe alphabet, so
    // this half of the §2.7 finding does not reproduce. Kept as a guard: a fix
    // that switches to a stricter decoder must not regress it.
    test('URL-safe alphabet (- and _) decodes', () {
      final payload = _payloadWithNonAlphanumericBase64();
      final standard = base64.encode(utf8.encode(payload));
      final urlSafe = standard.replaceAll('+', '-').replaceAll('/', '_');
      expect(urlSafe, isNot(standard),
          reason: 'the fixture must actually exercise the URL-safe alphabet');

      expect(parseConfigUris(urlSafe), hasLength(2));
      expect(parseConfigEntries(urlSafe).map((e) => e.host),
          ['de1.example.com', 'h2-fr.example.com']);
    });

    test('missing padding decodes', () {
      // CDNs and hand-rolled clients routinely strip `=`. Dart's decoder then
      // throws "Invalid length, must be multiple of four" and the whole
      // subscription is lost.
      final padded = base64.encode(utf8.encode('$_plain\n#pad'));
      final unpadded = padded.replaceAll('=', '');
      expect(padded, contains('='),
          reason: 'the fixture must actually need padding');
      expect(unpadded.length % 4, isNot(0),
          reason: 'stripping padding must actually break the length');

      expect(parseConfigUris(unpadded), hasLength(2));
    });

    test('base64 wrapped at 76 columns decodes (LF and CRLF)', () {
      String wrap(String s, String eol) {
        final chunks = <String>[];
        for (var i = 0; i < s.length; i += 76) {
          chunks.add(s.substring(i, i + 76 > s.length ? s.length : i + 76));
        }
        return chunks.join(eol);
      }

      expect(parseConfigUris(wrap(_standard, '\n')), hasLength(2));
      expect(parseConfigUris(wrap(_standard, '\r\n')), hasLength(2));
    });

    test('a plain-text body (not base64 at all) is still parsed', () {
      // The BFF proxies whatever Remnawave returns; a text/plain link list is a
      // documented Remnawave format. Today it silently yields [].
      expect(parseConfigUris(_plain), hasLength(2));
      expect(parseConfigEntries(_plain).map((e) => e.host),
          ['de1.example.com', 'h2-fr.example.com']);
    });

    test('an empty body yields an empty list rather than throwing', () {
      expect(parseConfigUris(''), isEmpty);
      expect(parseConfigUris('   \n  '), isEmpty);
      expect(parseConfigEntries(''), isEmpty);
    });

    test('genuinely unparseable content still yields an empty list', () {
      expect(parseConfigUris('«not base64, not links»'), isEmpty);
    });
  });

  group('§2.8 findUriForNode disambiguates two inbounds on one host', () {
    const node = ServerNode(
      id: 'n1',
      name: 'DE-1',
      address: 'same.example.com',
      port: 2222,
      usersOnline: 3,
    );

    test('prefers vless when hysteria2 is listed first', () {
      final uris = <String>[
        'hysteria2://uuid@same.example.com:8443#B',
        'vless://uuid@same.example.com:443#A',
      ];

      expect(findUriForNode(uris, node), startsWith('vless://'));
    });

    test('order of the subscription does not change the answer', () {
      final forward = findUriForNode(<String>[
        'vless://uuid@same.example.com:443#A',
        'hysteria2://uuid@same.example.com:8443#B',
      ], node);
      final reversed = findUriForNode(<String>[
        'hysteria2://uuid@same.example.com:8443#B',
        'vless://uuid@same.example.com:443#A',
      ], node);

      expect(forward, reversed,
          reason: 'protocol choice must be deterministic, not panel-order');
    });

    test('trojan outranks hysteria2 but loses to vless', () {
      expect(
        findUriForNode(<String>[
          'hysteria2://uuid@same.example.com:8443#B',
          'trojan://pw@same.example.com:443#C',
        ], node),
        startsWith('trojan://'),
      );
      expect(
        findUriForNode(<String>[
          'trojan://pw@same.example.com:443#C',
          'vless://uuid@same.example.com:443#A',
        ], node),
        startsWith('vless://'),
      );
    });

    test('still returns the only scheme on offer, and null for no match', () {
      expect(
        findUriForNode(
            <String>['hysteria2://uuid@same.example.com:8443#B'], node),
        startsWith('hysteria2://'),
      );
      expect(findUriForNode(<String>['vless://uuid@other.example.com:443'], node),
          isNull);
    });
  });
}
