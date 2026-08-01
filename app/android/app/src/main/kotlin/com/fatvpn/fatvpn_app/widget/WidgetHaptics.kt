package com.fatvpn.fatvpn_app.widget

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.CombinedVibration
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/// The tick under the widget's power button.
///
/// The tap itself is drawn on by the launcher (a ripple on the disc) and
/// answered by an immediate redraw, but neither of those is felt with the phone
/// in a pocket or a glance elsewhere — and the whole complaint this exists to
/// answer is a button that did not feel pressed.
///
/// ⚠️ **Why the usage is `HARDWARE_FEEDBACK` and not `TOUCH`.** A widget tap
/// lands in a broadcast receiver, so our process is never in the foreground when
/// this runs, and from Android 10 the platform drops any vibration from a
/// background process unless its usage is one of a short allow-list —
/// `IGNORED_BACKGROUND`, with no error to the caller. `USAGE_TOUCH` is not on
/// that list, so the semantically neater choice is the one that ships a button
/// that never buzzes. `USAGE_HARDWARE_FEEDBACK` is on it and is the platform's
/// bucket for feedback that accompanies a control the user physically actuated,
/// which is exactly this. It needs no permission beyond `VIBRATE`.
///
/// The attribute types that carry it are newer than the effects, so the older
/// branches below are honest best-effort: on API 29–30 a tap may be dropped in
/// the background, and below 29 there is no restriction to be dropped by. The
/// visual half of the feedback is what is guaranteed on every device.
object WidgetHaptics {
    private const val TAG = "FatVpnWidget"

    /// A click, not a buzz. Only used where the platform has no canned
    /// [VibrationEffect.EFFECT_CLICK] to ask for (below API 29).
    private const val TAP_MS = 18L

    @Suppress("DEPRECATION")
    fun tap(context: Context) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                    as? VibratorManager ?: return
                if (!manager.defaultVibrator.hasVibrator()) return
                manager.vibrate(
                    CombinedVibration.createParallel(
                        VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK),
                    ),
                    VibrationAttributes.Builder()
                        .setUsage(VibrationAttributes.USAGE_HARDWARE_FEEDBACK)
                        .build(),
                )
                return
            }

            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
            if (!vibrator.hasVibrator()) return
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                    vibrator.vibrate(
                        VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK),
                        attributes,
                    )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
                    vibrator.vibrate(
                        VibrationEffect.createOneShot(TAP_MS, VibrationEffect.DEFAULT_AMPLITUDE),
                        attributes,
                    )
                else -> vibrator.vibrate(TAP_MS)
            }
        } catch (e: Exception) {
            // A widget whose button works but does not buzz is a far smaller
            // problem than one that crashes the launcher's broadcast.
            Log.w(TAG, "No haptic for the widget press: $e")
        }
    }
}
