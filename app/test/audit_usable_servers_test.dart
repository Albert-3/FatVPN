// Regression test for docs/improvement-plan-app-android.md §2.9 —
// "getUsableServers глотает 401/402".
//
// `getUsableServers` wraps the `/config` fetch in `catch (_)`, which also
// catches `ApiException(402)`. The 402 branch in HomeScreen (→ renew screen)
// therefore never fires for /config: a user whose subscription lapsed sees a
// server list, taps Connect, and gets a raw error instead of the renew screen.
//
// The network-level fallback (`/config` unreachable → return the raw /servers
// list) is deliberate and must keep working — that is what lets a reconnect
// proceed while a dying tunnel is swallowing the app's own requests.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fatvpn_app/services/api_client.dart';

final _serversBody = jsonEncode(<Object?>[
  <String, Object?>{
    'country': 'DE',
    'flag': 'DE',
    'nodeCount': 1,
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'n1',
        'name': 'DE-1',
        'address': 'de1.example.com',
        'port': 2222,
        'usersOnline': 3,
      },
    ],
  },
]);

final _configBody = base64.encode(utf8.encode(
    'vless://11111111-2222-3333-4444-555555555555@de1.example.com:443#DE-1'));

ApiClient _clientWhereConfig(Future<http.Response> Function() config) {
  return ApiClient(
    baseUrl: 'http://bff.test',
    readAccessToken: () async => 'access-token',
    httpClient: MockClient((request) async {
      if (request.url.path == '/servers') {
        return http.Response(_serversBody, 200);
      }
      if (request.url.path == '/config') return config();
      return http.Response('unexpected ${request.url}', 404);
    }),
  );
}

void main() {
  test('402 on /config is rethrown, not turned into a /servers fallback',
      () async {
    final client = _clientWhereConfig(() async => http.Response('', 402));

    await expectLater(
      client.getUsableServers(),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 402)),
    );
  });

  test('401 on /config is rethrown so the session can be renewed', () async {
    final client = _clientWhereConfig(() async => http.Response('', 401));

    await expectLater(
      client.getUsableServers(),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('a network failure on /config still falls back to /servers', () async {
    final client = _clientWhereConfig(
        () async => throw http.ClientException('connection reset'));

    final servers = await client.getUsableServers();

    expect(servers, hasLength(1));
    expect(servers.single.country, 'DE');
  });

  test('a healthy /config builds the list from the subscription', () async {
    final client = _clientWhereConfig(() async => http.Response(_configBody, 200));

    final servers = await client.getUsableServers();

    expect(servers, hasLength(1));
    expect(servers.single.nodes.single.configUri, contains('de1.example.com'));
  });

  test('a 500 on /config is not swallowed either', () async {
    // Any answer *from the server* is the truth about this subscription; only
    // "we could not ask" justifies falling back.
    final client = _clientWhereConfig(() async => http.Response('boom', 500));

    await expectLater(
      client.getUsableServers(),
      throwsA(isA<ApiException>()),
    );
  }, skip: 'Only 401/402 are required by §2.9; documents the open question of '
      'whether 5xx should fall back to /servers.');
}
