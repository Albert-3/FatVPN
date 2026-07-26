import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/account_status.dart';
import '../models/auth_session.dart';
import '../models/pairing.dart';
import '../models/server_country.dart';
import '../utils/country_flag.dart';
import 'app_logger.dart';
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
    log.d('GET $path');
    var response =
        await _httpClient.get(uri, headers: {'Authorization': 'Bearer $accessToken'});
    if (response.statusCode == 401 && _onUnauthorized != null) {
      log.i('GET $path → 401, refreshing access token and retrying');
      final fresh = await _onUnauthorized();
      if (fresh != null) {
        response =
            await _httpClient.get(uri, headers: {'Authorization': 'Bearer $fresh'});
      }
    }
    if (response.statusCode >= 400) {
      log.w('GET $path → ${response.statusCode}');
    } else {
      log.d('GET $path → ${response.statusCode}');
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
      log.w('POST /auth/refresh → ${response.statusCode}');
      throw ApiException('Failed to refresh session', statusCode: response.statusCode);
    }

    log.i('Session refreshed (token rotated)');
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

  /// Exchanges a subscription key for a session. [attestationToken] is the
  /// stable per-install device key; the BFF binds the key to the first device
  /// (one key = one phone) and returns 409 if a different device presents it.
  Future<AuthSession> exchangeToken(String shortToken, String attestationToken) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/auth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'shortToken': shortToken, 'attestationToken': attestationToken}),
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
      log.w('POST /trial → ${response.statusCode}');
      throw ApiException('Failed to start trial', statusCode: response.statusCode);
    }

    log.i('Trial granted for $platform');
    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Starts a pairing attempt; the app shows the code/QR and opens the bot.
  Future<PairingStart> startPairing() async {
    final response = await _httpClient
        .post(Uri.parse('$_baseUrl/pair/start'))
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      log.w('POST /pair/start → ${response.statusCode}');
      throw ApiException('Failed to start pairing', statusCode: response.statusCode);
    }

    log.i('Pairing started');
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

  /// The servers this subscription can actually reach.
  ///
  /// Built from `/config`, not from `/servers`. The subscription is the only
  /// authoritative answer to "what can this user connect to": every entry in it
  /// is connectable by definition, whereas `/servers` lists Remnawave *nodes*,
  /// which is a different entity from the *hosts* the subscription is generated
  /// from. A node is the machine the panel manages; a host is a client-facing
  /// endpoint (frequently a domain, or a CDN front) and several can sit on one
  /// node. The two only share an address when a host happens to be published on
  /// its node's bare address.
  ///
  /// This used to be an intersection keyed on that address, which silently hid
  /// every host that didn't match one — the Hysteria2 entries (published on
  /// their own `h*-**.arpozan.cloud` domains, spliced in by the BFF's
  /// SubscriptionAugmenter) and any node fronted by a domain simply never
  /// appeared, and could never be picked at connect time either.
  ///
  /// `/servers` is now only an enrichment source: where a host does line up
  /// with a node, we take that node's country grouping and online count.
  /// Otherwise the country comes from the flag emoji in the host's own remark.
  /// Falls back to the raw `/servers` list if the config can't be fetched.
  Future<List<ServerCountry>> getUsableServers(String accessToken) async {
    final servers = await getServers(accessToken);
    List<ConfigEntry> entries;
    try {
      final (content, _) = await getConfig(accessToken);
      entries = parseConfigEntries(content);
    } catch (_) {
      return servers;
    }
    if (entries.isEmpty) return servers;

    // address → (country code, node) for the hosts that do map onto a node.
    final nodeByAddress = <String, (String, ServerNode)>{};
    for (final country in servers) {
      for (final node in country.nodes) {
        nodeByAddress.putIfAbsent(node.address, () => (country.country, node));
      }
    }

    final byCountry = <String, List<ServerNode>>{};
    for (final entry in entries) {
      final match = nodeByAddress[entry.host];
      final country = match?.$1 ??
          countryCodeFromFlagEmoji(entry.tag) ??
          _unknownCountry;
      // Keep the node's own identity/name when we have one, so nodes that were
      // already listed look exactly as before; otherwise fall back to the
      // host's remark, which is all the panel gives us for this entry.
      final node = match?.$2.withConfigUri(entry.uri) ??
          ServerNode(
            id: entry.uri,
            name: entry.tag.isEmpty ? entry.host : entry.tag,
            address: entry.host,
            port: entry.port,
            // No node backs this host, so the panel reports no client count for
            // it. Unknown, not zero — see [ServerNode.usersOnline].
            usersOnline: null,
            configUri: entry.uri,
          );
      byCountry.putIfAbsent(country, () => <ServerNode>[]).add(node);
    }

    final usable = byCountry.entries
        .map((e) => ServerCountry(
              country: e.key,
              flag: e.key,
              nodeCount: e.value.length,
              nodes: e.value,
            ))
        .toList();
    return usable.isEmpty ? servers : usable;
  }

  /// Bucket for a subscription entry whose remark carries no flag emoji and
  /// whose host matches no node — rare, but it must stay visible rather than be
  /// dropped, which is exactly the failure this method exists to undo.
  static const _unknownCountry = '??';

  Future<AccountStatus> getMe(String accessToken) async {
    final response = await _authedGet('/me', accessToken);

    if (response.statusCode != 200) {
      throw ApiException('Failed to load account status', statusCode: response.statusCode);
    }

    return AccountStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Last subscription we successfully fetched, kept so a reconnect can proceed
  /// when the network is momentarily unusable. See [getConfig].
  (String, String)? _lastGoodConfig;

  Future<(String content, String contentType)> getConfig(String accessToken) async {
    try {
      final response = await _authedGet('/config', accessToken);

      if (response.statusCode != 200) {
        throw ApiException('Failed to load config', statusCode: response.statusCode);
      }

      final contentType = response.headers['content-type'] ?? 'text/plain';
      return _lastGoodConfig = (response.body, contentType);
    } catch (e) {
      // Falling back matters most in the one situation where this call is least
      // likely to succeed: the user is on a server that stopped passing traffic
      // and is trying to switch away from it. The app's own requests travel
      // through the tunnel, so the dying one takes them down with it — and
      // without the previous subscription there would be nothing to reconnect
      // with, stranding the user on the broken server.
      //
      // Safe to reuse: a subscription changes when the user's key does, not
      // between two taps, and a wrong guess only costs one failed connect that
      // the next successful fetch corrects. Only network-level failures qualify
      // — an ApiException is the server talking, and its answer is the truth.
      final cached = _lastGoodConfig;
      if (e is ApiException || cached == null) rethrow;
      log.w('GET /config unreachable ($e) — reusing the last known subscription');
      return cached;
    }
  }
}
