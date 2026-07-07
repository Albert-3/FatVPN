import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/account_status.dart';
import '../models/auth_session.dart';
import '../models/pairing.dart';
import '../models/server_country.dart';
import 'vless_config_parser.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({
    http.Client? httpClient,
    String? baseUrl,
    Future<String?> Function()? onUnauthorized,
  })  : _httpClient = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? bffBaseUrl,
        // ignore: prefer_initializing_formals -- private field, public param name
        _onUnauthorized = onUnauthorized;

  final http.Client _httpClient;
  final String _baseUrl;

  /// Called when an authed request gets a 401 (expired access token). Should
  /// return a fresh access token (via `/auth/refresh`) so the request can be
  /// retried once, or null if the session can't be renewed.
  final Future<String?> Function()? _onUnauthorized;

  /// GET with a Bearer token that transparently refreshes the access token once
  /// on 401 and retries. 402 (lapsed subscription) is left for the caller to
  /// surface — it is not an auth failure.
  Future<http.Response> _authedGet(String path, String accessToken) async {
    final uri = Uri.parse('$_baseUrl$path');
    var response =
        await _httpClient.get(uri, headers: {'Authorization': 'Bearer $accessToken'});
    if (response.statusCode == 401 && _onUnauthorized != null) {
      final fresh = await _onUnauthorized();
      if (fresh != null) {
        response =
            await _httpClient.get(uri, headers: {'Authorization': 'Bearer $fresh'});
      }
    }
    return response;
  }

  /// Exchanges a refresh token for a fresh session (rotating the refresh token).
  Future<AuthSession> refreshSession(String refreshToken) async {
    final response = await _httpClient
        .post(
          Uri.parse('$_baseUrl/auth/refresh'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refreshToken': refreshToken}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw ApiException('Failed to refresh session', statusCode: response.statusCode);
    }

    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Best-effort refresh-token revocation on sign-out. Never throws.
  Future<void> logout(String refreshToken) async {
    try {
      await _httpClient
          .post(
            Uri.parse('$_baseUrl/auth/logout'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refreshToken': refreshToken}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Revocation is best-effort; the token still expires on its own.
    }
  }

  Future<AuthSession> exchangeToken(String shortToken) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/auth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'shortToken': shortToken}),
    );

    if (response.statusCode != 200) {
      throw ApiException(
        'Token exchange failed',
        statusCode: response.statusCode,
      );
    }

    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Requests a free trial for this device. [attestationToken] is the stable
  /// device key; [platform] is "android" or "ios". 409 = trial already used by
  /// this device, 503 = trial pool exhausted (surfaced via [ApiException.statusCode]).
  Future<AuthSession> startTrial(String attestationToken, String platform) async {
    final response = await _httpClient
        .post(
          Uri.parse('$_baseUrl/trial'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'attestationToken': attestationToken, 'platform': platform}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw ApiException('Failed to start trial', statusCode: response.statusCode);
    }

    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Starts a pairing attempt; the app shows the code/QR and opens the bot.
  Future<PairingStart> startPairing() async {
    final response = await _httpClient
        .post(Uri.parse('$_baseUrl/pair/start'))
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw ApiException('Failed to start pairing', statusCode: response.statusCode);
    }

    return PairingStart.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Polls pairing status; returns completed with a session once the bot links.
  Future<PairingStatus> pollPairing(String pollToken) async {
    final response = await _httpClient
        .get(Uri.parse('$_baseUrl/pair/status?pollToken=$pollToken'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      return const PairingStatus(PairingState.expired);
    }
    if (response.statusCode != 200) {
      throw ApiException('Failed to poll pairing', statusCode: response.statusCode);
    }

    return PairingStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<ServerCountry>> getServers(String accessToken) async {
    final response = await _authedGet('/servers', accessToken);

    if (response.statusCode != 200) {
      throw ApiException('Failed to load servers', statusCode: response.statusCode);
    }

    final body = jsonDecode(response.body) as List<dynamic>;
    return body
        .map((e) => ServerCountry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Like [getServers] but keeps only the countries/nodes actually present in
  /// this subscription's `/config` — `/servers` lists every Remnawave node
  /// regardless of squad, so offering the others just fails at connect time
  /// ("No available node in this subscription"). Falls back to the full list if
  /// the config can't be fetched.
  Future<List<ServerCountry>> getUsableServers(String accessToken) async {
    final servers = await getServers(accessToken);
    List<String> uris;
    try {
      final (content, _) = await getConfig(accessToken);
      uris = parseVlessUris(content);
    } catch (_) {
      return servers;
    }
    if (uris.isEmpty) return servers;

    final usable = <ServerCountry>[];
    for (final country in servers) {
      final nodes =
          country.nodes.where((n) => findUriForNode(uris, n) != null).toList();
      if (nodes.isNotEmpty) {
        usable.add(ServerCountry(
          country: country.country,
          flag: country.flag,
          nodeCount: nodes.length,
          nodes: nodes,
        ));
      }
    }
    return usable.isEmpty ? servers : usable;
  }

  Future<AccountStatus> getMe(String accessToken) async {
    final response = await _authedGet('/me', accessToken);

    if (response.statusCode != 200) {
      throw ApiException('Failed to load account status', statusCode: response.statusCode);
    }

    return AccountStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<(String content, String contentType)> getConfig(String accessToken) async {
    final response = await _authedGet('/config', accessToken);

    if (response.statusCode != 200) {
      throw ApiException('Failed to load config', statusCode: response.statusCode);
    }

    final contentType = response.headers['content-type'] ?? 'text/plain';
    return (response.body, contentType);
  }
}
