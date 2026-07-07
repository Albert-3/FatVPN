import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../models/auth_session.dart';
import '../models/pairing.dart';
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

  PairingStart? _pairing;
  Timer? _pollTimer;
  bool _pairingBusy = false;
  bool _pollInFlight = false;
  bool _trialBusy = false;
  bool _trialAvailable = false;
  bool _autoConnectRequested = false;

  AuthSession? get session => _session;
  bool get initializing => _initializing;
  bool get isAuthenticated => _session != null && !_session!.isExpired;
  String? get error => _error;

  /// True while a trial request is in flight (for the onboarding button spinner).
  bool get trialBusy => _trialBusy;

  /// Read-once flag: true right after a trial was granted so [HomeScreen] can
  /// auto-connect the tunnel once (so a store user reaches Telegram without a
  /// manual tap). Consuming it clears it.
  bool consumeAutoConnect() {
    if (!_autoConnectRequested) return false;
    _autoConnectRequested = false;
    return true;
  }

  /// Whether this device is still eligible for a free trial (hasn't used one
  /// yet). Drives whether the onboarding shows the "3 days free" button — a
  /// device that already had its trial only sees the Telegram / key options.
  bool get trialAvailable => _trialAvailable;

  /// Pairing code to show/QR-encode, or null while none is active.
  String? get pairCode => _pairing?.pairCode;

  /// Telegram deep link that carries the pairing code into the bot.
  Uri? get telegramPairUri =>
      _pairing == null ? null : telegramPairLink(_pairing!.pairCode);

  /// True while a pairing code exists and we're polling for completion.
  bool get pairingActive => _pairing != null;

  Future<void> start() async {
    final stored = await _tokenStorage.read();
    if (stored != null && !stored.isExpired) {
      _session = stored;
    }
    // Trial button shows only for a device that hasn't used its trial yet.
    _trialAvailable = !await _tokenStorage.hasAttemptedAutoTrial();
    _initializing = false;
    notifyListeners();

    _linkSubscription = _appLinks.uriLinkStream.listen(_handleUri);
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleUri(initialUri);
    }
  }

  /// Core trial grant shared by the onboarding button. Throws [ApiException]
  /// on non-200 so callers can react to 409/503. On success requests a one-off
  /// auto-connect so the user is online immediately.
  Future<void> _grantTrial() async {
    final deviceKey = await _tokenStorage.readOrCreateDeviceKey();
    final platform =
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final session = await _apiClient.startTrial(deviceKey, platform);
    _session = session;
    _trialAvailable = false;
    _autoConnectRequested = true;
    notifyListeners();
    unawaited(_tokenStorage.save(session).catchError((_) {}));
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

  /// Requests a free trial for this device and logs in on success. Error
  /// messages are passed in by the caller so they can be localized.
  Future<void> requestTrial({
    required String conflictMessage,
    required String noCapacityMessage,
    required String genericMessage,
  }) async {
    if (_trialBusy) return;
    _trialBusy = true;
    _error = null;
    notifyListeners();

    try {
      await _grantTrial();
      await _tokenStorage.markAutoTrialAttempted();
    } on ApiException catch (e) {
      _error = switch (e.statusCode) {
        409 => conflictMessage,
        503 => noCapacityMessage,
        _ => genericMessage,
      };
      if (e.statusCode == 409) {
        // Device already used its trial — hide the button and remember it.
        _trialAvailable = false;
        await _tokenStorage.markAutoTrialAttempted();
      }
      notifyListeners();
    } catch (_) {
      _error = genericMessage;
      notifyListeners();
    } finally {
      _trialBusy = false;
      notifyListeners();
    }
  }

  /// Requests a fresh pairing code and starts polling for completion. Safe to
  /// call again to retry after a code expires.
  Future<void> startPairing() async {
    if (_pairingBusy) return;
    _pairingBusy = true;
    _pollTimer?.cancel();
    _pairing = null;
    _error = null;
    notifyListeners();

    try {
      _pairing = await _apiClient.startPairing();
      notifyListeners();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
    } catch (_) {
      _error = 'Could not reach the server. Check your connection and try again.';
      notifyListeners();
    } finally {
      _pairingBusy = false;
    }
  }

  Future<void> _pollOnce() async {
    // Guard against overlapping ticks so a completion is handled exactly once.
    if (_pollInFlight) return;
    final pairing = _pairing;
    if (pairing == null) return;
    _pollInFlight = true;

    try {
      final status = await _apiClient.pollPairing(pairing.pollToken);
      switch (status.state) {
        case PairingState.completed:
          _pollTimer?.cancel();
          _pollTimer = null;
          _pairing = null;
          _session = status.session;
          // Transition the UI first; persistence is best-effort so a slow or
          // failing secure-storage write can't strand the user on this screen.
          notifyListeners();
          unawaited(_tokenStorage.save(status.session!).catchError((_) {}));
        case PairingState.expired:
          _pollTimer?.cancel();
          _pollTimer = null;
          _pairing = null;
          _error = 'Pairing code expired. Tap to get a new one.';
          notifyListeners();
        case PairingState.pending:
          break;
      }
    } catch (_) {
      // Transient network blip — keep polling; the next tick may succeed.
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> signOut() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pairing = null;
    await _tokenStorage.clear();
    _session = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _linkSubscription?.cancel();
    super.dispose();
  }
}
