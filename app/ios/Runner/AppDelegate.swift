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

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    observeWidgetActions()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
