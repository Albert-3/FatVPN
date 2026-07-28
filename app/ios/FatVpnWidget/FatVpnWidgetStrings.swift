import Foundation

/// The widget's own strings.
///
/// Not `NSLocalizedString`: the widget must follow the language the user picked
/// **in the app**, which the snapshot carries, and not the phone's — the two
/// differ often (a Russian-speaking user on an English phone), and a widget
/// disagreeing with the app one home screen away reads as a bug. The system
/// locale is only the fallback for an install that has never published a
/// language.
///
/// Wording is copied from `lib/l10n/strings.dart` on purpose, so the widget and
/// the home screen say the same words for the same state.
struct FatVpnWidgetStrings {
    let connected: String
    let connecting: String
    let disconnecting: String
    let disconnected: String
    let signedOut: String
    let bestServer: String
    let tapToConnect: String
    let openApp: String

    static let english = FatVpnWidgetStrings(
        connected: "Connected",
        connecting: "Connecting…",
        disconnecting: "Disconnecting…",
        disconnected: "Disconnected",
        signedOut: "Not signed in",
        bestServer: "Best server",
        tapToConnect: "Tap to connect",
        openApp: "Open the app"
    )

    static let russian = FatVpnWidgetStrings(
        connected: "Подключено",
        connecting: "Подключение…",
        disconnecting: "Отключение…",
        disconnected: "Отключено",
        signedOut: "Вы не авторизованы",
        bestServer: "Лучший сервер",
        tapToConnect: "Нажмите, чтобы подключиться",
        openApp: "Откройте приложение"
    )

    static func forLanguage(_ language: String?) -> FatVpnWidgetStrings {
        switch language {
        case "ru": return .russian
        case "en": return .english
        default:
            let system = Locale.preferredLanguages.first ?? "en"
            return system.hasPrefix("ru") ? .russian : .english
        }
    }

    func status(for snapshot: FatVpnWidgetSnapshot) -> String {
        guard snapshot.signedIn else { return signedOut }
        switch snapshot.state {
        case "connected": return connected
        case "connecting", "preparing": return connecting
        case "disconnecting": return disconnecting
        default: return disconnected
        }
    }
}
