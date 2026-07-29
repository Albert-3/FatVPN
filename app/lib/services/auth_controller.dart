import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../models/auth_session.dart';
import '../models/pairing.dart';
import 'api_client.dart';
import 'app_logger.dart';
import 'home_widget_bridge.dart';
import 'token_storage.dart';
import 'vpn_controller.dart';

/// Owns the current [AuthSession] and keeps it updated from two sources:
/// a token already persisted on disk, and short tokens arriving via the
/// `fatvpn://token/<shortToken>` deep link sent by the Telegram bot.
class AuthController extends ChangeNotifier {
  AuthController({ApiClient? apiClient, TokenStorage? tokenStorage, AppLinks? appLinks})
      : _apiClient = apiClient ?? ApiClient(),
        _tokenStorage = tokenStorage ?? TokenStorage(),
        _appLinks = appLinks ?? AppLinks() {
    // One client for the whole app (see [api]), so it has to read the session
    // from here rather than be handed a token that goes stale in the caller's
    // hands.
    _apiClient
      ..readAccessToken = currentAccessToken
      ..onUnauthorized = ensureFreshAccessToken
      ..readSessionMintedAt = () => _sessionMintedAt;
  }

  final ApiClient _apiClient;
  final TokenStorage _tokenStorage;

  /// The app's single [ApiClient]. Shared so the `/servers` + `/config` cache
  /// and the last-known subscription are one thing rather than one per screen,
  /// and so a screen opening doesn't start a fresh connection pool.
  ApiClient get api => _apiClient;
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
  bool _trialResumable = false;
  bool _trialResumeBusy = false;
  bool _autoConnectRequested = false;
  // When the current session was freshly minted (trial/pairing/exchange). Used
  // to skip the resume-refresh right after a grant: the JWT is good for 30 min,
  // so refreshing seconds later is pointless — and worse, it races the trial
  // auto-connect bringing the tunnel up, which can drop the refresh response and
  // leave a rotated-but-locally-unrotated token that trips reuse detection on
  // the next call (whole session family revoked → forced re-pair).
  DateTime? _sessionMintedAt;
  static const _skipResumeRefreshWindow = Duration(seconds: 90);

  // The key code the user pasted to connect (the "код ключа" from the bot).
  // Shown in Settings so a user holding several keys can see which is active.
  // Null for pairing/trial sessions, which have no user-entered code.
  String? _keyCode;

  AuthSession? get session => _session;
  bool get initializing => _initializing;

  /// The pasted key code backing the current session, or null when the session
  /// came from pairing/trial (no user-entered code). Restored across restarts.
  String? get keyCode => _keyCode;

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

  /// Whether the "continue trial period" button should appear on the sign-out
  /// screen: this device has taken a trial before and hasn't since moved to a
  /// real subscription (paired via Telegram or a pasted key). Doesn't
  /// guarantee the trial is still within its window — [resumeTrial] finds
  /// that out from the server.
  bool get trialResumable => _trialResumable;

  /// True while [resumeTrial] is in flight (button spinner).
  bool get trialResumeBusy => _trialResumeBusy;

  /// Invoked when the session goes away — the user signing out, or a refresh
  /// the server rejected outright. The tunnel was authorised by that session,
  /// so it has to come down with it: otherwise the app shows onboarding while
  /// the user's whole traffic still leaves through a subscription they no
  /// longer hold, VPN icon and all. Wired by [HomeScreen], which owns the
  /// [VpnController]; null while that screen is off the tree — which is *not*
  /// the same as no tunnel running, so [_dropTunnelWithSession] falls back to
  /// a standalone teardown rather than skipping it.
  Future<void> Function()? onSessionDropped;

  /// Brings the tunnel down with the session that authorised it.
  ///
  /// Goes through [onSessionDropped] while [HomeScreen] is on the tree. When
  /// it is not — a sign-out from the renew screen, a refresh rejected with 401
  /// after a 402 already swapped Home out — the tunnel can still be running
  /// (and on iOS the on-demand snapshot survives regardless), so the fallback
  /// stops it and wipes the persisted state without a controller. Reads
  /// [onSessionDropped] synchronously, before the gate can unmount the screen
  /// that wired it.
  Future<void> _dropTunnelWithSession() async {
    final handler = onSessionDropped;
    try {
      if (handler != null) {
        await handler();
      } else {
        await VpnController.stopAndForgetStandalone();
      }
    } catch (err) {
      log.w('Could not stop the tunnel with the session ($err)');
    }
  }

