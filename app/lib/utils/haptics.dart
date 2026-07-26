import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Haptic feedback for the app's primary actions.
///
/// The two platforms need different calls to feel the same. On iOS
/// [HapticFeedback.mediumImpact] is a crisp `UIImpactFeedbackGenerator` tap,
/// while `vibrate()` there is the long system buzz — far too heavy for a
/// button. On Android the impact constants map to `KEYBOARD_TAP`/`CONTEXT_CLICK`,
/// which are barely perceptible on most devices, so the `LONG_PRESS` constant
/// behind [HapticFeedback.vibrate] gives the solid "thunk" a power button wants.
///
/// Both paths go through the OS haptic settings, so a user who turned touch
/// feedback off feels nothing — and neither needs the `VIBRATE` permission.
class Haptics {
  const Haptics._();

  /// Fired when the user toggles the VPN on or off.
  static Future<void> powerToggle() {
    return defaultTargetPlatform == TargetPlatform.android
        ? HapticFeedback.vibrate()
        : HapticFeedback.mediumImpact();
  }
}
