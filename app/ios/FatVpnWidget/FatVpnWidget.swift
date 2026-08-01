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

    /// The status dot. Green only for a tunnel that is actually up: a connecting
    /// or disconnecting one is deliberately not green, because "green" next to
    /// the word "Connected" is read as "my traffic is protected".
    private var accent: Color {
        guard snapshot.signedIn else { return FatVpnWidgetPalette.disabled }
        return snapshot.isConnected ? FatVpnWidgetPalette.accent : FatVpnWidgetPalette.textSecondary
    }

    /// The power button, on the other hand, is always the logo's green — it is a
    /// button, not a status light, and the state is already said twice beside it
    /// (the dot and the status line). Grey only when there is no session, where
    /// it is not a button at all.
    private var powerTint: Color {
        snapshot.signedIn ? FatVpnWidgetPalette.accent : FatVpnWidgetPalette.disabled
    }

    /// A tunnel on its way up or down. Drawn differently from both settled
    /// states: the disc dims, so "I pressed it and something is happening" is
    /// answerable without reading a word.
    private var isBusy: Bool {
        snapshot.state == "connecting" ||
            snapshot.state == "preparing" ||
            snapshot.state == "disconnecting"
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

    /// The 2×2 tile: one big button in the middle, everything else caption under
    /// it. The button is the only thing on this widget anybody presses, so it
    /// gets the centre and the size — the text is there to answer "is it on?",
    /// which is a glance, not a read.
    ///
    /// Every line scales down rather than truncating: the Russian strings are
    /// half again as long as the English ones ("Нажмите, чтобы подключиться"),
    /// and a tile this narrow has no room to lose a word to an ellipsis.
    private var smallBody: some View {
        VStack(spacing: 7) {
            powerControl(diameter: 62)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(strings.status(for: snapshot))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FatVpnWidgetPalette.textPrimary)
                        .fatVpnCrossFade()
                }
                Text(locationText)
                    .font(.system(size: 12))
                    .foregroundColor(FatVpnWidgetPalette.textSecondary)
                secondaryLine.font(.system(size: 11))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .fatVpnInvalidatable()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fatVpnWidgetBackground()
        .widgetURL(tileURL)
    }

    /// What a tap *outside* the power button does — and, in practice, the tap
    /// path that actually works on iOS 17.
    ///
    /// The tile's URL used to be a plain "open the app" on iOS 17, on the
    /// theory that the interactive `Button` owns the toggling. A real device
    /// (iPhone 11, iOS 17.6.1, builds 196–199) then showed the system never
    /// performing that button's intent at all — under three different
    /// conformance markers — with every press falling through to this URL. So
    /// the URL *is* the toggle whenever a session exists: the worst case is
    /// the app opening and immediately connecting, which is the promised
    /// fallback, and if the intent ever does fire on some device, the button
    /// consumes the tap first and this URL never sees it.
    private var tileURL: URL {
        snapshot.signedIn ? FatVpnWidgetLink.toggle : FatVpnWidgetLink.open
    }

    /// `.top`, so the button sits at the top of the tile here too rather than
    /// centred against the text column.
    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 14) {
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
                        .fatVpnCrossFade()
                }
                Text(locationText)
                    .font(.system(size: 14))
                    .foregroundColor(FatVpnWidgetPalette.textSecondary)
                    .lineLimit(1)
                secondaryLine.font(.system(size: 13))
            }
            .fatVpnInvalidatable()
            Spacer(minLength: 0)
            powerControl(diameter: 62)
        }
        .padding(16)
        // `.topLeading`, not `.leading`: aligning the row's own contents to the
        // top is not enough while the row itself is centred in a tile half again
        // as tall as it is.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fatVpnWidgetBackground()
        .widgetURL(tileURL)
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
        } else if isBusy {
            // "Tap to connect" under the word "Connecting…" reads as a button
            // that ignored the tap — which is precisely the impression this
            // widget has to stop giving. An empty line rather than no line, so
            // the tile does not resize mid-connect.
            Text(" ").lineLimit(1)
        } else {
            Text(snapshot.signedIn ? strings.tapToConnect : strings.openApp)
                .foregroundColor(FatVpnWidgetPalette.textSecondary)
                .lineLimit(1)
        }
    }

    /// The power button as a tap target, by what the OS allows.
    ///
    ///  * **iOS 17+** — a real `Button`, in every family. Its intent runs in
    ///    the app's process, launched in the background, and toggles the tunnel
    ///    right there (see `FatVpnTogglePowerIntent`); the tile around it stays
    ///    free to just open the app.
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

    /// Green either way — filled when the tunnel is up, outlined when it is not,
    /// so "is it on?" is still answerable at a glance without the button ever
    /// going grey on a signed-in user.
    private func powerButton(diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(powerTint.opacity(snapshot.isConnected ? 1 : 0.18))
            Circle().strokeBorder(powerTint.opacity(snapshot.isConnected ? 0 : 0.6),
                                  lineWidth: 2)
            Image(systemName: "power")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(snapshot.isConnected
                                 ? FatVpnWidgetPalette.background
                                 : powerTint)
        }
        .frame(width: diameter, height: diameter)
        // Dimmed while the tunnel is moving in either direction, so the press
        // has an answer that needs no reading — and marked invalidatable, which
        // is the one press state WidgetKit offers: the system greys whatever
        // carries this from the moment the button's intent starts until the
        // reload that follows it. A custom pressed `ButtonStyle` cannot stand in
        // for it — a widget's view is archived, and nothing in it has runtime
        // state to track a finger with.
        .opacity(isBusy ? 0.5 : 1)
        .fatVpnInvalidatable()
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
    /// Marks content the system may grey out while the power button's intent is
    /// running — WidgetKit's only press state, and the reason a tap feels like
    /// one before anything has actually changed.
    ///
    /// The widget target deploys to iOS 14, four releases below interactive
    /// widgets, so this is a no-op everywhere the button is not a `Button`
    /// either.
    @ViewBuilder
    func fatVpnInvalidatable() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.invalidatableContent()
        } else {
            self
        }
    }

    /// Cross-fades a label when its text changes between timeline entries, so
    /// "Connected" replacing "Connecting…" is a transition rather than a jump
    /// cut. Nothing animates continuously in a widget — WidgetKit renders
    /// entries, not frames — but a change *between* two of them does.
    @ViewBuilder
    func fatVpnCrossFade() -> some View {
        if #available(iOSApplicationExtension 16.0, *) {
            self.contentTransition(.opacity)
        } else {
            self
        }
    }

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
