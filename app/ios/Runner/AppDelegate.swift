import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the process's lifetime: a FlutterMethodChannel stops delivering
  /// once nothing references it.
  private var widgetChannel: FlutterMethodChannel?

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
    let channel = FlutterMethodChannel(
      name: "fatvpn/widget",
      binaryMessenger: registrar.messenger()
    )
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
      // What the widget's power button asked for, if anything. The button is an
      // App Intent (iOS 17+): it can bring this app to the front but cannot
      // hand it a URL, so it leaves the action in the shared App Group and the
      // app comes and takes it — on launch and on every resume, see
      // AuthController.pollWidgetAction.
      case "takePendingAction":
        result(FatVpnWidgetSnapshot.takePendingAction())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    widgetChannel = channel
    observeWidgetActionRequests()
  }

  /// Tells Dart the instant the power button's intent runs, instead of leaving
  /// it to be noticed at the next poll.
  ///
  /// `FatVpnTogglePowerIntent` sets `openAppWhenRun`, which means the system
  /// performs it **in this process**, and it does that once the app is already
  /// active — after `AuthController.start()` and after the `resumed` lifecycle
  /// callback have both already looked in the mailbox and found it empty. Push,
  /// not poll, is what makes the press take effect on the press.
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
