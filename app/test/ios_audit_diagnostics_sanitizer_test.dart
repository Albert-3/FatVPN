// Regression tests for docs/improvement-plan-ios.md §2.4 — "diagnostics leak
// the config and visited domains into the UI and the support bundle".
//
// On iOS the extension persists a failure reason plus the last ~6000 bytes of
// sing-box's stderr; VpnController reads it, puts it in `errorMessage` (shown
// on screen) and in the app log, which the user shares from Settings as a
// support bundle. sing-box's parse errors quote the offending JSON, so the text
// routinely contains the outbound verbatim.
//
// The plan names what must not survive that trip: `uuid`, `password`,
// `private_key`, `short_id`, `pre_shared_key`, and long base64-ish blobs.
// `sanitizeDiagnostics` was written for the Android half of the audit against
// URI-shaped text (`key=value`, `creds@host`); these tests state the JSON-shaped
// case, which is the shape iOS actually produces.

import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/utils/sanitize.dart';

/// Asserts the secret is gone and something was left in its place.
void expectRedacted(String output, String secret, {required String what}) {
  expect(output.contains(secret), isFalse,
      reason: '$what survived sanitising: $output');
}

void main() {
  group('URI-shaped diagnostics (already covered by the Android fix)', () {
    test('a vless URI loses its uuid and its endpoint', () {
      const raw = 'start service: dial vless://'
          '11111111-2222-3333-4444-555555555555@203.0.113.7:443 failed';

      final out = sanitizeDiagnostics(raw);

      expectRedacted(out, '11111111-2222-3333-4444-555555555555',
          what: 'the vless user id');
      expectRedacted(out, '203.0.113.7:443', what: 'the node endpoint');
    });

    test('query-style credentials are redacted', () {
      const raw = 'parse link: '
          '?password=SuperSecretTrojanPw&pbk=abcdefghijklmnop&sid=0123abcd';

      final out = sanitizeDiagnostics(raw);

      expectRedacted(out, 'SuperSecretTrojanPw', what: 'the trojan password');
      expectRedacted(out, 'abcdefghijklmnop', what: 'the Reality public key');
      expectRedacted(out, '0123abcd', what: 'the Reality short id');
    });
  });

  group('§2.4 JSON-shaped diagnostics — what sing-box actually prints', () {
    test('a quoted password is redacted', () {
      // sing-box quotes the failing fragment of the config, and the config is
      // JSON, not a URI: the `key=value` patterns never fire on this shape.
      const raw = 'decode config at 12: json: cannot unmarshal '
          '{"type":"trojan","password":"SuperSecretTrojanPw"}';

      expectRedacted(sanitizeDiagnostics(raw), 'SuperSecretTrojanPw',
          what: 'the trojan password');
    });

    test('a quoted WireGuard private key is redacted', () {
      const raw = 'initialize outbound/wireguard[wg-out]: '
          '{"private_key":"aFakeButValidLookingWgKey0123456789abcdef="}';

      expectRedacted(
          sanitizeDiagnostics(raw), 'aFakeButValidLookingWgKey0123456789abcdef=',
          what: 'the WireGuard private key');
    });

    test('a quoted pre-shared key is redacted', () {
      const raw = 'initialize outbound/wireguard[wg-out]: '
          '{"pre_shared_key":"psk0123456789abcdefghijklmnopqrstuvwxyz="}';

      expectRedacted(sanitizeDiagnostics(raw),
          'psk0123456789abcdefghijklmnopqrstuvwxyz=',
          what: 'the WireGuard pre-shared key');
    });

    test('a quoted Reality short id and public key are redacted', () {
      const raw = 'initialize outbound/vless[proxy]: tls: reality: '
          '{"short_id":"6ba85179e30d4fc2",'
          '"public_key":"Qq3RTvJKmXeGw4bYc1sZ2nA8pLdF5uHiO0TxWvNrEyM"}';

      final out = sanitizeDiagnostics(raw);

      expectRedacted(out, '6ba85179e30d4fc2', what: 'the Reality short id');
      expectRedacted(out, 'Qq3RTvJKmXeGw4bYc1sZ2nA8pLdF5uHiO0TxWvNrEyM',
          what: 'the Reality public key');
    });

    test('a quoted uuid is redacted', () {
      const raw = 'initialize outbound/vless[proxy]: '
          '{"uuid":"11111111-2222-3333-4444-555555555555"}';

      expectRedacted(sanitizeDiagnostics(raw),
          '11111111-2222-3333-4444-555555555555',
          what: 'the vless user id');
    });

    test('a quoted hysteria2/shadowsocks password is redacted', () {
      const raw = 'initialize outbound/hysteria2[hy2]: '
          '{"password":"c2hhZG93c29ja3NwYXNzd29yZA==","up_mbps":100}';

      expectRedacted(
          sanitizeDiagnostics(raw), 'c2hhZG93c29ja3NwYXNzd29yZA==',
          what: 'the hysteria2 password');
    });
  });

  group('the three redactors must agree', () {
    // The same tail is redacted by Dart (app log + on-screen error),
    // PacketTunnelProvider.redactSecrets (diagnostics.txt) and
    // SingboxMmPlugin.redactSecrets (support bundle). A key present in one list
    // and missing from another means the bundle is clean and the error screen
    // is not — or the reverse. This pins the shared key list from the Dart
    // side; the two Swift copies are checked by reading, since no Swift
    // compiler exists in this environment.
    const sharedKeys = <String>[
      'uuid',
      'password',
      'pbk',
      'sid',
      'short_id',
      'obfs-password',
      'obfs_password',
      'auth',
      'auth_str',
      'secret',
      'private_key',
      'pre_shared_key',
      'public_key',
    ];

    for (final key in sharedKeys) {
      test('"$key" is redacted in JSON form', () {
        final raw = '{"$key":"Sup3rSecretValue0123"}';

        expectRedacted(sanitizeDiagnostics(raw), 'Sup3rSecretValue0123',
            what: 'the JSON value of $key');
      });

      test('"$key" is redacted in URI form', () {
        final raw = 'link parse failed: ?$key=Sup3rSecretValue0123&type=tcp';

        expectRedacted(sanitizeDiagnostics(raw), 'Sup3rSecretValue0123',
            what: 'the URI value of $key');
      });
    }

    test('an unquoted JSON value is redacted too', () {
      // sing-box prints numbers and bare tokens unquoted; a value alternation
      // that only covered quoted strings would let those through.
      for (final raw in <String>[
        '{"password":12345678901234}',
        '{"secret":bareTokenValue}',
        '{"uuid":null}',
      ]) {
        final out = sanitizeDiagnostics(raw);
        expect(out, contains('<redacted>'), reason: 'unredacted: $raw → $out');
      }
    });

    test('whitespace around the JSON colon does not defeat it', () {
      for (final raw in <String>[
        '{"password" : "Sup3rSecretValue0123"}',
        '{"password":\t"Sup3rSecretValue0123"}',
        '{ "password"  :  "Sup3rSecretValue0123" }',
      ]) {
        expectRedacted(sanitizeDiagnostics(raw), 'Sup3rSecretValue0123',
            what: 'a value behind loose spacing');
      }
    });

    test('an escaped quote inside the value does not end it early', () {
      final out = sanitizeDiagnostics(r'{"password":"has\"quote\"inside"}');

      expect(out, isNot(contains('quote')),
          reason: 'stopping at the escaped quote would leave the tail of the '
              'secret in the log: $out');
    });

    test('the key match is exact, not a prefix', () {
      // "authority", "secretariat" and friends are ordinary diagnostic words.
      // A key list that matched prefixes would redact them and take the
      // surrounding sentence with them.
      final out = sanitizeDiagnostics(
          '{"authority":"grpc.example.com","password":"realSecret12345"}');

      expect(out, contains('grpc.example.com'),
          reason: 'authority is not a credential; redacting it removes the '
              'transport detail an engineer needs');
      expectRedacted(out, 'realSecret12345', what: 'the real credential');
    });
  });

  group('V26 — what the first pass missed', () {
    test('an entire base64 subscription does not pass through', () {
      // The exact V26 finding: /config's body is one base64 blob of vless://
      // links, and a diagnostic quoting it handed over every node at once.
      const blob = 'dmxlc3M6Ly8xMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1'
          'NTVAMjAzLjAuMTEzLjc6NDQzP3NlY3VyaXR5PXRscyN0ZXN0';
      final out = sanitizeDiagnostics('failed to parse subscription: $blob');

      expectRedacted(out, blob, what: 'the encoded subscription');
    });

    test('a bare IPv4 without a port is still a node address', () {
      final out =
          sanitizeDiagnostics('dial tcp 203.0.113.7: connection refused');

      expectRedacted(out, '203.0.113.7', what: 'the portless node address');
      expect(out, contains('connection refused'));
    });

    test('IPv6 literals are redacted, bracketed or bare', () {
      for (final raw in <String>[
        'dial tcp [2001:db8::42]:443: unreachable',
        'route added via 2400:cb00:2048:1::681c:83a',
        'bind on fdfe:dcba:9876::1 failed',
      ]) {
        final out = sanitizeDiagnostics(raw);
        expect(out, contains('<redacted-ip>'), reason: 'unredacted: $raw');
        expect(out, isNot(contains('2001:db8')),
            reason: 'an IPv6 is as much a node address as an IPv4: $out');
      }
    });

    test('timestamps and loopback survive the IPv6 rule', () {
      // `12:00:00` has the shape of an IPv6 candidate; the filter must tell
      // them apart or every log line loses its clock.
      const stamp = '[2026-07-28T12:00:00Z] INFO started';
      expect(sanitizeDiagnostics(stamp), stamp);

      const probe = 'watchdog probe ::1 alive, 127.0.0.1 reachable';
      expect(sanitizeDiagnostics(probe), probe,
          reason: 'loopback identifies the phone, not the panel — and it is '
              'half of every watchdog log');
    });

    test('an ss:// credential with a slash inside is caught', () {
      // ss:// userinfo is base64, and '/' is in the base64 alphabet — the
      // general credential rule stops at '/' and walked straight past it.
      const raw =
          'parse ss://YWVzLTEyOC1nY206cGFzc3dvcmQ/8x@203.0.113.7:8388 failed';
      final out = sanitizeDiagnostics(raw);

      expectRedacted(out, 'YWVzLTEyOC1nY206cGFzc3dvcmQ',
          what: 'the shadowsocks credential');
    });

    test('long hex runs are redacted — device keys, undashed uuids', () {
      const hex = '09b64c8deb42ddd2952d1982966872141528d6ddee1fc2853b92a96b'
          '7759763d';
      final out = sanitizeDiagnostics('device key: $hex');

      expectRedacted(out, hex, what: 'a 64-char hex identifier');
    });

    test('outbound tags and long words are not blobs', () {
      // The blob rule must not eat the very things support reads first.
      const raw = 'initialize outbound/shadowsocks[ss-out]: '
          'outbound/hysteria2[hy2-fr] configuration reloaded';

      expect(sanitizeDiagnostics(raw), raw);
    });

    test('the new passes are idempotent too', () {
      const raw = 'dial tcp [2001:db8::42]:443 from 203.0.113.7, key '
          '09b64c8deb42ddd2952d1982966872141528d6ddee1fc2853b92a96b7759763d';
      final once = sanitizeDiagnostics(raw);

      expect(sanitizeDiagnostics(once), once);
    });
  });

  group('the sanitiser stays usable', () {
    test('a realistic failing-start tail stays diagnosable', () {
      // The whole point of the tail. If redaction leaves nothing an engineer
      // can act on, the user is told to send the raw log instead and the
      // redactor has achieved nothing.
      const raw = 'FATAL[0003] start service: initialize outbound/vless'
          '[proxy-main]: decode config at 42: json: cannot unmarshal string '
          'into Go struct field Options.outbounds.tls of type bool\n'
          'INFO[0003] router: loaded 0 rule-set\n'
          'ERROR[0004] outbound/vless[proxy-main]: dial tcp: i/o timeout';

      final out = sanitizeDiagnostics(raw);

      expect(out, contains('start service'));
      expect(out, contains('outbound/vless[proxy-main]'),
          reason: 'the failing outbound tag is the first thing support looks '
              'at, and a tag is not a credential');
      expect(out, contains('decode config at 42'));
      expect(out, contains('Options.outbounds.tls'));
      expect(out, contains('i/o timeout'));
      expect(out, contains('router: loaded 0 rule-set'));
    });

    test('log levels, timestamps and line structure are untouched', () {
      const raw = '[2026-07-28T12:00:00Z] INFO sing-box started (version 1.10)';

      expect(sanitizeDiagnostics(raw), raw,
          reason: 'a line with no secret in it must come through unchanged');
    });

    test('sanitising twice changes nothing more, on JSON too', () {
      const raw = 'decode config: {"uuid":"11111111-2222-3333-4444-'
          '555555555555","password":"pw012345678901","short_id":"6ba85179"}'
          ' from 203.0.113.7:443';

      final once = sanitizeDiagnostics(raw);

      expect(sanitizeDiagnostics(once), once,
          reason: 'the JSON rule rewrites into a shape it also matches, so a '
              'second pass must be a fixed point');
      expect(sanitizeDiagnostics(sanitizeDiagnostics(once)), once);
    });

    test('the surrounding diagnostic text survives', () {
      // Over-redaction is its own failure mode: a bundle of `<redacted>` tells
      // support nothing and the user will send the raw log instead.
      const raw = 'start service: initialize inbound/tun[tun-in]: '
          'configure tun interface: operation not permitted';

      final out = sanitizeDiagnostics(raw);

      expect(out, contains('initialize inbound/tun'));
      expect(out, contains('operation not permitted'));
    });

    test('sanitising twice changes nothing more', () {
      const raw = 'dial vless://11111111-2222-3333-4444-555555555555'
          '@203.0.113.7:443: i/o timeout';

      final once = sanitizeDiagnostics(raw);

      expect(sanitizeDiagnostics(once), once,
          reason: 'the tail is sanitised on more than one path; a '
              'non-idempotent pass would mangle already-clean text');
    });

    test('empty and whitespace input are handled', () {
      expect(sanitizeDiagnostics(''), '');
      expect(sanitizeDiagnostics('   '), '   ');
    });

    test('a multi-line stderr tail is sanitised on every line', () {
      final raw = <String>[
        'FATAL[0001] start service: decode config at 3',
        '{"uuid":"22222222-3333-4444-5555-666666666666"}',
        'INFO[0002] outbound/vless[proxy]: 198.51.100.9:8443',
      ].join('\n');

      final out = sanitizeDiagnostics(raw);

      expectRedacted(out, '22222222-3333-4444-5555-666666666666',
          what: 'a uuid on a later line');
      expectRedacted(out, '198.51.100.9:8443',
          what: 'an endpoint on a later line');
    });
  });
}
