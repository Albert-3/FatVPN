package com.fatvpn.fatvpn_app.widget

import android.app.ActivityManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import org.json.JSONObject
import java.util.Locale

/// Everything the widget draws, assembled from the two places that know it.
data class FatVpnWidgetModel(
    /// Tunnel state as one of the plugin's wire values (`connected`,
    /// `connecting`, `preparing`, `disconnecting`, `disconnected`, `error`).
    val state: String,
    /// The language the user picked *in the app* — not the device's. The two
    /// differ often enough (a Russian-speaking user on an English phone) that
    /// following the system locale would contradict the app on the same screen.
    val language: String?,
    val signedIn: Boolean,
    val locationLabel: String?,
    val flagEmoji: String?,
    /// Wall-clock start of the running session, or null. Feeds the widget's
    /// self-ticking Chronometer.
    val connectedAtMillis: Long?,
    val expiresAtMillis: Long?,
    /// True while a stop we sent has not been confirmed by the tunnel yet.
    val stopping: Boolean,
    /// True while a connect started from the widget is still on its way — see
    /// [FatVpnWidgetState.WIDGET_KEY_CONNECT_REQUESTED_AT]. The tunnel does not
    /// exist yet at that point, so nothing else on the device knows about it.
    val connecting: Boolean,
) {
    val isUp: Boolean
        get() = state == STATE_CONNECTED
    val isBusy: Boolean
        get() = stopping || connecting || state == STATE_CONNECTING ||
            state == STATE_PREPARING || state == STATE_DISCONNECTING

    companion object {
        const val STATE_DISCONNECTED = "disconnected"
        const val STATE_PREPARING = "preparing"
        const val STATE_CONNECTING = "connecting"
        const val STATE_CONNECTED = "connected"
        const val STATE_DISCONNECTING = "disconnecting"
    }
}

/// Reads the widget's view model without waking the app.
///
/// Two stores feed it, and the split is deliberate:
///
///  * `signbox_mm_runtime` is the VPN service's own record of the tunnel
///    (see `RuntimeStateStore` in the vendored singbox_mm plugin). It is written
///    by the service, so it stays correct when the tunnel is stopped from the
///    notification, or brought back by the OS, with the app long dead — which is
///    precisely when a widget is looked at.
///  * `fatvpn_widget` is what the app publishes (see HomeWidgetBridge): the
///    chosen location, the language, whether there is a subscription at all.
///    None of it is knowable from the tunnel.
object FatVpnWidgetState {
    /// Written by the plugin's `RuntimeStateStore`. Read-only here: this file
    /// must never write into another module's store.
    private const val RUNTIME_PREFS = "signbox_mm_runtime"
    private const val RUNTIME_KEY_STATE = "state"
    private const val RUNTIME_KEY_CONNECTED_AT = "connectedAt"

    /// Written by [FatVpnWidgetChannel] from the Dart side.
    const val WIDGET_PREFS = "fatvpn_widget"
    const val WIDGET_KEY_SNAPSHOT = "snapshot"

    /// Set the moment a widget tap asks the tunnel to stop, cleared when the
    /// tunnel confirms. See [STOP_OPTIMISM_WINDOW_MS].
    const val WIDGET_KEY_STOP_REQUESTED_AT = "stopRequestedAt"

    /// Set the moment a widget tap starts a connect, cleared when
    /// [WidgetConnectService] finishes. Without it the widget would sit on
    /// "Disconnected" for the several seconds it takes to fetch a config and
    /// pick a node — long enough for the user to conclude the button is dead
    /// and tap it again.
    const val WIDGET_KEY_CONNECT_REQUESTED_AT = "connectRequestedAt"

    /// How long the widget is allowed to claim "disconnecting" on nothing but
    /// its own say-so. Long enough for an orderly teardown to broadcast its new
    /// state, short enough that a stop which never happened cannot leave the
    /// widget lying about a tunnel that is still up.
    private const val STOP_OPTIMISM_WINDOW_MS = 8_000L

    /// The same idea for a connect, and much longer: the work behind it is two
    /// network round trips and a ping of every candidate node. Kept just above
    /// [WidgetConnectService]'s own timeout, so the service is always the one
    /// that ends the attempt — this is only the backstop for a service that was
    /// killed before it could clear the marker.
    private const val CONNECT_OPTIMISM_WINDOW_MS = 100_000L

    private const val SERVICE_CLASS = "com.signbox.singbox_mm.SignboxLibboxVpnService"

