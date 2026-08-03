import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The app engine's end of `fatvpn/widget_connect_host`, held so the widget's
  /// App Intent can reach Dart from a process the system launched in the
  /// background — see `FatVpnWidgetToggle.runOnMainEngine`.
  ///
  /// Nil until the implicit engine exists, which is normal rather than
  /// exceptional: the intent is regularly performed before `main()` has run.
  /// The caller retries.
  static private(set) var widgetConnectHost: FlutterMethodChannel?

  /// Kept alive for as long as the app is: a `FlutterMethodChannel` nothing
  /// references stops delivering, and this one is the widget's only way to be
  /// told anything.
  private static var widgetChannel: FlutterMethodChannel?

  private var actionObserver: NSObjectProtocol?

  /// The `fatvpn://` URL this process was opened with, held until Dart comes to
  /// take it.
  ///
  /// Flutter's own delivery is a race on a cold start, and the widget's press
  /// loses it. `defaultRouteName` does not carry the URL on iOS, and the push
  /// through `didPushRouteInformation` happens while the Dart isolate is still
  /// booting, so nothing is listening yet: a press that started the app arrived
  /// nowhere. Measured, not assumed — the simulator smoke test opened
  /// `fatvpn://widget/toggle` against a cold app and the log came back with
  /// nothing but "App started".
  ///
  /// A mailbox removes the race rather than shortening it, exactly as the App
  /// Group one does for a parked press: the native side always receives the
  /// URL, and Dart reads it when it is ready (`takeLaunchLink`, polled on
  /// launch and on every resume).
  private static var pendingLaunchLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    observeWidgetActions()
    // A launch *caused by* a URL carries it here and, on some paths, nowhere
    // else. Recorded before Flutter starts, which is the whole point.
    if let url = launchOptions?[.url] as? URL {
      Self.rememberLaunchLink(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// ⚠️ Kept, but on this app it never fires: `Info.plist` declares
  /// `UIApplicationSceneManifest`, and a scene-based app receives URL opens in
  /// its **scene** delegate instead — see SceneDelegate.swift, which is where
  /// the links are actually caught. Left in place for the non-scene path
  /// (and as the note that stops someone re-adding it as a "fix").
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    Self.rememberLaunchLink(url)
    return super.application(app, open: url, options: options)
  }

  /// Records a `fatvpn://` open for Dart to collect. Called from the scene
  /// delegate, which is the only place iOS actually delivers them here.
  ///
  /// The trace is not decoration. "The link did not reach Dart" has three
  /// possible causes — iOS never delivered it, this never ran, or Dart never
  /// collected it — and four builds were spent unable to tell them apart. This
  /// line, drained into the app's log on the next poll, separates the first two
  /// from the third.
  static func rememberLaunchLink(_ url: URL, from source: String = "app delegate") {
    // Both, deliberately. The App Group trail is what a user's "Share
    // diagnostics" carries off a real phone, and NSLog is what survives a
    // simulator where the App Group container may not exist at all — a silent
    // no-op there would leave CI as blind as the four builds before it.
    FatVpnWidgetStore.trace("link → \(source): \(url.scheme ?? "?")://\(url.host ?? "?")")
    NSLog("[fatvpn] link → %@: %@", source, url.absoluteString)
    guard url.scheme == "fatvpn" else { return }
    pendingLaunchLink = url.absoluteString
    // Nudge an app that is already running, for the same reason the parked
    // action posts one: by the time a warm open arrives, both places that poll
    // have already run.
    widgetChannel?.invokeMethod("actionAvailable", arguments: nil)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerWidgetChannels(engineBridge.pluginRegistry)
  }

  /// Mirrors the session into the home-screen widget, and gives the widget's
  /// App Intent a way back into Dart.
  ///
  /// The app is one of two writers — the packet-tunnel extension is the other,
  /// and it is the one that keeps the widget honest while the app is not
  /// running (an on-demand start, or a stop from Settings → VPN). See
  /// ios/Shared/FatVpnWidgetStore.swift.
  private func registerWidgetChannels(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "FatVpnWidgetChannel") else { return }
    Self.widgetChannel = Self.attachWidgetChannel(to: registrar.messenger())
    Self.widgetConnectHost = FlutterMethodChannel(
      name: "fatvpn/widget_connect_host",
      binaryMessenger: registrar.messenger()
    )
  }

  /// Wires the `fatvpn/widget` channel onto a messenger and returns it.
  ///
  /// Static and returning the channel because the headless connect engine needs
  /// the same native half the UI engine has: the Dart runner publishes widget
  /// snapshots as it works, and without this every publish from that engine is a
  /// `MissingPluginException`.
  @discardableResult
  static func attachWidgetChannel(to messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "fatvpn/widget", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "publish":
        guard let payload = call.arguments as? [String: Any] else {
          result(
            FlutterError(
              code: "INVALID_SNAPSHOT",
              message: "publish expects a map",
              details: nil))
          return
        }
        FatVpnWidgetStore.write(payload)
        result(nil)
      case "takePendingAction":
        result(FatVpnWidgetStore.takeParkedAction()?.rawValue)
      case "takeLaunchLink":
        // Read once and cleared: a URL acted on twice would toggle the tunnel
        // back to where it started, which looks exactly like a press that did
        // nothing.
        result(Self.pendingLaunchLink)
        Self.pendingLaunchLink = nil
      case "takeBreadcrumbs":
        result(FatVpnWidgetStore.takeTrail())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  /// Tells Dart, in-process, that a press has just been parked.
  ///
  /// The poll on launch and on resume cannot be the only path. On iOS 17 the
  /// system performs the intent in this process *after* the app is already
  /// active — i.e. after both of those have run — so without this the press
  /// would sit in the App Group until the user backgrounded and reopened the
  /// app, which is a button that does nothing as far as anyone pressing it is
  /// concerned.
  private func observeWidgetActions() {
    actionObserver = NotificationCenter.default.addObserver(
      forName: FatVpnWidgetStore.actionPosted,
      object: nil,
      queue: .main
    ) { _ in
      Self.widgetChannel?.invokeMethod("actionAvailable", arguments: nil)
    }
  }
}
