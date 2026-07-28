import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the process's lifetime: a FlutterMethodChannel stops delivering
  /// once nothing references it.
  private var widgetChannel: FlutterMethodChannel?

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    widgetChannel = channel
  }
}
