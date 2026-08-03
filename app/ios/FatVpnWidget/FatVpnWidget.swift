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
    /// Every line scales down instead of truncating — the Russian strings are
    /// half again as long as the English ones and a tile this narrow has no room
    /// to lose a word to an ellipsis.
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
    /// own.
    ///
    ///  * **iOS 18+ with a session** — `nil`, and that matters: a `.widgetURL`
    ///    makes the whole widget one tap target and is reported to swallow
    ///    presses that land on a `Button(intent:)` inside it (Apple Developer
    ///    Forums thread 731758). The button owns its area; a tap anywhere else
    ///    falls through to WidgetKit's default, which is "open the app" anyway.
    ///  * **iOS 17 and below, with a session** — the toggle, for the whole tile.
    ///    There is no button on those versions (see [powerControl]), so nothing
    ///    is left for a URL to swallow, and `systemSmall` could not have had a
    ///    second tap target regardless: WidgetKit gives a small widget exactly
    ///    one, and it is this.
    ///  * **No session** — `open`, because the only thing the user can do about
    ///    that is on a screen. The Dart side tells `widget/open` apart from a
    ///    plain launch.
    ///
    /// The cost on 17 is real and deliberate: a tap on the status text toggles
    /// the VPN there too, where the design says it should only open the app.
    /// That is the price of the control working at all — see [powerControl].
    private var tileURL: URL? {
        guard snapshot.signedIn else { return FatVpnWidgetLink.open }
        if #available(iOSApplicationExtension 18.0, *) {
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
    ///
    ///  * **iOS 18+** — a real `Button` running [FatVpnTogglePowerIntent]: the
    ///    system performs it in the app's process in the background, and nothing
    ///    appears on screen. This is the behaviour the widget exists for.
    ///  * **iOS 17 and below** — a link, not a button. The press opens the app
    ///    and arrives as `fatvpn://widget/toggle`, which the app routes to the
    ///    same action an in-app press takes. Confirmed working on a device
    ///    (iPhone 11 / iOS 17.6.1, build 207).
    ///  * **No session** — not a control at all: the tile opens the app, the
    ///    only place the user can do anything about that.
    ///
    /// ⚠️ **Why 17 gets a link, when interactive widgets are a 17 feature.**
    /// Because there it does not run. Every marker Apple documents was shipped
    /// and tried on that phone — `ForegroundContinuableIntent`,
    /// `LiveActivityIntent`, `AudioPlaybackIntent` — and then `openAppWhenRun:
    /// true` with no `widgetURL` on the tile to swallow the press (build 206).
    /// The native press trail, written to the App Group on `perform()`'s first
    /// line before anything that could fail, came back **empty every time**.
    ///
    /// ⚠️ **iOS 18 has never been seen working either.** Build 207 (no
    /// `UIBackgroundModes`): the press opened the app, toggled nothing, no
    /// haptic. Build 233 (`audio` mode shipped since 208): the same, from a
    /// user's phone — so the audio-mode hypothesis did not rescue it. A run on
    /// 2026-08-03 briefly reported the button working on 18, and the tester
    /// retracted that the same day. The intent was then deleted outright, and
    /// **re-added on the owner's later call (2026-08-03)**: 18 is the one
    /// version where Apple documents background execution for a widget intent,
    /// and the failure has never actually been diagnosed — no press trail has
    /// ever been collected from an iOS 18 phone, so "perform() never ran" and
    /// "ran and failed" are still indistinguishable there. Acceptance is a
    /// **traced** run on an iOS 18 device (the support bundle carries the
    /// trail); if the trail is empty there too, demote 18 to the link for good.
    ///
    /// The `Link` serves the medium family; on `systemSmall` WidgetKit allows
    /// exactly one tap target and ignores links, so there the tile's own
    /// [tileURL] is the toggle. Both end at the same URL, so it does not matter
    /// which one the system honours.
    @ViewBuilder
    private func powerControl(diameter: CGFloat) -> some View {
        if snapshot.signedIn {
            if #available(iOSApplicationExtension 18.0, *) {
                Button(intent: FatVpnTogglePowerIntent()) {
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
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(snapshot.isConnected
                                 ? FatVpnWidgetPalette.background
                                 : powerTint)
        }
        .frame(width: diameter, height: diameter)
        // Dimmed while the tunnel is moving either way, so the press has an
        // answer that needs no reading — and marked invalidatable, which is the
        // one press state WidgetKit offers: the system greys whatever carries
        // this from the moment the intent starts until the reload that follows
        // it. A custom pressed `ButtonStyle` cannot stand in for it — a widget's
        // view is archived, and nothing in it has runtime state to track a
        // finger with.
        .opacity(snapshot.isBusy ? 0.5 : 1)
        .fatVpnInvalidatable()
    }
}

/// Lock-screen (and StandBy) widgets. A separate view because accessory families
/// are rendered by the system in a single tint colour — anything styled for the
/// home screen comes out there as a flat silhouette.
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
    /// Marks content the system may grey out while the button's intent runs —
    /// WidgetKit's only press state, and the reason a tap feels like one before
    /// anything has actually changed.
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
    /// one through `containerBackground`, and without it the tile renders on the
    /// system's default material — light grey under a light wallpaper, with our
    /// white text on top of it.
    @ViewBuilder
    func fatVpnWidgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(FatVpnWidgetPalette.background, for: .widget)
        } else {
            self.background(FatVpnWidgetPalette.background)
        }
    }
}
