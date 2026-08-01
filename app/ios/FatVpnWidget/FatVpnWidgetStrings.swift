import Foundation

/// The widget's own strings, in the language chosen **in the app**.
///
/// Not `NSLocalizedString`: that follows the phone's language, and the app lets
/// the user pick one independently of it. A tile in English beside an app in
/// Russian is the kind of detail that reads as a different product.
struct FatVpnWidgetStrings {
    let connected: String
    let connecting: String
    let disconnecting: String
    let disconnected: String
    let failed: String
    let tapToConnect: String
    let openApp: String
    let bestServer: String

    static let english = FatVpnWidgetStrings(
        connected: "Connected",
        connecting: "Connecting…",
        disconnecting: "Disconnecting…",
        disconnected: "Disconnected",
        failed: "Connection error",
        tapToConnect: "Tap to connect",
        openApp: "Open the app",
        bestServer: "Best server"
    )

    static let russian = FatVpnWidgetStrings(
        connected: "Подключено",
        connecting: "Подключение…",
        disconnecting: "Отключение…",
        disconnected: "Отключено",
        failed: "Ошибка подключения",
        tapToConnect: "Нажмите, чтобы подключиться",
        openApp: "Откройте приложение",
        bestServer: "Лучший сервер"
    )

    static func forLanguage(_ code: String?) -> FatVpnWidgetStrings {
        (code ?? "").lowercased().hasPrefix("ru") ? .russian : .english
    }

    func status(for snapshot: FatVpnWidgetSnapshot) -> String {
        switch snapshot.state {
        case "connected": return connected
        case "connecting", "preparing": return connecting
        case "disconnecting": return disconnecting
        case "error": return failed
        default: return disconnected
        }
    }
}
