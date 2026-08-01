import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the process's lifetime: a FlutterMethodChannel stops delivering
  /// once nothing references it.
  private var widgetChannel: FlutterMethodChannel?

  /// The widget power button's way of running a connect **on the app's own
  /// engine** instead of spawning a headless one beside it — see
  /// `FatVpnWidgetAppToggle.runOnMainEngine`. Static because the caller is a
  /// static context with no reference to the delegate; nil until the main
  /// engine is up, which the caller treats as "not yet, retry".
  static private(set) var widgetConnectHost: FlutterMethodChannel?

  /// Observer for the widget power button firing inside *this* process — see
  /// [observeWidgetActionRequests].
  private var widgetActionObserver: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerWidgetChannel(engineBridge.pluginRegistry)
  }

  /// Mirrors the session into the home-screen widget.
  ///
  /// The app is one of two writers — the packet-tunnel extension is the other,
  /// and it is the one that keeps the widget honest while the app is not
  /// running (an on-demand start, or a stop from Settings → VPN). See
  /// ios/Shared/FatVpnWidgetSnapshot.swift.
  private func registerWidgetChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "FatVpnWidgetChannel") else { return }
    widgetChannel = AppDelegate.attachWidgetChannel(to: registrar.messenger())
    AppDelegate.widgetConnectHost = FlutterMethodChannel(
      name: "fatvpn/widget_connect_host",
      binaryMessenger: registrar.messenger()
    )
    observeWidgetActionRequests()
  }

  /// The native half of the `fatvpn/widget` channel, on whichever engine asks.
  ///
  /// Static because two engines need it: the UI engine (above), and the
  /// headless engine the widget's intent runs `widgetConnectMain` on
  /// (`FatVpnWidgetAppToggle`) — whose runner publishes snapshots through this
  /// same channel and would otherwise hit a MissingPluginException. The caller
  /// keeps the returned channel alive; one nothing references stops delivering.
  static func attachWidgetChannel(to messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "fatvpn/widget", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "publish":
        guard let arguments = call.arguments as? [String: Any] else {
          result(FlutterError(code: "BAD_ARGS", message: "publish expects a map", details: nil))
          return
        }
        // A Dart `null` arrives here as NSNull, and UserDefaults would store
        // that as a value rather than an absence — the widget would then read
        // "there is a location" and render an empty one.
        FatVpnWidgetSnapshot.write(arguments.filter { !($0.value is NSNull) })
        result(nil)
      // What the widget's power button parked, if anything. Normally the
      // intent toggles the tunnel itself in this very process
      // (FatVpnWidgetAppToggle) and parks nothing; an action appears here only
      // when a screen is unavoidable — no session, lapsed subscription, the
      // first-ever consent dialog — or from the widget-copy fallback. The app
      // collects it on launch and on every resume, see
      // AuthController.pollWidgetAction.
      case "takePendingAction":
        result(FatVpnWidgetSnapshot.takePendingAction())
      // Why the last press had to surface the app at all. Read once, and only
      // so Dart can write it into the log that "Share diagnostics" sends — the
      // intent itself runs with no UI and no console the user can reach.
      case "takeHandOverReason":
        result(FatVpnWidgetSnapshot.takeHandOverReason())
      // The native step-by-step trace of the last press(es), drained into the
      // Dart log so "Share diagnostics" finally answers "did the intent run,
      // and in which process" — the question builds 197 and 198 could not.
      case "takeBreadcrumbs":
        result(FatVpnWidgetSnapshot.takeBreadcrumbs())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  /// Tells Dart the instant the power button's intent runs, instead of leaving
  /// it to be noticed at the next poll.
  ///
  /// `FatVpnTogglePowerIntent` runs **in this process** (its
  /// `AudioPlaybackIntent` conformance routes it here), and when it parks an
  /// action it may do so while the app is already active — after
  /// `AuthController.start()` and after the `resumed` lifecycle callback have
  /// both already looked in the mailbox and found it empty. Push, not poll, is
  /// what makes the press take effect on the press.
  private func observeWidgetActionRequests() {
    if let observer = widgetActionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    widgetActionObserver = NotificationCenter.default.addObserver(
      forName: FatVpnWidgetSnapshot.actionRequestedNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      // An intent's perform() is not promised the main thread, and a Flutter
      // channel must be spoken to from it.
      DispatchQueue.main.async {
        // Nothing is sent with it: the action itself stays in the App Group,
        // and Dart comes and takes it (`takePendingAction`) so that the push
        // and the poll can never both carry out the same tap.
        self?.widgetChannel?.invokeMethod("pendingActionAvailable", arguments: nil)
      }
    }
  }
}
