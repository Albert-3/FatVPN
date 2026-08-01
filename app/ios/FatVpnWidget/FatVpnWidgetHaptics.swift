import Foundation
#if !FATVPN_WIDGET_EXTENSION
import AudioToolbox
import UIKit
#endif

/// The tick under the power button, on the one path that has nowhere else to
/// produce it: the iOS 18 press, performed in the app's process with nothing on
/// screen.
///
/// The other path does not come here. On iOS 17 the press opens the app, and the
/// app buzzes for itself when it collects the parked action — in the foreground,
/// where feedback generators actually work. Splitting it that way is what keeps
/// exactly one buzz per press: whichever process is going to be in front of the
/// user owns it.
///
/// Compiled into both targets so the press body can call it unconditionally, but
/// it does nothing at all in the widget's process — an extension has no access
/// to the vibromotor, and no entitlement or background mode changes that.
///
/// ⚠️ Do not expect much of the background buzz. `UIFeedbackGenerator` and
/// CoreHaptics are documented foreground-only, so all that is left there is the
/// old undifferentiated system vibration — the same for connect and disconnect,
/// because the IDs that differ (1519/1520/1521) are Taptic peeks and go silent
/// outside the foreground exactly like the generators do. It is one line, it
/// cannot fail loudly, and it is the only tick a background press can have.
enum FatVpnWidgetHaptics {
    enum Direction {
        case connecting
        case disconnecting
    }

    static func play(_ direction: Direction) {
        #if !FATVPN_WIDGET_EXTENSION
        Task { @MainActor in
            guard UIApplication.shared.applicationState == .active else {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                return
            }
            // Rigid going up, soft coming down — told apart by feel, which is
            // the point of using the generator wherever it works at all.
            let generator = UIImpactFeedbackGenerator(
                style: direction == .connecting ? .rigid : .soft
            )
            // Warms the Taptic Engine. Without it the first impact of a launch
            // is the one most likely to be dropped, and from this button the
            // first impact of a launch is the only one there is.
            generator.prepare()
            generator.impactOccurred()
        }
        #endif
    }
}
