import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/account_status.dart';
import '../models/auth_session.dart';
import '../models/pairing.dart';
import '../models/server_country.dart';
import '../utils/country_flag.dart';
import 'app_logger.dart';
import 'pinned_http_client.dart';
import 'vless_config_parser.dart';

/// A request the BFF answered with something other than success.
///
/// Deliberately carries no prose: what the user reads has to be localized, and
/// the app's default language is Russian. [code] is for logs and for the UI to
/// switch on; [statusCode] is what callers actually branch on (401 auth, 402
/// lapsed subscription, 409 conflict, 503 no capacity).
class ApiException implements Exception {
  ApiException(this.code, {this.statusCode});

  /// Machine-readable identifier of the failing call, e.g. `servers_failed`.
  final String code;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $code';
}

class ApiClient {
  ApiClient({
    http.Client? httpClient,
    String? baseUrl,
    this.readAccessToken,
    this.onUnauthorized,
    this.readSessionMintedAt,
  })  : _httpClient = httpClient ?? createBffHttpClient(baseUrl: baseUrl),
        _baseUrl = baseUrl ?? bffBaseUrl;

  final http.Client _httpClient;
  final String _baseUrl;

  /// Supplies the access token to use *right now*.
  ///
  /// A provider rather than an argument because callers hold on to this client
  /// for a long time — the location screen for as long as it is open, the
  /// tunnel's session watchdog for hours — and a token captured when they
  /// started is stale by the time they use it. Every stale token costs a 401
  /// and a refresh-token rotation, and every rotation is a chance to lose the
  /// session (see AuthController).
  Future<String?> Function()? readAccessToken;

  /// Called when an authed request gets a 401 (expired access token). Should
  /// return a fresh access token (via `/auth/refresh`) so the request can be
  /// retried once, or null if the session can't be renewed.
  Future<String?> Function()? onUnauthorized;

  /// When the current session was last *replaced* (new key, trial, pairing).
  /// Cached subscription data belongs to the session it was fetched under, so a
  /// change here throws it away rather than letting a reconnect run on the
  /// previous key's subscription.
  DateTime? Function()? readSessionMintedAt;

  /// Ceiling on every authed request. Without it these calls inherit the OS TCP
  /// timeout, and since the app's own traffic goes through the tunnel, a request
  /// issued while a tunnel is dying (switching location, leaving a dead node)
  /// hangs for over two minutes with the UI stuck on "Connecting" — measured at
  /// 2 m 16 s before this was added. Failing fast is what lets [getConfig] fall
  /// back to the cached subscription and the reconnect proceed.
  static const _requestTimeout = Duration(seconds: 15);

  /// How long `/servers` and `/config` answers are reused.
  ///
  /// Opening the app, opening the location picker and tapping Connect used to
  /// be five requests for two answers that cannot change between them; a
  /// subscription changes when the user's key does, which [readSessionMintedAt]
  /// already reports.
  static const _cacheTtl = Duration(minutes: 5);

  /// Releases the keep-alive connection pool. The app shares one client, so
  /// this is only for its own teardown and for tests.
  void close() => _httpClient.close();

