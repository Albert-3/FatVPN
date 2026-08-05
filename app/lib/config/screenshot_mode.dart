/// True only in the build the store-screenshot workflow drives
/// (`--dart-define=SCREENSHOTS=true`, see ios-screenshots in codemagic.yaml).
///
/// Compile-time and false in every build that reaches a user, so this cannot
/// change shipped behaviour. It exists because two things the app rightly does
/// on its own are impossible to photograph on a simulator: the notification
/// permission sheet is a system alert no automated run can dismiss, and the
/// auto-connect after sign-in always fails there — a simulator has no
/// NetworkExtension — leaving a red error across the frame.
///
/// Keep the list of what it suppresses short and visible; anything it hides is
/// behaviour the shots then fail to prove.
const bool kScreenshotMode = bool.fromEnvironment('SCREENSHOTS');
