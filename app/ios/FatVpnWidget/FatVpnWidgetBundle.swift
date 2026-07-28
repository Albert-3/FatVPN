import SwiftUI
import WidgetKit

/// Entry point of the WidgetKit extension.
///
/// The target's deployment target is iOS 14 (WidgetKit's minimum), above the
/// app's own 13.0 — an extension may require a newer OS than the app that
/// embeds it, and on iOS 13 the widget simply is not offered.
@main
struct FatVpnWidgetBundle: WidgetBundle {
    var body: some Widget {
        FatVpnWidget()
    }
}