  /// GET with a Bearer token that transparently refreshes the access token once
  /// on 401 and retries. 402 (lapsed subscription) is left for the caller to
  /// surface — it is not an auth failure.
  Future<http.Response> _authedGet(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    log.d('GET $path');
    final accessToken = await readAccessToken?.call() ?? '';
    var response = await _httpClient
        .get(uri, headers: {'Authorization': 'Bearer $accessToken'})
        .timeout(_requestTimeout);
    if (response.statusCode == 401 && onUnauthorized != null) {
      log.i('GET $path → 401, refreshing access token and retrying');
      final fresh = await onUnauthorized!();
      if (fresh != null) {
        response = await _httpClient
            .get(uri, headers: {'Authorization': 'Bearer $fresh'})
            .timeout(_requestTimeout);
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
      throw ApiException('refresh_failed', statusCode: response.statusCode);
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
      // The 409 body distinguishes "no slots left" from the bare conflict older
      // servers return, so the app can name the real reason.
      throw ApiException(_errorCode(response.body) ?? 'token_exchange_failed',
          statusCode: response.statusCode);
    }

    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// The `error` field of an error body, or null if there isn't one — every
  /// failure path here has to survive an HTML error page from a proxy.
  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['error'];
        if (code is String && code.isNotEmpty) return code;
      }
    } catch (_) {/* not JSON */}
    return null;
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
      throw ApiException('trial_failed', statusCode: response.statusCode);
    }

    log.i('Trial granted for $platform');
    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Starts a pairing attempt; the app shows the code/QR and opens the bot.
  ///
  /// [attestationToken] identifies this phone so pairing counts against the
  /// subscription's device slots, exactly as pasting a code does. Optional
  /// because the server accepts a body-less call from older builds — but leaving
  /// it out means connecting through Telegram ignores the device limit.
  Future<PairingStart> startPairing({String? attestationToken}) async {
    final response = await _httpClient
        .post(
          Uri.parse('$_baseUrl/pair/start'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'attestationToken': ?attestationToken}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      log.w('POST /pair/start → ${response.statusCode}');
      throw ApiException('pair_start_failed', statusCode: response.statusCode);
    }

    log.i('Pairing started');
    return PairingStart.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Polls pairing status; returns completed with a session once the bot links.
  Future<PairingStatus> pollPairing(String pollToken) async {
    final uri = Uri.parse('$_baseUrl/pair/status')
        .replace(queryParameters: <String, String>{'pollToken': pollToken});
    final response =
        await _httpClient.get(uri).timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      return const PairingStatus(PairingState.expired);
    }
    if (response.statusCode != 200) {
      throw ApiException('pair_status_failed', statusCode: response.statusCode);
    }

    return PairingStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// [force] skips the cache — for the explicit refresh action, where the
  /// point of the tap is to go and ask.
  Future<List<ServerCountry>> getServers({bool force = false}) async {
    _dropStaleCaches();
    final cached = force ? null : _servers?.take();
    if (cached != null) return cached;

    final response = await _authedGet('/servers');

    if (response.statusCode != 200) {
      throw ApiException('servers_failed', statusCode: response.statusCode);
    }

    final body = jsonDecode(response.body) as List<dynamic>;
    final servers = body
        .map((e) => ServerCountry.fromJson(e as Map<String, dynamic>))
        .toList();
    _servers = _Cached(servers, _mintedAt);
    return servers;
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
  Future<List<ServerCountry>> getUsableServers({bool force = false}) async {
    final servers = await getServers(force: force);
    List<ConfigEntry> entries;
    try {
      final (content, _) = await getConfig(force: force);
      entries = parseConfigEntries(content);
    } on ApiException catch (e) {
      // 401 and 402 are the server telling us about the session, not about the
      // subscription's contents. Swallowing them here is what used to hide a
      // lapsed subscription behind a full server list, so the user only met it
      // as a raw error after tapping Connect instead of on the renew screen.
      if (e.statusCode == 401 || e.statusCode == 402) rethrow;
      return servers;
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
          unknownCountryCode;
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

  Future<AccountStatus> getMe() async {
    final response = await _authedGet('/me');

    if (response.statusCode != 200) {
      throw ApiException('account_status_failed', statusCode: response.statusCode);
    }

    return AccountStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Server list and subscription of the current session, reused within
  /// [_cacheTtl]. The subscription doubles as the offline fallback below.
  _Cached<List<ServerCountry>>? _servers;
  _Cached<(String, String)>? _config;

  DateTime? get _mintedAt => readSessionMintedAt?.call();

  /// Drops everything cached under a superseded session.
  void _dropStaleCaches() {
    final minted = _mintedAt;
    if (_servers != null && _servers!.mintedAt != minted) _servers = null;
    if (_config != null && _config!.mintedAt != minted) _config = null;
  }

  Future<(String content, String contentType)> getConfig({
    bool force = false,
  }) async {
    _dropStaleCaches();
    final cached = force ? null : _config?.take();
    if (cached != null) return cached;
    try {
      final response = await _authedGet('/config');

      if (response.statusCode != 200) {
        throw ApiException('config_failed', statusCode: response.statusCode);
      }

      final contentType = response.headers['content-type'] ?? 'text/plain';
      final value = (response.body, contentType);
      _config = _Cached(value, _mintedAt);
      return value;
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
      final stale = _config;
      if (e is ApiException || stale == null) rethrow;
      log.w('GET /config unreachable ($e) — reusing the last known subscription');
      return stale.value;
    }
  }
}

/// A value with the session it belongs to and the moment it was taken.
class _Cached<T> {
  _Cached(this.value, this.mintedAt) : _at = DateTime.now();

  final T value;
  final DateTime? mintedAt;
  final DateTime _at;

  bool get _fresh => DateTime.now().difference(_at) < ApiClient._cacheTtl;

  /// The value while it is still worth reusing, otherwise null.
  T? take() => _fresh ? value : null;
}
