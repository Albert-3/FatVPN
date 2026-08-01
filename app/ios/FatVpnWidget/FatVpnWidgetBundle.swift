import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// One widget in the bundle, deliberately: a second entry in the picker is a
/// second thing to explain, and everything this product has to show fits on one
/// tile.
@main
struct FatVpnWidgetBundle: WidgetBundle {
    var body: some Widget {
        FatVpnWidget()
    }
}
