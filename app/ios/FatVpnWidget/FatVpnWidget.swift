import SwiftUI
import WidgetKit

/// Colours mirrored from `lib/theme/app_colors.dart` — the widget sits on the
/// same home screen as the app icon and has to read as the same product.
enum FatVpnWidgetPalette {
    static let background = Color(rgb: 0x0B1622)
    static let card = Color(rgb: 0x152436)
    static let accent = Color(rgb: 0x34D399)
    static let textPrimary = Color.white
    static let textSecondary = Color(rgb: 0x8C9BAC)
    static let disabled = Color(rgb: 0x3A4A5C)
}

extension Color {
    /// Written as one 0xRRGGBB literal so the values can be diffed against
    /// `AppColors` by eye — and so no component is a `0x0B / 255` that a reader
    /// has to prove is not integer division.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Deep links the widget can send. The app never connects on a widget's say-so
/// alone — it re-checks the entitlement and rebuilds the config first — so these
/// are requests, not commands. See `HomeWidgetBridge` on the Dart side.
enum FatVpnWidgetLink {
    static let toggle = URL(string: "fatvpn://widget/toggle")!
    /// Not an action: opens the app and does nothing else. Used for the parts
    /// of the widget that are a status display rather than a button.
    static let open = URL(string: "fatvpn://widget/open")!
}

struct FatVpnWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: FatVpnWidgetSnapshot
}

struct FatVpnWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FatVpnWidgetEntry {
        FatVpnWidgetEntry(date: Date(), snapshot: .unknown)
    }

    func getSnapshot(in context: Context, completion: @escaping (FatVpnWidgetEntry) -> Void) {
        completion(FatVpnWidgetEntry(date: Date(), snapshot: FatVpnWidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FatVpnWidgetEntry>) -> Void) {
        let entry = FatVpnWidgetEntry(date: Date(), snapshot: FatVpnWidgetSnapshot.read())
        // One entry, and a refresh far out. Everything that changes what this
        // widget shows already reloads it explicitly — the app on every state
        // change, the packet-tunnel extension when the OS starts or stops the
        // tunnel without the app (FatVpnWidgetSnapshot.reloadWidgets) — and the
        // session clock ticks by itself inside SwiftUI's timer text. The
        // scheduled refresh is only a backstop for a reload that never arrived,
        // and WidgetKit budgets those reloads: asking for one a minute would
        // spend the budget and get the widget frozen for hours.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct FatVpnWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FatVpnWidgetEntry

    private var snapshot: FatVpnWidgetSnapshot { entry.snapshot }
    private var strings: FatVpnWidgetStrings { .forLanguage(snapshot.language) }

    /// Green only for a tunnel that is actually up: a connecting or
    /// disconnecting one is deliberately not green, because "green" on a VPN
    /// widget is read as "my traffic is protected".
    private var accent: Color {
        guard snapshot.signedIn else { return FatVpnWidgetPalette.disabled }
        return snapshot.isConnected ? FatVpnWidgetPalette.accent : FatVpnWidgetPalette.textSecondary
    }

    private var locationText: String {
        let label = snapshot.locationLabel ?? strings.bestServer
        guard let flag = snapshot.flagEmoji, !flag.isEmpty else { return label }
        return "\(flag) \(label)"
    }

    @ViewBuilder
    var body: some View {
        if family == .systemMedium {
            mediumBody
        } else {
            smallBody
        }
    }

    // MARK: - Home screen

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(strings.status(for: snapshot))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FatVpnWidgetPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(locationText)
                .font(.system(size: 13))
                .foregroundColor(FatVpnWidgetPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack {
                powerControl(diameter: 44)
                Spacer(minLength: 0)
                secondaryLine.font(.system(size: 12))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fatVpnWidgetBackground()
        .widgetURL(smallTileURL)
    }

    /// What a tap *outside* the power button does on a small widget.
    ///
    /// From iOS 17 the button is an interactive `Button`, so the rest of the
    /// tile is free to do what a status display should: open the app. Below 17
    /// there are no interactive widgets and SwiftUI ignores `Link` inside a
    /// small widget, so the whole tile stays the single tap target it has to be
    /// — one that toggles, because a widget with a power button drawn on it
    /// that only opens an app is worse than no button at all.
    private var smallTileURL: URL {
        if #available(iOSApplicationExtension 17.0, *) {
            return FatVpnWidgetLink.open
        }
        return snapshot.signedIn ? FatVpnWidgetLink.toggle : FatVpnWidgetLink.open
    }

    private var mediumBody: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FatVPN")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FatVpnWidgetPalette.textSecondary)
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 9, height: 9)
                    Text(strings.status(for: snapshot))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(FatVpnWidgetPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(locationText)
                    .font(.system(size: 14))
                    .foregroundColor(FatVpnWidgetPalette.textSecondary)
                    .lineLimit(1)
                secondaryLine.font(.system(size: 13))
            }
            Spacer(minLength: 0)
            powerControl(diameter: 62)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .fatVpnWidgetBackground()
        .widgetURL(FatVpnWidgetLink.open)
    }

    /// The session clock while connected, the call to action otherwise.
    @ViewBuilder
    private var secondaryLine: some View {
        if snapshot.isConnected, let connectedAt = snapshot.connectedAt {
            // Ticks on its own: WidgetKit renders this text from the date, so
            // the clock does not cost a timeline reload per second.
            Text(connectedAt, style: .timer)
                .foregroundColor(FatVpnWidgetPalette.accent)
                .lineLimit(1)
        } else {
            Text(snapshot.signedIn ? strings.tapToConnect : strings.openApp)
                .foregroundColor(FatVpnWidgetPalette.textSecondary)
                .lineLimit(1)
        }
    }

    /// The power button as a tap target, by what the OS allows.
    ///
    ///  * **iOS 17+** — a real `Button`, in every family. It runs in the widget
    ///    process, parks the request in the App Group and brings the app forward
    ///    (see `FatVpnTogglePowerIntent`); the tile around it stays free to just
    ///    open the app.
    ///  * **iOS 16 and below** — a `Link` on a medium widget, and nothing at all
    ///    on a small one, where SwiftUI ignores links and the tile's own
    ///    `widgetURL` is the toggle instead ([smallTileURL]).
    ///  * **No session** — not a button at all: the tile opens the app, which is
    ///    the only place the user can do anything about that.
    @ViewBuilder
    private func powerControl(diameter: CGFloat) -> some View {
        if snapshot.signedIn {
            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: FatVpnTogglePowerIntent()) {
                    powerButton(diameter: diameter)
                }
                // Without `.plain` the system draws its own button chrome — a
                // grey capsule behind a disc that is already a button.
                .buttonStyle(.plain)
            } else if family == .systemSmall {
                powerButton(diameter: diameter)
            } else {
                Link(destination: FatVpnWidgetLink.toggle) {
                    powerButton(diameter: diameter)
                }
            }
        } else {
            powerButton(diameter: diameter)
        }
    }

    private func powerButton(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(snapshot.isConnected
                      ? FatVpnWidgetPalette.accent.opacity(0.22)
                      : FatVpnWidgetPalette.card)
            Image(systemName: "power")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(accent)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Lock-screen (and StandBy) widgets. Separate view because accessory families
/// are rendered by the system in a single tint colour — anything styled for the
/// home screen comes out as a flat silhouette there.
@available(iOSApplicationExtension 16.0, *)
struct FatVpnAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FatVpnWidgetEntry

    private var snapshot: FatVpnWidgetSnapshot { entry.snapshot }
    private var strings: FatVpnWidgetStrings { .forLanguage(snapshot.language) }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("FatVPN").font(.headline)
                Text(strings.status(for: snapshot)).font(.caption)
                if snapshot.isConnected, let connectedAt = snapshot.connectedAt {
                    Text(connectedAt, style: .timer).font(.caption2)
                } else if let label = snapshot.locationLabel {
                    Text(label).font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(snapshot.signedIn ? FatVpnWidgetLink.toggle : FatVpnWidgetLink.open)
        case .accessoryInline:
            Text("FatVPN · \(strings.status(for: snapshot))")
                .widgetURL(FatVpnWidgetLink.open)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: snapshot.isConnected ? "lock.shield.fill" : "lock.open")
                    .font(.system(size: 20, weight: .semibold))
            }
            .widgetURL(snapshot.signedIn ? FatVpnWidgetLink.toggle : FatVpnWidgetLink.open)
        }
    }
}

