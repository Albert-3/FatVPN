import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../models/auth_session.dart';
import 'api_client.dart';
import 'token_storage.dart';

/// Owns the current [AuthSession] and keeps it updated from two sources:
/// a token already persisted on disk, and short tokens arriving via the
/// `fatvpn://token/<shortToken>` deep link sent by the Telegram bot.
class AuthController extends ChangeNotifier {
  AuthController({ApiClient? apiClient, TokenStorage? tokenStorage, AppLinks? appLinks})
      : _apiClient = apiClient ?? ApiClient(),
        _tokenStorage = tokenStorage ?? TokenStorage(),
        _appLinks = appLinks ?? AppLinks();

  final ApiClient _apiClient;
  final TokenStorage _tokenStorage;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  AuthSession? _session;
  bool _initializing = true;
  String? _error;

  AuthSession? get session => _session;
  bool get initializing => _initializing;
  bool get isAuthenticated => _session != null && !_session!.isExpired;
  String? get error => _error;

  Future<void> start() async {
    final stored = await _tokenStorage.read();
    if (stored != null && !stored.isExpired) {
      _session = stored;
    }
    _initializing = false;
    notifyListeners();

    _linkSubscription = _appLinks.uriLinkStream.listen(_handleUri);
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleUri(initialUri);
    }
  }

  Future<void> _handleUri(Uri uri) async {
    if (uri.scheme != deepLinkScheme) {
      return;
    }
    final shortToken = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uri.host;
    if (shortToken.isEmpty) {
      return;
    }
    await exchangeShortToken(shortToken);
  }

  Future<void> exchangeShortToken(String shortToken) async {
    try {
      _error = null;
      final session = await _apiClient.exchangeToken(shortToken);
      await _tokenStorage.save(session);
      _session = session;
      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
    } catch (_) {
      _error = 'Could not reach the server. Check your connection and try again.';
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await _tokenStorage.clear();
    _session = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }
}
