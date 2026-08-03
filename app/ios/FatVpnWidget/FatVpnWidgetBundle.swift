import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// One home-screen widget in the bundle, deliberately: a second entry in the
/// picker is a second thing to explain, and everything this product has to
/// show fits on one tile. The Control Center toggle is not a picker entry —
/// controls live in their own gallery — so it costs no such explanation.
@main
struct FatVpnWidgetBundle: WidgetBundle {
    var body: some Widget {
        FatVpnWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            FatVpnWidgetControl()
        }
    }
}
