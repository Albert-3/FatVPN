// Certificate pinning — docs/improvement-plan-app-android.md §"Cert pinning",
// docs/open-bugs.md 4.2.
//
// The BFF carries a 90-day refresh token and the subscription id, and until now
// any CA in the device's store could vouch for api.fatklyuchi.space. These tests
// hold two ends of the same wire: that the bundle really is the published ISRG
// roots (nobody swapped a certificate into it), and that a server signed by
// anyone else is actually refused — checked against a real TLS handshake with a
// real server, not by inspecting configuration.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/config/ca_pins.dart';
import 'package:fatvpn_app/services/pinned_http_client.dart';

/// SHA-256 of each root as `letsencrypt.org` publishes it. X1's and X2's have
/// been public for years and can be checked against any independent source;
/// all four were read off the downloaded files with `openssl x509 -fingerprint
/// -sha256` on 2026-08-02.
const _publishedRoots = <String, String>{
  'ISRG Root X1':
      '96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6',
  'ISRG Root X2':
      '69:72:9B:8E:15:A8:6E:FC:17:7A:57:AF:B7:17:1D:FC:64:AD:D2:8C:2F:CA:8C:F1:50:7E:34:45:3C:CB:14:70',
  'ISRG Root YE':
      'E1:4F:FC:AD:5B:00:25:73:10:06:CA:A4:3A:12:1A:22:D8:E9:70:0F:4F:B9:CF:85:2F:02:A7:08:AA:5D:56:66',
  'ISRG Root YR':
      'E5:7B:7E:6F:15:0C:41:91:02:E8:D5:C0:55:72:9F:F9:67:B9:D1:A8:29:BF:00:CE:C8:9C:A6:04:EB:F4:A8:6F',
};

/// The DER bytes of every certificate in a PEM bundle.
List<List<int>> _derBlocks(String pem) {
  final blocks = <List<int>>[];
  final re = RegExp(
    r'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
    dotAll: true,
  );
  for (final m in re.allMatches(pem)) {
    blocks.add(base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), '')));
  }
  return blocks;
}

String _fingerprint(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join(':')
    .toUpperCase();

/// A TLS server on loopback holding a certificate from a CA that exists nowhere
/// but `test/fixtures/tls`. Stands in for anything that is not the real BFF: a
/// corporate middlebox, a profile someone installed on an iPhone, a CA that has
/// been coerced.
Future<HttpServer> _serverSignedByAnotherCa() async {
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChain('test/fixtures/tls/other-ca-server.pem')
    ..usePrivateKey('test/fixtures/tls/other-ca-server-key.pem');
  final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4, 0, context);
  server.listen((request) {
    request.response
      ..statusCode = 200
      ..write('ok');
    request.response.close();
  });
  return server;
}

void main() {
  test('the bundle is exactly the four published ISRG roots', () {
    final blocks = _derBlocks(letsEncryptRootsPem);

    expect(blocks, hasLength(_publishedRoots.length),
        reason: 'a certificate was added to or removed from the bundle');
    expect(
      blocks.map(_fingerprint).toSet(),
      _publishedRoots.values.toSet(),
      reason: 'the bundle no longer matches what letsencrypt.org publishes — '
          'a root cannot be edited here without saying so out loud',
    );
  });

  test('a server signed by another CA is refused', () async {
    final server = await _serverSignedByAnotherCa();
    addTearDown(() => server.close(force: true));

    // The client the app actually builds for the BFF, pointed at that server.
    final client = createBffHttpClient();
    addTearDown(client.close);

    await expectLater(
      client.get(Uri.parse('https://localhost:${server.port}/')),
      throwsA(isA<HandshakeException>()),
      reason: 'this is the whole feature: an unpinned client would get 200 here',
    );
  });

  test('the same server is reachable when its own CA is the pinned one', () async {
    // Not a property of the app — a check on this test. Without it, "refused"
    // above would also pass if the server never came up, if the port were wrong,
    // or if loopback TLS did not work at all on the machine, and the pin would
    // look proven by an accident.
    final server = await _serverSignedByAnotherCa();
    addTearDown(() => server.close(force: true));

    final trustsFixture = HttpClient(
        context: SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(
              File('test/fixtures/tls/other-ca.pem').readAsBytesSync()));
    addTearDown(() => trustsFixture.close(force: true));

    final request =
        await trustsFixture.getUrl(Uri.parse('https://localhost:${server.port}/'));
    final response = await request.close();

    expect(response.statusCode, 200);
  });
}

// Deliberately not tested here: that `withTrustedRoots: false` excludes the
// *platform's* store. Proving it needs a certificate from a public CA and a
// server holding its private key, which is the one thing a fixture cannot be.
// It shows up on a device instead — TA17 in docs/release-test-checklist.md — as
// "a phone with an intercepting proxy installed still cannot see the traffic".