    fun read(context: Context): FatVpnWidgetModel {
        val published = readPublished(context)
        val runtime = context.getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
        val runtimeState = runtime.getString(RUNTIME_KEY_STATE, null)
        val runtimeConnectedAt =
            runtime.getLong(RUNTIME_KEY_CONNECTED_AT, 0L).takeIf { it > 0L }

        // A snapshot claiming the tunnel is up is a record of the last state the
        // service managed to write, not proof it survived: a force-stop or a
        // low-memory kill leaves "connected" on disk forever. The plugin
        // cross-checks that against a process-scoped flag it owns
        // (VpnServiceLiveness); from here the equivalent check is asking the
        // system whether our own VPN service is running — since Android 8,
        // getRunningServices returns exactly that and nothing else.
        val claimsUp = runtimeState == FatVpnWidgetModel.STATE_CONNECTED ||
            runtimeState == FatVpnWidgetModel.STATE_CONNECTING ||
            runtimeState == FatVpnWidgetModel.STATE_PREPARING
        val reconciled = when {
            runtimeState == null -> published.optString("state", FatVpnWidgetModel.STATE_DISCONNECTED)
            claimsUp && !isTunnelServiceRunning(context) -> FatVpnWidgetModel.STATE_DISCONNECTED
            else -> runtimeState
        }

        val widgetPrefs = context.getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
        val stopRequestedAt = widgetPrefs.getLong(WIDGET_KEY_STOP_REQUESTED_AT, 0L)
        val stopping = stopRequestedAt > 0L &&
            System.currentTimeMillis() - stopRequestedAt < STOP_OPTIMISM_WINDOW_MS &&
            reconciled != FatVpnWidgetModel.STATE_DISCONNECTED

        val connectRequestedAt = widgetPrefs.getLong(WIDGET_KEY_CONNECT_REQUESTED_AT, 0L)
        // Dropped as soon as the tunnel has something to say for itself: from
        // then on its own state is the better information. Note that `error`
        // does not count as the tunnel speaking — it is what the *previous*
        // session left behind, and a connect that has not reached the tunnel yet
        // must not be drawn from it.
        val tunnelSpeaksForItself = reconciled == FatVpnWidgetModel.STATE_CONNECTED ||
            reconciled == FatVpnWidgetModel.STATE_CONNECTING ||
            reconciled == FatVpnWidgetModel.STATE_PREPARING ||
            reconciled == FatVpnWidgetModel.STATE_DISCONNECTING
        val connecting = connectRequestedAt > 0L &&
            System.currentTimeMillis() - connectRequestedAt < CONNECT_OPTIMISM_WINDOW_MS &&
            !tunnelSpeaksForItself

        return FatVpnWidgetModel(
            state = reconciled,
            language = published.optString("lang").takeIf { it.isNotEmpty() },
            signedIn = published.optBoolean("signedIn", false),
            locationLabel = published.optString("locationLabel").takeIf { it.isNotEmpty() },
            flagEmoji = published.optString("flagEmoji").takeIf { it.isNotEmpty() },
            connectedAtMillis = sessionStart(
                published = published.optLong("connectedAtMillis", 0L).takeIf { it > 0L },
                runtime = runtimeConnectedAt,
            ).takeIf { reconciled == FatVpnWidgetModel.STATE_CONNECTED },
            expiresAtMillis = published.optLong("expiresAtMillis", 0L).takeIf { it > 0L },
            stopping = stopping,
            connecting = connecting,
        )
    }

    /// Records that a connect started from the widget is under way, so the very
    /// next redraw says so. `commit()` rather than `apply()`: the redraw is a
    /// broadcast to another component, which would otherwise race the write.
    fun markConnectRequested(context: Context) {
        context.getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(WIDGET_KEY_CONNECT_REQUESTED_AT, System.currentTimeMillis())
            .commit()
    }

    fun clearConnectMarker(context: Context) {
        context.getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(WIDGET_KEY_CONNECT_REQUESTED_AT)
            .commit()
    }

    /// Picks the session start to count from.
    ///
    /// The app's is the earlier of the two whenever a session survived a blip:
    /// [VpnController] deliberately keeps one start across automatic reconnects
    /// and node switches, because that is what "session time" means on the home
    /// screen, while the service records when the *current* tunnel came up. The
    /// widget follows the app so the two clocks agree — but never accepts a
    /// start later than the tunnel's own, which would be a leftover from a
    /// session that has already ended.
    private fun sessionStart(published: Long?, runtime: Long?): Long? = when {
        published == null -> runtime
        runtime == null -> published
        else -> minOf(published, runtime)
    }

    /// Shape of the published snapshot this build understands. Mirrors
    /// `HomeWidgetSnapshot.version` on the Dart side: anything else is read as
    /// "nothing published yet", which the widget already knows how to draw,
    /// rather than guessed at field by field.
    private const val SNAPSHOT_VERSION = 1

    private fun readPublished(context: Context): JSONObject {
        val raw = context
            .getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
            .getString(WIDGET_KEY_SNAPSHOT, null)
            ?: return JSONObject()
        return try {
            val parsed = JSONObject(raw)
            if (parsed.optInt("v", 0) == SNAPSHOT_VERSION) parsed else JSONObject()
        } catch (e: Exception) {
            // A half-written snapshot renders as "nothing published yet", which
            // the widget already knows how to draw.
            JSONObject()
        }
    }

    @Suppress("DEPRECATION")
    private fun isTunnelServiceRunning(context: Context): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return false
        return try {
            manager.getRunningServices(Int.MAX_VALUE)
                .any { it.service.className == SERVICE_CLASS }
        } catch (e: Exception) {
            // Nothing here is worth failing a widget update over; assume the
            // snapshot is honest rather than blanking a live session.
            true
        }
    }

    /// A context whose resources resolve in the app's chosen language, so the
    /// widget's own strings match the app rather than the phone. Falls back to
    /// the given context when the app has never published a language.
    fun localized(context: Context, language: String?): Context {
        val tag = when (language) {
            "en" -> "en"
            "ru" -> "ru"
            else -> return context
        }
        val configuration = Configuration(context.resources.configuration)
        val locale = Locale(tag)
        // Deliberately not Locale.setDefault: this runs on the app's main
        // process during a widget update, and changing the process-wide default
        // would re-language the running app as a side effect of drawing a
        // widget. Only the returned context speaks the chosen language.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            configuration.setLocales(android.os.LocaleList(locale))
        } else {
            configuration.setLocale(locale)
        }
        return context.createConfigurationContext(configuration)
    }
}
