import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../models/auth_session.dart';
import '../models/pairing.dart';
import 'api_client.dart';
import 'app_logger.dart';
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
  bool _subscriptionExpired = false;
  // Shared in-flight refresh so concurrent callers (cold-start refresh, a 401
  // retry, a resume tick) coalesce into one rotation and all get the same fresh
  // token, instead of racing and double-rotating.
  Future<String?>? _refreshFuture;

  PairingStart? _pairing;
  Timer? _pollTimer;
  bool _pairingBusy = false;
  bool _pollInFlight = false;
  bool _trialBusy = false;
  bool _trialAvailable = false;
  bool _autoConnectRequested = false;
  // When the current session was freshly minted (trial/pairing/exchange). Used
  // to skip the resume-refresh right after a grant: the JWT is good for 30 min,
  // so refreshing seconds later is pointless — and worse, it races the trial
  // auto-connect bringing the tunnel up, which can drop the refresh response and
  // leave a rotated-but-locally-unrotated token that trips reuse detection on
  // the next call (whole session family revoked → forced re-pair).
  DateTime? _sessionMintedAt;
  static const _skipResumeRefreshWindow = Duration(seconds: 90);

  AuthSession? get session => _session;
  bool get initializing => _initializing;

  /// When the current session was last *replaced* (trial grant, key exchange,
  /// pairing). Unchanged by silent refreshes, so a screen can reload subscription
  /// data only when the underlying key actually changed. Null for a restored
  /// session that hasn't been re-minted this run.
  DateTime? get sessionMintedAt => _sessionMintedAt;

  /// Whether we hold a session at all (a refresh token). Drives onboarding vs
  /// the rest of the app — independent of whether the subscription is active.
  bool get isLoggedIn => _session != null;

  /// Whether the subscription is currently usable. False routes the app to the
  /// renew screen instead of the home screen. Combines the locally-known expiry
  /// with a server-reported lapse (402).
  bool get subscriptionActive =>
      _session != null && !_session!.isExpired && !_subscriptionExpired;

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
  /// yet). Drives whether the onboarding shows the "2 days free" button — a
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
    if (stored != null) {
      _session = stored;
      log.i('Restored stored session (expires ${stored.expiresAt.toIso8601String()})');
    } else {
      log.i('No stored session — starting onboarding');
    }
    // Trial button shows only for a device that hasn't used its trial yet.
    _trialAvailable = !await _tokenStorage.hasAttemptedAutoTrial();
    _initializing = false;
    notifyListeners();

    // Refresh in the background — never block the first frame on the network.
    // The gate shows Home/renew from the stored expiry immediately; the refresh
    // rotates the token and corrects the expiry (extension or lapse) when it
    // lands. A slow or unreachable BFF can no longer strand the app on a loader.
    if (stored != null && stored.hasRefreshToken) {
      unawaited(_refreshNow());
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(_handleUri);
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleUri(initialUri);
    }
  }

  /// Callback for [ApiClient]: returns a freshly-refreshed access token on 401,
  /// or null if the session can't be renewed.
  Future<String?> ensureFreshAccessToken() {
    if (_session == null) return Future.value(null);
    return _refreshNow();
  }

  /// Refreshes on app resume so an extended (or lapsed) subscription is picked
  /// up without the user doing anything.
  Future<void> refreshOnResume() async {
    if (_session == null) return;
    // Skip if the session was just minted — see [_sessionMintedAt]. This is the
    // resume that fires after the trial's auto-connect VPN-permission dialog;
    // refreshing here needlessly races the tunnel coming up and can cost the
    // whole session to reuse detection.
    final mintedAt = _sessionMintedAt;
    if (mintedAt != null &&
        DateTime.now().difference(mintedAt) < _skipResumeRefreshWindow) {
      log.i('Skipping resume-refresh — session freshly minted');
      return;
    }
    await _refreshNow();
  }

  /// Coalesces concurrent refreshes onto one in-flight call.
  Future<String?> _refreshNow() {
    return _refreshFuture ??=
        _doRefresh().whenComplete(() => _refreshFuture = null);
  }

  /// Exchanges the stored refresh token for a fresh session. Updates expiry (so
  /// [subscriptionActive] recomputes) and persists. Signs out on a hard 401
  /// (revoked/unknown refresh token); leaves the session intact on a network
  /// blip so a later call can retry.
  Future<String?> _doRefresh() async {
    final refreshToken = _session?.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      await signOut();
      return null;
    }
    try {
      final fresh = await _apiClient.refreshSession(refreshToken);
      _session = fresh;
      _subscriptionExpired = fresh.isExpired;
      notifyListeners();
      unawaited(_tokenStorage.save(fresh).catchError((_) {}));
      return fresh.accessToken;
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        log.w('Refresh rejected (401) — signing out');
        await signOut();
      } else {
        log.w('Refresh failed (${e.statusCode}) — keeping session for retry');
      }
      return null;
    } catch (err) {
      log.w('Refresh network error — keeping session for retry ($err)');
      return null;
    }
  }

  /// Called when a request returns 402 — the subscription has lapsed. Flips the
  /// app to the renew screen. Cleared by a later successful refresh.
  void notifyExpired() {
    if (_subscriptionExpired) return;
    log.w('Subscription reported lapsed (402) — routing to renew screen');
    _subscriptionExpired = true;
    notifyListeners();
  }

  /// Core trial grant shared by the onboarding button. Throws [ApiException]
  /// on non-200 so callers can react to 409/503. On success requests a one-off
  /// auto-connect so the user is online immediately.
  Future<void> _grantTrial() async {
    final deviceKey = await _tokenStorage.readOrCreateDeviceKey();
    final platform =
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final session = await _apiClient.startTrial(deviceKey, platform);
    // A trial supersedes any in-flight pairing attempt — stop its poll timer so
    // it doesn't keep hitting /pair/status in the background after we navigate
    // to Home (pairing-complete does the same cleanup).
    _pollTimer?.cancel();
    _pollTimer = null;
    _pairing = null;
    _session = session;
    _sessionMintedAt = DateTime.now();
    _subscriptionExpired = false;
    _trialAvailable = false;
    _autoConnectRequested = true;
    // The gate flips to Home on notifyListeners; persist afterwards but *await*
    // it so a quick back-out (which finishes the Activity) → reopen restores the
    // session from disk instead of dropping back to the trial onboarding.
    notifyListeners();
    try {
      await _tokenStorage.save(session);
    } catch (_) {/* UI already advanced; a later refresh re-persists */}
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
      _session = session;
      _sessionMintedAt = DateTime.now();
      _subscriptionExpired = false;
      // Entering a key should get the user online right away, like a trial
      // grant — HomeScreen reads this once and auto-connects.
      _autoConnectRequested = true;
      // Transition the UI first (the gate flips to Home on notifyListeners),
      // then await persistence so a quick back-out → reopen restores the session
      // from disk instead of dropping back to onboarding — mirrors the trial path.
      notifyListeners();
      try {
        await _tokenStorage.save(session);
      } catch (_) {/* UI already advanced; a later refresh re-persists */}
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
          log.i('Pairing completed — session established');
          _pollTimer?.cancel();
          _pollTimer = null;
          _pairing = null;
          _session = status.session;
          _sessionMintedAt = DateTime.now();
          _subscriptionExpired = false;
          // Transition the UI first (gate flips to Home), then await persistence
          // so a quick back-out → reopen restores the session from disk instead
          // of dropping back to onboarding — mirrors the trial path.
          notifyListeners();
          try {
            await _tokenStorage.save(status.session!);
          } catch (_) {/* UI already advanced; a later refresh re-persists */}
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
    log.i('Signing out');
    _pollTimer?.cancel();
    _pollTimer = null;
    _pairing = null;
    final refreshToken = _session?.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      unawaited(_apiClient.logout(refreshToken));
    }
    await _tokenStorage.clear();
    _session = null;
    _subscriptionExpired = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _linkSubscription?.cancel();
    super.dispose();
  }
}
