import Flutter
import UIKit

/// Where `fatvpn://` links actually arrive.
///
/// This app declares `UIApplicationSceneManifest`, and on a scene-based app iOS
/// delivers URL opens to the **scene** delegate — `UIApplicationDelegate`'s
/// `application(_:open:options:)` is never called. That single fact explains a
/// run of failures nobody had connected: `app_links` reporting nothing on iOS,
/// and then two attempts of mine to catch the launch URL in `AppDelegate`,
/// both of which the simulator smoke test showed changing nothing at all.
///
/// Two callbacks, because a scene learns about a URL in two different ways:
///
///  * `willConnectTo` carries it when the URL is what **started** the app. This
///    is the widget's press against a closed app, and a key link from the bot
///    tapped in Telegram — the cases that were doing nothing.
///  * `openURLContexts` carries every open while the scene is already live.
///
/// Both hand it to `AppDelegate.rememberLaunchLink`, which holds it until Dart
/// asks (`takeLaunchLink`, polled on launch and on every resume). Holding it is
/// the point: on a cold start the URL exists before the Dart isolate does, so
/// anything that tries to *deliver* it races the engine's boot and loses.
///
/// `super` is still called on both paths, so Flutter's own deep-link handling
/// keeps serving the warm case it already served. A link arriving twice is
/// de-duplicated in Dart; a link arriving never is what this file is for.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Traced even when empty, which is the case that matters: it separates
    // "the scene connected without a URL" from "this callback never ran".
    FatVpnWidgetStore.trace("scene willConnect, urls=\(connectionOptions.urlContexts.count)")
    NSLog("[fatvpn] scene willConnect, urls=%d", connectionOptions.urlContexts.count)
    for context in connectionOptions.urlContexts {
      AppDelegate.rememberLaunchLink(context.url, from: "scene willConnect")
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    FatVpnWidgetStore.trace("scene openURLContexts, urls=\(urlContexts.count)")
    NSLog("[fatvpn] scene openURLContexts, urls=%d", urlContexts.count)
    for context in urlContexts {
      AppDelegate.rememberLaunchLink(context.url, from: "scene openURLContexts")
    }
    super.scene(scene, openURLContexts: urlContexts)
  }
}
