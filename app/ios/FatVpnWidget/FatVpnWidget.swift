import SwiftUI
import WidgetKit

/// Colours mirrored from `lib/theme/app_colors.dart` — the tile sits on the same
/// home screen as the app icon and has to read as the same product.
enum FatVpnWidgetPalette {
    static let background = Color(rgb: 0x0B1622)
    static let accent = Color(rgb: 0x34D399)
    static let textPrimary = Color.white
    static let textSecondary = Color(rgb: 0x8C9BAC)
    static let disabled = Color(rgb: 0x3A4A5C)
}

extension Color {
    /// One 0xRRGGBB literal, so the values can be diffed against `AppColors` by
    /// eye and no component is a `0x0B / 255` a reader has to prove is not
    /// integer division.
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

/// Links the tile can send on the versions of iOS where a tap can only be a
/// link. The app never connects on a widget's say-so alone — it re-checks the
/// entitlement and rebuilds the config first — so these are requests, not
/// commands.
enum FatVpnWidgetLink {
    static let toggle = URL(string: "fatvpn://widget/toggle")!
    /// Not an action: opens the app and does nothing else. For the parts of the
    /// tile that are a status display rather than a button.
    static let open = URL(string: "fatvpn://widget/open")!
}

struct FatVpnWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: FatVpnWidgetSnapshot
}