struct FatVpnWidget: Widget {
    let kind = "FatVpnWidget"

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOSApplicationExtension 16.0, *) {
            return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
        return [.systemSmall, .systemMedium]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FatVpnWidgetProvider()) { entry in
            FatVpnWidgetRootView(entry: entry)
        }
        .configurationDisplayName("FatVPN")
        .description(descriptionText)
        .supportedFamilies(supportedFamilies)
    }

    private var descriptionText: String {
        let strings = FatVpnWidgetStrings.forLanguage(FatVpnWidgetSnapshot.read().language)
        // The picker has no room for a second sentence, and the call to action
        // is the honest description of what this widget is for.
        return strings.tapToConnect
    }
}

/// Routes each widget family to the view built for it.
struct FatVpnWidgetRootView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FatVpnWidgetEntry

    var body: some View {
        // Nested rather than `if #available(...), family == ...`: a ViewBuilder
        // body has its own rules about what an `if` may contain, and an
        // availability check on its own is the shape that is certainly allowed.
        if #available(iOSApplicationExtension 16.0, *) {
            if family == .accessoryCircular ||
                family == .accessoryRectangular ||
                family == .accessoryInline {
                FatVpnAccessoryView(entry: entry)
            } else {
                FatVpnWidgetEntryView(entry: entry)
            }
        } else {
            FatVpnWidgetEntryView(entry: entry)
        }
    }
}

extension View {
    /// iOS 17 stopped drawing a widget's own background: a view has to declare
    /// one through `containerBackground`, and without it the widget renders on
    /// the system's default material — light grey under a light wallpaper, with
    /// our white text on top of it.
    @ViewBuilder
    func fatVpnWidgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(FatVpnWidgetPalette.background, for: .widget)
        } else {
            self.background(FatVpnWidgetPalette.background)
        }
    }
}