  /// Pairing code to show/QR-encode, or null while none is active.
  String? get pairCode => _pairing?.pairCode;

  /// Telegram deep link that carries the pairing code into the bot.
  Uri? get telegramPairUri =>
      _pairing == null ? null : telegramPairLink(_pairing!.pairCode);

  /// True while a pairing code exists and we're polling for completion.
  bool get pairingActive => _pairing != null;

  Future<void> start() async {
    AuthSession? stored;
    try {
      stored = await _tokenStorage.read();
      if (stored != null) {
        _session = stored;
        _keyCode = await _tokenStorage.readKeyCode();
        log.i('Restored stored session (expires ${stored.expiresAt.toIso8601String()})');
      } else {
        log.i('No stored session — starting onboarding');
        await _refreshTrialResumable();
        // No local session, but this device already had a trial (e.g. it
        // signed out) — the trial's own expiry lives server-side, not in local
        // storage, so the only way to find out whether it's still running is
        // to ask. This cold-start check is silent; the sign-out screen instead
        // shows an explicit "continue trial" button (see [resumeTrial]).
        if (_trialResumable) {
          await _tryRecoverTrialSession();
        }
      }
      // Trial button shows only for a device that hasn't used its trial yet.
      _trialAvailable = !await _tokenStorage.hasAttemptedAutoTrial();
      // A pairing attempt the user left in flight. Android is free to kill the
      // app while they are in Telegram, and without this the app comes back and
      // starts a *new* code while the bot has already completed the old one —
      // "✅ приложение подключено" in the chat, a spinner that never resolves in
      // the app. AwaitingAuthScreen resumes the poll on the restored code.
      if (_session == null || _session!.isExpired) {
        _pairing = await _tokenStorage.readPairing();
        if (_pairing != null) {
          log.i('Restored a pairing attempt still in its window');
        }
      }
    } catch (error, stack) {
      // Whatever failed, the app still has to leave the splash screen: the
      // gate in main.dart watches [initializing], so an escaping exception
      // here means a splash that never resolves and an app the user can only
      // fix by reinstalling. Onboarding without a session is a place they can
      // act from. Anything already restored above is kept — a later step
      // failing is no reason to throw away a session that read fine.
      log.e('Startup session restore failed — continuing to onboarding',
          error, stack);
    }
    _initializing = false;
    notifyListeners();

    // Refresh in the background — never block the first frame on the network.
    // The gate shows Home/renew from the stored expiry immediately; the refresh
    // rotates the token and corrects the expiry (extension or lapse) when it
    // lands. A slow or unreachable BFF can no longer strand the app on a loader.
    if (stored != null && stored.hasRefreshToken) {
      unawaited(_refreshNow());
    }

    // A widget tap the platform is holding for us (iOS App Intent — see
    // [pollWidgetAction]). Before the deep link, because on iOS this is the
    // path that actually carries a widget tap.
    await pollWidgetAction();

    _linkSubscription = _appLinks.uriLinkStream.listen(_handleUri);
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleUri(initialUri);
    }
  }

  /// Picks up a widget tap that the platform parked instead of deep-linking.
  ///
  /// On iOS the widget's power button is an App Intent: it can ask the system
  /// to open the app, but not to open a URL, so the action is left in the
  /// shared App Group and collected here — on launch, and on every resume
  /// (`main.dart`), since the app is frequently already running when the user
  /// taps its widget.
  Future<void> pollWidgetAction() async {
    final action = await HomeWidgetBridge.instance.takePendingAction();
    if (action == null) return;
    log.i('Widget action collected from the platform: ${action.name}');
    _pendingWidgetAction = action;
    notifyListeners();
  }

  /// Callback for [ApiClient]: returns a freshly-refreshed access token on 401,
  /// or null if the session can't be renewed.
  Future<String?> ensureFreshAccessToken() {
    if (_session == null) return Future.value(null);
    return _refreshNow();
  }

  /// Margin before [AuthSession.accessTokenExpiresAt] at which a token is
  /// treated as spent. Wide enough to cover a slow request and a clock that
  /// disagrees with the server's by a little.
  static const _accessTokenLeeway = Duration(minutes: 2);

  /// The access token to use for the next request, refreshed only when the
  /// current one is about to run out.
  ///
  /// This is what [ApiClient] reads before every call. Refreshing on a timer
  /// instead — or refreshing because a screen has been open a while — rotates
  /// the refresh token for no reason, and each rotation is an opportunity to
  /// lose the whole session family to reuse detection.
  Future<String?> currentAccessToken() async {
    final session = _session;
    if (session == null) return null;
    final expiry = session.accessTokenExpiresAt;
    if (expiry != null &&
        expiry.difference(DateTime.now()) > _accessTokenLeeway) {
      return session.accessToken;
    }
    // Unknown expiry (a session stored by an older build) or genuinely spent:
    // rotate, and fall back to what we hold if the network says no — a 401 then
    // triggers the retry path in ApiClient.
    return await _refreshNow() ?? session.accessToken;
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
      // Disk before memory. The server has already revoked the token we just
      // presented, so a rotation that lives only in RAM is one process kill
      // away from replaying a revoked token — which reuse detection answers by
      // revoking the whole family and forcing a re-pair. Letting the write
      // failure abort the refresh keeps the old token authoritative, and the
      // BFF's grace window covers the immediate retry.
      await _tokenStorage.save(fresh);
      _session = fresh;
      final wasExpired = _subscriptionExpired;
      _subscriptionExpired = fresh.isExpired;
      if (_subscriptionExpired && !wasExpired) {
        // The refresh is how the app learns the subscription lapsed while it
        // wasn't looking (a cold start, a resume). The tunnel dies with the
        // entitlement, same as on a live 402 — see [notifyExpired].
        log.w('Refresh reports the subscription lapsed — dropping the tunnel');
        unawaited(_dropTunnelWithSession());
      }
      notifyListeners();
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
      log.w('Refresh failed — keeping session for retry ($err)');
      return null;
    }
  }

  /// Called when a request returns 402 — the subscription has lapsed. Flips the
  /// app to the renew screen. Cleared by a later successful refresh.
  void notifyExpired() {
    if (_subscriptionExpired) return;
    log.w('Subscription reported lapsed (402) — routing to renew screen');
    _subscriptionExpired = true;
    // Started before notifyListeners so [onSessionDropped] is read while
    // [HomeScreen] is still mounted — the notification is what unmounts it.
    // A lapsed subscription must take the tunnel down, not just the UI: left
    // running it carries traffic on an entitlement the server just refused,
    // and on iOS the on-demand snapshot would keep resurrecting it.
    unawaited(_dropTunnelWithSession());
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
    _stopPolling();
    _pairing = null;
    unawaited(_tokenStorage.clearPairing());
    _session = session;
    // A trial has no user-entered key code — drop any stale one from storage.
    _keyCode = null;
    unawaited(_tokenStorage.clearKeyCode());
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
      await _tokenStorage.saveSessionKind('trial');
    } catch (_) {/* UI already advanced; a later refresh re-persists */}
  }

  /// Refreshes [trialResumable] from local storage: true only if this device
  /// has used a trial before and hasn't since moved on to a real subscription
  /// (paired via Telegram or a pasted key) — otherwise a paying customer who
  /// once tried the free trial could get silently stuck back in their old,
  /// soon-to-expire trial instead of reaching the pairing screen.
  Future<void> _refreshTrialResumable() async {
    final hasAttemptedTrial = await _tokenStorage.hasAttemptedAutoTrial();
    if (!hasAttemptedTrial) {
      _trialResumable = false;
      return;
    }
    final lastKind = await _tokenStorage.readSessionKind();
    _trialResumable = lastKind != 'key' && lastKind != 'pairing';
  }

  /// Calls `POST /trial` for a device that's used one before and applies the
  /// resulting session. The BFF treats a repeat request from a known device
  /// as a resume: it reissues a session for the still-running trial, or 409s
  /// if it's genuinely used up — callers react to the thrown [ApiException]
  /// (or don't, for the silent cold-start attempt).
  Future<void> _resumeTrialSession() async {
    final deviceKey = await _tokenStorage.readOrCreateDeviceKey();
    final platform =
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final session = await _apiClient.startTrial(deviceKey, platform);
    _session = session;
    _sessionMintedAt = DateTime.now();
    try {
      await _tokenStorage.save(session);
      await _tokenStorage.saveSessionKind('trial');
    } catch (_) {/* session is live in memory; a later refresh re-persists */}
  }

  /// Silently retries the trial for a device that already used one and has no
  /// local session (cold start only — right after sign-out the recovery/sign-
  /// out screen instead shows an explicit "continue trial" button). Failures
  /// (409 or network) just fall through to the normal onboarding/pairing UI.
  Future<void> _tryRecoverTrialSession() async {
    try {
      await _resumeTrialSession();
      log.i('Recovered still-active trial session after sign-out');
    } on ApiException catch (e) {
      if (e.statusCode == 409) _trialResumable = false;
      log.i('No trial to recover (${e.statusCode})');
    } catch (err) {
      log.i('Trial recovery skipped — network error ($err)');
    }
  }

  /// Explicit "continue trial period" action from the sign-out/recovery
  /// screen. 409 means the trial is genuinely used up — hides the button
  /// going forward.
  Future<void> resumeTrial({
    required String expiredMessage,
    required String genericMessage,
  }) async {
    if (_trialResumeBusy) return;
    _trialResumeBusy = true;
    _error = null;
    notifyListeners();

    try {
      await _resumeTrialSession();
      notifyListeners();
    } on ApiException catch (e) {
      if (e.statusCode == 409) _trialResumable = false;
      _error = e.statusCode == 409 ? expiredMessage : genericMessage;
      notifyListeners();
    } catch (_) {
      _error = genericMessage;
      notifyListeners();
    } finally {
      _trialResumeBusy = false;
      notifyListeners();
    }
  }

  /// A key that arrived over `fatvpn://token/<code>` and is waiting for the
  /// user to say yes. Null when there is nothing pending.
  ///
  /// Not exchanged on arrival: any app on the device can fire that intent, and
  /// a key it chose would silently move the victim's whole traffic onto a
  /// subscription the attacker controls. The exchange itself is authenticated
  /// by the BFF, so the only defence against being handed *someone else's* key
  /// is asking the person holding the phone.
  String? get pendingDeepLinkToken => _pendingDeepLinkToken;
  String? _pendingDeepLinkToken;

  /// The last widget tap waiting to be carried out, or null. Consumed exactly
  /// once by the home screen — see [consumeWidgetAction].
  HomeWidgetAction? _pendingWidgetAction;

  /// Takes the pending widget action, leaving nothing behind. Returns null when
  /// there is none.
  ///
  /// The action is parked here rather than dispatched straight to the UI
  /// because the link usually arrives *before* there is a UI to dispatch it to:
  /// a tap on the widget cold-starts the app, and `getInitialLink` resolves
  /// while the home screen is still several frames away.
  HomeWidgetAction? consumeWidgetAction() {
    final action = _pendingWidgetAction;
    _pendingWidgetAction = null;
    return action;
  }

  Future<void> _handleUri(Uri uri) async {
    if (uri.scheme != deepLinkScheme) {
      return;
    }
    // A widget tap is not a key. Without this branch the code below would take
    // `fatvpn://widget/connect` for a short token and ask the user to accept a
    // "key" named `connect` — every path segment of every fatvpn:// link used
    // to end up in [pendingDeepLinkToken].
    if (uri.host == homeWidgetLinkHost) {
      final action = homeWidgetActionFromUri(uri);
      if (action != null) {
        log.i('Widget action received: ${action.name}');
        _pendingWidgetAction = action;
        notifyListeners();
      }
      return;
    }
    final shortToken = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uri.host;
    if (shortToken.isEmpty) {
      return;
    }
    _pendingDeepLinkToken = shortToken;
    notifyListeners();
  }

  /// Accepts the key from [pendingDeepLinkToken].
  Future<void> confirmPendingDeepLinkToken({
    required String conflictMessage,
    required String deviceLimitMessage,
    required String notFoundMessage,
    required String genericMessage,
  }) async {
    final token = _pendingDeepLinkToken;
    if (token == null) return;
    _pendingDeepLinkToken = null;
    await exchangeShortToken(
      token,
      conflictMessage: conflictMessage,
      deviceLimitMessage: deviceLimitMessage,
      notFoundMessage: notFoundMessage,
      genericMessage: genericMessage,
    );
  }

  void dismissPendingDeepLinkToken() {
    if (_pendingDeepLinkToken == null) return;
    log.i('Deep-linked key declined by the user');
    _pendingDeepLinkToken = null;
    notifyListeners();
  }

  Future<void> exchangeShortToken(
    String shortToken, {
    required String conflictMessage,
    required String deviceLimitMessage,
    required String notFoundMessage,
    required String genericMessage,
  }) async {
    try {
      _error = null;
      final deviceKey = await _tokenStorage.readOrCreateDeviceKey();
      final session = await _apiClient.exchangeToken(shortToken, deviceKey);
      // A pasted key supersedes any pairing attempt in flight, same as a trial
      // does — otherwise its timer keeps polling from behind the home screen.
      _stopPolling();
      _pairing = null;
      unawaited(_tokenStorage.clearPairing());
      _session = session;
      _keyCode = shortToken;
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
        await _tokenStorage.saveKeyCode(shortToken);
        await _tokenStorage.saveSessionKind('key');
      } catch (_) {/* UI already advanced; a later refresh re-persists */}
    } on ApiException catch (e) {
      // 404 is a wrong or spent key, not an unreachable server — telling the
      // user the network is down sends them hunting the wrong problem.
      _error = switch (e.statusCode) {
        // A key now runs on several phones, so "linked to another phone" is only
        // still true for a server that predates the limit and sends a bare 409.
        409 => e.code == 'device_limit' ? deviceLimitMessage : conflictMessage,
        404 => notFoundMessage,
        _ => genericMessage,
      };
      notifyListeners();
    } catch (_) {
      _error = genericMessage;
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

  /// Back-off schedule for `/pair/status`. The user is off in Telegram paying
  /// for a subscription, so the first seconds are worth polling tightly and the
  /// minutes after that are not — a flat 2 s meant 30 requests a minute on
  /// mobile radio for as long as the screen stayed open.
  static const _pollIntervals = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
  ];

  /// Consecutive failed polls before the attempt is abandoned. Without a limit
  /// a malformed "completed" response (a version skew between BFF and app)
  /// leaves the timer running forever behind a spinner that never resolves.
  static const _maxPollFailures = 5;

  int _pollTicks = 0;
  int _pollFailures = 0;
  String _pairingExpiredMessage = '';
  String _pairingGenericMessage = '';

  /// Requests a fresh pairing code and starts polling for completion. Safe to
  /// call again to retry after a code expires. Error strings are passed in by
  /// the caller so they can be localized.
  Future<void> startPairing({
    required String expiredMessage,
    required String genericMessage,
  }) async {
    if (_pairingBusy) return;
    _pairingBusy = true;
    _stopPolling();
    _pairing = null;
    _error = null;
    _pairingExpiredMessage = expiredMessage;
    _pairingGenericMessage = genericMessage;
    notifyListeners();

    try {
      _pairing = await _apiClient.startPairing();
      // Persist before the first poll, so a kill between the two doesn't strand
      // a code the bot can still complete. A storage failure must not fail the
      // attempt itself — it only costs the resume.
      try {
        await _tokenStorage.savePairing(_pairing!);
      } catch (err) {
        log.w('Could not persist the pairing attempt ($err)');
      }
      notifyListeners();
      _schedulePoll();
    } catch (_) {
      _error = genericMessage;
      notifyListeners();
    } finally {
      _pairingBusy = false;
    }
  }

  /// Failure texts for an attempt that is already running. [startPairing] sets
  /// them itself; an attempt restored from disk on a cold start never went
  /// through it, and without this its expiry would surface as a blank error
  /// box.
  void setPairingMessages({
    required String expiredMessage,
    required String genericMessage,
  }) {
    _pairingExpiredMessage = expiredMessage;
    _pairingGenericMessage = genericMessage;
  }

  /// Pauses polling while the app is in the background (the user is in Telegram
  /// completing the pairing) and resumes with an immediate check on return, so
  /// a completion that happened meanwhile shows up at once.
  void setPairingPaused(bool paused) {
    if (_pairing == null) return;
    if (paused) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    if (_pollTimer == null) {
      unawaited(_pollOnce());
      _schedulePoll();
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollTicks = 0;
    _pollFailures = 0;
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    final interval = _pollIntervals[
        _pollTicks < _pollIntervals.length ? _pollTicks : _pollIntervals.length - 1];
    _pollTimer = Timer(interval, () {
      _pollTicks++;
      unawaited(_pollOnce());
      if (_pairing != null) _schedulePoll();
    });
  }

  /// Ends the attempt and tells the user why. [expired] distinguishes the code
  /// running out from repeated failures.
  void _failPairing({required bool expired}) {
    _stopPolling();
    _pairing = null;
    unawaited(_tokenStorage.clearPairing());
    _error = expired ? _pairingExpiredMessage : _pairingGenericMessage;
    notifyListeners();
  }

  Future<void> _pollOnce() async {
    // Guard against overlapping ticks so a completion is handled exactly once.
    if (_pollInFlight) return;
    final pairing = _pairing;
    if (pairing == null) return;
    // The server stops honouring the code at this point, so polling past it is
    // guaranteed-useless traffic that the user reads as a hung screen.
    if (DateTime.now().isAfter(pairing.expiresAt)) {
      log.i('Pairing code expired locally — stopping the poll');
      _failPairing(expired: true);
      return;
    }
    _pollInFlight = true;

    try {
      final status = await _apiClient.pollPairing(pairing.pollToken);
      _pollFailures = 0;
      switch (status.state) {
        case PairingState.completed:
          log.i('Pairing completed — session established');
          _stopPolling();
          _pairing = null;
          unawaited(_tokenStorage.clearPairing());
          _session = status.session;
          // Pairing has no user-entered key code — drop any stale one.
          _keyCode = null;
          unawaited(_tokenStorage.clearKeyCode());
          _sessionMintedAt = DateTime.now();
          _subscriptionExpired = false;
          // Transition the UI first (gate flips to Home), then await persistence
          // so a quick back-out → reopen restores the session from disk instead
          // of dropping back to onboarding — mirrors the trial path.
          notifyListeners();
          try {
            await _tokenStorage.save(status.session!);
            await _tokenStorage.saveSessionKind('pairing');
          } catch (_) {/* UI already advanced; a later refresh re-persists */}
        case PairingState.expired:
          _failPairing(expired: true);
        case PairingState.pending:
          break;
      }
    } catch (err) {
      // A blip is normal and the next tick may succeed; a run of them is not,
      // and used to leave the user watching a spinner forever.
      _pollFailures++;
      log.w('Pairing poll failed ($_pollFailures/$_maxPollFailures): $err');
      if (_pollFailures >= _maxPollFailures) {
        _failPairing(expired: false);
      }
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> signOut() async {
    log.i('Signing out');
    // Before anything else, so the UI never reaches onboarding over a tunnel
    // that is still up. Falls back to a standalone stop when no screen is
    // wired — a sign-out from the renew screen still owes the tunnel a
    // teardown.
    await _dropTunnelWithSession();
    _stopPolling();
    _pairing = null;
    final refreshToken = _session?.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      unawaited(_apiClient.logout(refreshToken));
    }
    await _tokenStorage.clear();
    _session = null;
    _keyCode = null;
    _subscriptionExpired = false;
    // Signing out only drops the local session — a still-running trial is
    // bound to the device server-side and isn't actually over. Refresh
    // [trialResumable] so the sign-out screen can offer an explicit
    // "continue trial" button instead of only Telegram/key entry.
    await _refreshTrialResumable();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    _linkSubscription?.cancel();
    _apiClient.close();
    super.dispose();
  }
}