struct FatVpnWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FatVpnWidgetEntry {
        FatVpnWidgetEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (FatVpnWidgetEntry) -> Void) {
        completion(FatVpnWidgetEntry(date: Date(), snapshot: FatVpnWidgetStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FatVpnWidgetEntry>) -> Void) {
        let now = Date()
        let entry = FatVpnWidgetEntry(date: now, snapshot: FatVpnWidgetStore.read())
        // One entry and a distant refresh. Everything that changes what this
        // tile shows already reloads it explicitly — the app on every state
        // change, the packet-tunnel extension when the OS starts or stops the
        // tunnel without the app, the press overlay the moment a button is
        // tapped — and the session clock ticks by itself inside SwiftUI's timer
        // text. The scheduled refresh is only a backstop for a reload that never
        // arrived, and WidgetKit budgets reloads: asking for one a minute spends
        // the budget and gets the widget frozen for hours.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct FatVpnWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FatVpnWidgetEntry

    private var snapshot: FatVpnWidgetSnapshot { entry.snapshot }
    private var strings: FatVpnWidgetStrings { .forLanguage(snapshot.language) }

    /// The status dot. Green only for a tunnel that is actually up — a
    /// connecting one is deliberately not green, because green beside a status
    /// line is read as "my traffic is protected".
    private var accent: Color {
        guard snapshot.signedIn else { return FatVpnWidgetPalette.disabled }
        return snapshot.isConnected ? FatVpnWidgetPalette.accent : FatVpnWidgetPalette.textSecondary
    }

    /// The power disc, on the other hand, is always the logo's green: it is a
    /// button, not a status light, and the state is already said twice beside
    /// it. Grey only with no session, where it is not a button at all.
    private var powerTint: Color {
        snapshot.signedIn ? FatVpnWidgetPalette.accent : FatVpnWidgetPalette.disabled
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

    /// The 2×2 tile: the button on top, everything else caption under it. The
    /// button is the only thing on this widget anybody presses, so it gets the
    /// size and the top; the text answers "is it on?", which is a glance rather
    /// than a read.
    ///
    /// **The version split is 26, not 18 (owner's call, 2026-08-04 evening):**
    /// iOS 18 and below press the tile as the `fatvpn://widget/toggle` link —
    /// the one mechanism confirmed on real devices — and only iOS 26+ gets the
    /// native background `Button(intent:)`. The new scheme never had a
    /// positive run on iOS 18 (every 18.x data point was the old app-process
    /// scheme failing), so 18 keeps what works; 26 keeps the native button by
    /// the owner's explicit wish, with eyes open: build 245's traced run on
    /// iOS 26.5.2 showed the press never reaching `perform()` — matching
    /// Apple's confirmed 26.5 press-delivery regression FB22848510 — so on
    /// that OS the button may stay dead until Apple fixes it; acceptance is
    /// still TW10 (reinstall the tile!) + TW14 with the trace, and the
    /// Control Center toggle (TW14a) is the discriminator.
    ///
    /// On 26+ with a session the **whole tile** is the button, not just the
    /// disc. On ≤18 the whole tile toggles via `widgetURL`, so the semantics
    /// match across the split. The disc inside the 26+ button is plain
    /// visuals — a `Button` nested in a `Button` is exactly the
    /// tap-swallowing this widget has been bitten by before (thread 731758,
    /// the `.widgetURL` variant of it).
    ///
    /// Every line scales down instead of truncating — the Russian strings are
    /// half again as long as the English ones and a tile this narrow has no room
    /// to lose a word to an ellipsis.
    @ViewBuilder
    private var smallBody: some View {
        if #available(iOS 26.0, iOSApplicationExtension 26.0, *) {
            if snapshot.signedIn {
                Button(intent: FatVpnTunnelToggleIntent()) {
                    smallContent(interactiveDisc: false)
                        // The VStack's own hit area is its drawn pixels; the
                        // rectangle is what makes the padding press too.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fatVpnWidgetBackground()
                .widgetURL(tileURL)
            } else {
                smallContent(interactiveDisc: true)
                    .fatVpnWidgetBackground()
                    .widgetURL(tileURL)
            }
        } else {
            smallContent(interactiveDisc: true)
                .fatVpnWidgetBackground()
                .widgetURL(tileURL)
        }
    }

    /// The small tile's content. [interactiveDisc] false means an ancestor owns
    /// the press (the 26+ whole-tile button) and the disc must be drawn inert.
    @ViewBuilder
    private func smallContent(interactiveDisc: Bool) -> some View {
        VStack(spacing: 7) {
            if interactiveDisc {
                powerControl(diameter: 62)
            } else {
                powerButton(diameter: 62)
            }
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
    }

    /// The medium tile, with the button at the top of its column rather than
    /// centred against the text.
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
        // `.topLeading`, not `.leading`: aligning the row's contents to the top
        // is not enough while the row itself is centred in a tile half again as
        // tall as it is.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fatVpnWidgetBackground()
        .widgetURL(tileURL)
    }

    /// What a tap on the tile does, for everything the power control does not
    /// own. The split is **26**, not 18 — see [smallBody].
    ///
    ///  * **iOS 26+ with a session** — `nil`, and that matters: a `.widgetURL`
    ///    makes the whole widget one tap target and is reported to swallow
    ///    presses that land on a `Button(intent:)` inside it (Apple Developer
    ///    Forums thread 731758). The button owns its area; a tap anywhere else
    ///    falls through to WidgetKit's default, which is "open the app" anyway.
    ///  * **iOS 18 and below, with a session** — the toggle, for the whole
    ///    tile. The press is a link there (see [powerControl]), so there is no
    ///    in-tile button for a URL to swallow, and `systemSmall` could not have
    ///    had a second tap target regardless: WidgetKit gives a small widget
    ///    exactly one, and it is this. The cost is real and deliberate: a tap
    ///    on the status text toggles the VPN too, where the design says it
    ///    should only open the app — the price of the control working at all.
    ///  * **No session** — `open`, because the only thing the user can do about
    ///    that is on a screen. The Dart side tells `widget/open` apart from a
    ///    plain launch.
    private var tileURL: URL? {
        guard snapshot.signedIn else { return FatVpnWidgetLink.open }
        if #available(iOS 26.0, iOSApplicationExtension 26.0, *) {
            return nil
        }
        return FatVpnWidgetLink.toggle
    }

    /// The session clock while connected, the call to action otherwise.
    @ViewBuilder
    private var secondaryLine: some View {
        if snapshot.isConnected, let connectedAt = snapshot.connectedAt {
            // Ticks on its own: WidgetKit renders this from the date, so the
            // clock costs no timeline reload per second.
            Text(connectedAt, style: .timer)
                .foregroundColor(FatVpnWidgetPalette.accent)
                .lineLimit(1)
        } else if snapshot.isBusy {
            // "Tap to connect" under the word "Connecting…" reads as a button
            // that ignored the tap, which is precisely the impression this
            // widget exists to stop giving. An empty line rather than no line,
            // so the tile does not resize mid-connect.
            Text(" ").lineLimit(1)
        } else {
            Text(snapshot.signedIn ? strings.tapToConnect : strings.openApp)
                .foregroundColor(FatVpnWidgetPalette.textSecondary)
                .lineLimit(1)
        }
    }

    /// The power control as a tap target, by what the OS actually delivers.
    /// The split is **26**, not 18 (owner's call, 2026-08-04 evening — see
    /// [smallBody] for the full reasoning and the FB22848510 caveat).
    ///
    ///  * **iOS 26+** — a `Button` running [FatVpnTunnelToggleIntent] **in the
    ///    widget's own process**, toggling the tunnel natively — the sing-box
    ///    architecture, adopted 2026-08-04 (see FatVpnWidgetTunnel.swift).
    ///    Nothing opens; the tile redraws itself.
    ///  * **iOS 18 and below** — a link, not a button. The press opens the app
    ///    and arrives as `fatvpn://widget/toggle`, which the app routes to the
    ///    same action an in-app press takes. Confirmed working on a device
    ///    (iPhone 11 / iOS 17.6.1, builds 207 and 234). 18 is on this side of
    ///    the split because the native scheme has no positive data point
    ///    there either — every 18.x failure on record was the old app-process
    ///    scheme, and the owner chose the demonstrated mechanism over an
    ///    undemonstrated one.
    ///  * **No session** — not a control at all: the tile opens the app, the
    ///    only place the user can do anything about that.
    ///
    /// ⚠️ **The 26+ button is NOT the old app-process scheme back for a third
    /// try.** That scheme — route the press into the *app's* process via
    /// `AudioPlaybackIntent` and toggle from there — is buried for good after
    /// failing identically on three devices (builds 207 and 233, and the
    /// owner's iOS 18+ phone on 2026-08-04), and the 2026-08-04 research
    /// showed that route broken ecosystem-wide (see
    /// FatVpnWidgetIntents.swift). This intent is the opposite shape: plain,
    /// widget-process, native tunnel work — the shape sing-box demonstrably
    /// ships, on the surface (Control Center) where it is field-proven, plus
    /// this button, where it is documented but publicly undemonstrated for a
    /// VPN. Acceptance is a traced run (TW14), and the tile must be removed
    /// and re-added first — WidgetKit archives the view, and an archived tile
    /// keeps the dead build's button.
    ///
    /// The `Link` serves the medium family; on `systemSmall` WidgetKit allows
    /// exactly one tap target and ignores links, so there the tile's own
    /// [tileURL] is the toggle. Both end at the same URL, so it does not matter
    /// which one the system honours.
    @ViewBuilder
    private func powerControl(diameter: CGFloat) -> some View {
        if snapshot.signedIn {
            if #available(iOS 26.0, iOSApplicationExtension 26.0, *) {
                Button(intent: FatVpnTunnelToggleIntent()) {
                    powerButton(diameter: diameter)
                }
                // Without `.plain` the system draws its own chrome — a grey
                // capsule behind a disc that is already a button.
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

    /// Green either way — filled when the tunnel is up, outlined when it is not
    /// — so "is it on?" stays answerable at a glance without the button going
    /// grey on a signed-in user.
    private func powerButton(diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(powerTint.opacity(snapshot.isConnected ? 1 : 0.18))
            Circle().strokeBorder(powerTint.opacity(snapshot.isConnected ? 0 : 0.6), lineWidth: 2)
            Image(systemName: "power")
                // First in the chain, not last: this is an `Image`-only
                // modifier, and `.font`/`.foregroundColor` below already
                // erase the receiver to `some View` (caught by the CI build).
                //
                // Not cosmetic. Under a tinted/clear Home Screen appearance —
                // first-class on iOS 26 — widgets render "accented", and an
                // accented-desaturated Image inside a Button is an
                // Apple-acknowledged, unfixed way for the button to stop firing
                // its intent at all (2026-08-04 research). Full colour opts the
                // glyph out of that entire failure class.
                .fatVpnFullColorInAccentedMode()
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(snapshot.isConnected
                                 ? FatVpnWidgetPalette.background
                                 : powerTint)
        }
        .frame(width: diameter, height: diameter)
        // Dimmed while the tunnel is moving either way, so the press has an
        // answer that needs no reading. On ≤17 the press itself is answered by
        // the app coming to the front (the tile is a link there);
        // `invalidatableContent` greys content while an App Intent runs, which
        // is the 18+ button's press state.
        .opacity(snapshot.isBusy ? 0.5 : 1)
        .fatVpnInvalidatable()
    }
}

/// Lock-screen (and StandBy) widgets. A separate view because accessory families
/// are rendered by the system in a single tint colour — anything styled for the
/// home screen comes out there as a flat silhouette.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
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
        if #available(iOS 16.0, iOSApplicationExtension 16.0, *) {
            return [
                .systemSmall, .systemMedium,
                .accessoryCircular, .accessoryRectangular, .accessoryInline,
            ]
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
        // The picker has no room for a second sentence, and the call to action
        // is the honest description of what this widget is for.
        FatVpnWidgetStrings.forLanguage(FatVpnWidgetStore.read().language).tapToConnect
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
        //
        // Two platforms in every check in this file (2026-08-04): a plain
        // `iOSApplicationExtension N` clause is only evaluated when the file is
        // compiled in extension mode — outside it the `*` matches and the check
        // is TRUE on every OS version, which for the 18-gate would put the
        // intent button on iOS 16–17 tiles and kill the one press mechanism
        // this project has confirmed on a device. The two-platform form reads
        // the same in both modes.
        if #available(iOS 16.0, iOSApplicationExtension 16.0, *) {
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

extension Image {
    /// Keeps the glyph full-colour when the Home Screen renders widgets in
    /// accented (tinted/clear) mode — see the note at the call site in
    /// [powerButton].
    @ViewBuilder
    func fatVpnFullColorInAccentedMode() -> some View {
        if #available(iOS 18.0, iOSApplicationExtension 18.0, *) {
            self.widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }
}

extension View {
    /// Marks content the system may grey out while the button's intent runs —
    /// WidgetKit's only press state, and the reason a tap feels like one before
    /// anything has actually changed.
    @ViewBuilder
    func fatVpnInvalidatable() -> some View {
        if #available(iOS 17.0, iOSApplicationExtension 17.0, *) {
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
        if #available(iOS 16.0, iOSApplicationExtension 16.0, *) {
            self.contentTransition(.opacity)
        } else {
            self
        }
    }

    /// iOS 17 stopped drawing a widget's own background: a view has to declare
    /// one through `containerBackground`, and without it the tile renders on the
    /// system's default material — light grey under a light wallpaper, with our
    /// white text on top of it.
    @ViewBuilder
    func fatVpnWidgetBackground() -> some View {
        if #available(iOS 17.0, iOSApplicationExtension 17.0, *) {
            self.containerBackground(FatVpnWidgetPalette.background, for: .widget)
        } else {
            self.background(FatVpnWidgetPalette.background)
        }
    }
}
