package com.fatvpn.fatvpn_app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.fatvpn.fatvpn_app.R
import java.util.UUID

/// The FatVPN home-screen widget: current tunnel state, where it runs, how long
/// it has been up, and a power button.
///
/// The power button is a button, not a shortcut: both directions happen without
/// the app, and only a tap *outside* it opens the app.
///
///  * **Stopping** is done here, in the widget's own process — the tunnel is our
///    service and telling it to stop needs nothing else. One tap, no app.
///  * **Starting** goes to [WidgetConnectService], which runs the app's own
///    connect logic in a background Flutter engine. It deliberately does not
///    start from the last config on disk: bringing the tunnel up needs a live
///    entitlement check (`/servers` answers 402 the moment a subscription
///    lapses) and a fresh subscription, or the widget would reconnect a user
///    on credentials the panel has already revoked. With no country chosen —
///    which is every first press — it connects to the fastest node overall.
///  * The one case that still opens the app is the one that cannot be answered
///    without a screen: no session, a lapsed subscription, or the system's VPN
///    consent dialog on a device that has never connected.
open class FatVpnWidgetProvider : AppWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            // A widget provider has to be exported — that is how the launcher
            // reaches it — which means any app on the device can send it an
            // explicit intent, this action included. For a VPN that is not a
            // theoretical problem: a silent "stop" from a hostile app drops the
            // user's traffic out of the tunnel without a single visible sign.
            // So the tap is authenticated by a token that only ever exists in
            // this app's private preferences and inside an immutable
            // PendingIntent the launcher cannot rewrite.
            ACTION_TOGGLE ->
                if (isOwnToggle(context, intent)) {
                    handleToggle(context)
                } else {
                    Log.w(TAG, "Ignoring a toggle that did not come from our widget")
                }
            // Broadcast by the vendored plugin's VPN service on every state
            // change (see SignboxLibboxServiceContract.ACTION_STATE_UPDATE). It
            // is what keeps the widget honest while the app is not running —
            // e.g. the user stops the tunnel from its notification.
            ACTION_TUNNEL_STATE -> {
                clearStopMarkerIfSettled(context, intent.getStringExtra(EXTRA_STATE))
                refresh(context)
            }
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            render(context, appWidgetManager, id)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        // Resizing picks a different layout on pre-31 devices, where the size
        // mapping below is not available.
        render(context, appWidgetManager, appWidgetId)
    }

    private fun handleToggle(context: Context) {
        val model = FatVpnWidgetState.read(context)
        if (!model.signedIn) {
            // No usable subscription: the only honest action is to open the app,
            // which shows why (onboarding, or the renew screen).
            launchApp(context, null)
            return
        }
        when {
            // A connect this widget started that has not reached the tunnel
            // yet: there is nothing to stop, so the tap cancels the attempt
            // instead of asking a service that does not exist to shut down. The
            // moment the tunnel *has* started, [FatVpnWidgetModel.connecting] is
            // false and the branch below takes over — the two never overlap.
            model.connecting -> cancelStart(context)
            model.isUp || model.isBusy -> requestStop(context)
            else -> requestStart(context)
        }
        refresh(context)
    }

    private fun cancelStart(context: Context) {
        FatVpnWidgetState.clearConnectMarker(context)
        try {
            context.stopService(Intent(context, WidgetConnectService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Could not cancel the connect started from the widget: $e")
        }
    }

    /// Brings the tunnel up without opening the app — see [WidgetConnectService]
    /// for why that needs a background Flutter engine rather than a service
    /// start, and [handleToggle] for when it is allowed to happen at all.
    private fun requestStart(context: Context) {
        FatVpnWidgetState.markConnectRequested(context)
        try {
            WidgetConnectService.start(context)
        } catch (e: Exception) {
            // Starting a foreground service from the background is restricted,
            // and the exemption this relies on — the user having just tapped a
            // widget — is not something to bet a dead-looking button on. The app
            // can always connect, so fall back to it.
            Log.w(TAG, "Could not start the connect service from the widget: $e")
            FatVpnWidgetState.clearConnectMarker(context)
            launchApp(context, WIDGET_LINK_CONNECT)
        }
    }

    /// Tells the running tunnel service to stop, and marks the widget as
    /// "disconnecting" so the tap has a visible effect before the service gets
    /// around to broadcasting its new state.
    private fun requestStop(context: Context) {
        context.getSharedPreferences(FatVpnWidgetState.WIDGET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(FatVpnWidgetState.WIDGET_KEY_STOP_REQUESTED_AT, System.currentTimeMillis())
            .apply()
        val intent = Intent()
            .setClassName(context, TUNNEL_SERVICE_CLASS)
            .setAction(ACTION_TUNNEL_STOP)
        try {
            context.startService(intent)
        } catch (e: Exception) {
            // Starting a service from the background is restricted, and the one
            // exemption this relies on — the user having just tapped a widget —
            // is not something to bet a dead-looking button on. Fall back to the
            // app, which can always stop the tunnel.
            Log.w(TAG, "Could not stop the tunnel from the widget: $e")
            clearStopMarker(context)
            launchApp(context, WIDGET_LINK_DISCONNECT)
        }
    }

    private fun launchApp(context: Context, link: String?) {
        val intent = if (link != null) {
            Intent(Intent.ACTION_VIEW, Uri.parse(link)).setPackage(context.packageName)
        } else {
            context.packageManager.getLaunchIntentForPackage(context.packageName)
        } ?: return
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Could not open the app from the widget: $e")
        }
    }

    private fun clearStopMarkerIfSettled(context: Context, state: String?) {
        if (state == FatVpnWidgetModel.STATE_DISCONNECTED || state == "error") {
            clearStopMarker(context)
        }
        // The tunnel is up: whatever this widget started has arrived, and the
        // marker it left behind has nothing left to say.
        if (state == FatVpnWidgetModel.STATE_CONNECTED) {
            FatVpnWidgetState.clearConnectMarker(context)
        }
    }

    private fun clearStopMarker(context: Context) {
        context.getSharedPreferences(FatVpnWidgetState.WIDGET_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(FatVpnWidgetState.WIDGET_KEY_STOP_REQUESTED_AT)
            .apply()
    }

    private fun refresh(context: Context) = notifyWidgets(context)

    private fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
        val model = FatVpnWidgetState.read(context)
        val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Let the launcher pick per size instead of guessing from the
            // options bundle: the same widget is a 2x1 tile on one home screen
            // and a 4x2 card on the next.
            RemoteViews(
                mapOf(
                    SizeF(SQUARE_WIDTH_DP, SQUARE_HEIGHT_DP) to
                        buildViews(context, model, R.layout.widget_fatvpn_square),
                    SizeF(COMPACT_MAX_WIDTH_DP, COMPACT_MAX_HEIGHT_DP) to
                        buildViews(context, model, R.layout.widget_fatvpn_compact),
                    SizeF(WIDE_WIDTH_DP, WIDE_HEIGHT_DP) to
                        buildViews(context, model, R.layout.widget_fatvpn_wide),
                ),
            )
        } else {
            val options = manager.getAppWidgetOptions(appWidgetId)
            val minWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0
            val minHeight = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0) ?: 0
            // Each test is against the layout's *own* size, not the previous
            // one's. Comparing the wide layout to the compact threshold handed
            // the three-line layout to a one-row widget, and RemoteViews does
            // not scale what does not fit — it clips it, so the bottom line was
            // sawn in half on the device (Redmi Note 7, Android 10).
            //
            // Order matters: a 2×2 tile is tall enough for the square layout but
            // too narrow for the wide one, so "wide" has to be asked first and
            // "square" is what a tall-but-narrow tile falls into.
            val layout = when {
                minWidth >= WIDE_WIDTH_DP && minHeight >= WIDE_HEIGHT_DP ->
                    R.layout.widget_fatvpn_wide
                minHeight >= SQUARE_HEIGHT_DP -> R.layout.widget_fatvpn_square
                else -> R.layout.widget_fatvpn_compact
            }
            buildViews(context, model, layout)
        }
        manager.updateAppWidget(appWidgetId, views)
    }

    private fun buildViews(
        context: Context,
        model: FatVpnWidgetModel,
        layoutId: Int,
    ): RemoteViews {
        val localized = FatVpnWidgetState.localized(context, model.language)
        val views = RemoteViews(context.packageName, layoutId)

        val statusRes = when {
            !model.signedIn -> R.string.widget_status_signed_out
            model.stopping || model.state == FatVpnWidgetModel.STATE_DISCONNECTING ->
                R.string.widget_status_disconnecting
            model.state == FatVpnWidgetModel.STATE_CONNECTED -> R.string.widget_status_connected
            model.connecting ||
                model.state == FatVpnWidgetModel.STATE_CONNECTING ||
                model.state == FatVpnWidgetModel.STATE_PREPARING ->
                R.string.widget_status_connecting
            else -> R.string.widget_status_disconnected
        }
        views.setTextViewText(R.id.widget_status, localized.getString(statusRes))

        val up = model.isUp && !model.stopping
        views.setInt(
            R.id.widget_dot,
            "setColorFilter",
            localized.getColor(if (up) R.color.widget_accent else R.color.widget_text_secondary),
        )
        // The same inversion the home screen's power button uses: a dark glyph
        // on a solid accent disc while the tunnel is up, a muted glyph on the
        // card colour while it is down. Anything else and the two buttons —
        // one tap apart — look like different products.
        views.setImageViewResource(
            R.id.widget_power_bg,
            if (up) R.drawable.widget_power_on else R.drawable.widget_power_off,
        )
        views.setInt(
            R.id.widget_power,
            "setColorFilter",
            localized.getColor(
                when {
                    up -> R.color.widget_bg
                    model.signedIn -> R.color.widget_text_secondary
                    else -> R.color.widget_disabled
                },
            ),
        )

        // "🇩🇪 DE", or the localized "Best server" while no country is chosen —
        // the same two forms the location card on the home screen shows.
        views.setTextViewText(
            R.id.widget_location,
            buildString {
                if (!model.flagEmoji.isNullOrEmpty()) {
                    append(model.flagEmoji)
                    append(' ')
                }
                append(
                    model.locationLabel
                        ?: localized.getString(R.string.widget_location_best),
                )
            },
        )

        // What the last line carries, and why it differs per layout.
        //
        // The compact and square layouts have one line for everything below the
        // status, and the location has to win it: the call to action
        // ("Подключиться") next to it left both ellipsized on a real 4x1 widget,
        // and the power button says the same thing without spending a pixel. The
        // exception is having no session at all — then there is no location
        // worth showing and the only useful words are "open the app". Only the
        // wide layout has a line to spare, and it spends it on the hint.
        val narrow = layoutId != R.layout.widget_fatvpn_wide
        val sessionStart = model.connectedAtMillis
        val showTimer = model.isUp && !model.stopping && sessionStart != null
        val showHint = if (narrow) !model.signedIn else !showTimer
        views.setViewVisibility(
            R.id.widget_location,
            if (narrow && !model.signedIn) View.GONE else View.VISIBLE,
        )
        views.setViewVisibility(R.id.widget_hint, if (showHint) View.VISIBLE else View.GONE)

        if (sessionStart != null && showTimer) {
            views.setChronometer(
                R.id.widget_timer,
                // Chronometer counts in elapsed-realtime, so the wall-clock
                // start has to be translated into that clock. Doing it here
                // means the widget ticks on its own — no update per second, and
                // no waking the app to redraw a clock.
                SystemClock.elapsedRealtime() - (System.currentTimeMillis() - sessionStart),
                null,
                true,
            )
            views.setViewVisibility(R.id.widget_timer, View.VISIBLE)
        } else {
            // Stopped, not just hidden: a Chronometer left running keeps
            // ticking inside the launcher's process behind a GONE view.
            views.setChronometer(R.id.widget_timer, SystemClock.elapsedRealtime(), null, false)
            views.setViewVisibility(R.id.widget_timer, View.GONE)
        }

        views.setTextViewText(
            R.id.widget_hint,
            localized.getString(
                if (model.signedIn) {
                    R.string.widget_hint_tap_to_connect
                } else {
                    R.string.widget_hint_open_app
                },
            ),
        )

        views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))
        views.setOnClickPendingIntent(R.id.widget_power_touch, toggleIntent(context))
        return views
    }

    private fun openAppIntent(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            REQUEST_OPEN_APP,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun toggleIntent(context: Context): PendingIntent {
        val intent = Intent(context, FatVpnWidgetProvider::class.java)
            .setAction(ACTION_TOGGLE)
            .putExtra(EXTRA_TOKEN, toggleToken(context))
        return PendingIntent.getBroadcast(
            context,
            REQUEST_TOGGLE,
            intent,
            // IMMUTABLE matters twice over here: it keeps the launcher (or
            // anything else holding this PendingIntent) from swapping the
            // action or the token for something else.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun isOwnToggle(context: Context, intent: Intent): Boolean {
        val presented = intent.getStringExtra(EXTRA_TOKEN) ?: return false
        return presented == toggleToken(context)
    }

    /// The per-install secret carried by the widget's own toggle intent.
    /// Generated on first use and kept in the app's private preferences, so it
    /// is unreadable to other apps and stable across widget redraws.
    private fun toggleToken(context: Context): String {
        val prefs = context.getSharedPreferences(
            FatVpnWidgetState.WIDGET_PREFS,
            Context.MODE_PRIVATE,
        )
        prefs.getString(KEY_TOGGLE_TOKEN, null)?.let { return it }
        val token = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_TOGGLE_TOKEN, token).commit()
        return token
    }

    companion object {
        private const val TAG = "FatVpnWidget"

        const val ACTION_TOGGLE = "com.fatvpn.fatvpn_app.widget.action.TOGGLE"

        /// Mirrors of the vendored plugin's contract (see
        /// SignboxLibboxServiceContract). Duplicated rather than imported: the
        /// plugin declares them `internal`, so they are invisible outside its
        /// own Gradle module — and the same strings are hard-coded in this
        /// app's AndroidManifest intent-filter, which no import could avoid.
        ///
        /// Nothing here fails to compile if the plugin renames one: the widget
        /// would simply stop being updated by the tunnel, and the first sign of
        /// it is a device check (TW5 in docs/release-test-checklist.md — stop
        /// the tunnel from the notification and watch the widget).
        const val ACTION_TUNNEL_STATE = "com.signbox.singbox_mm.action.STATE"
        const val ACTION_TUNNEL_STOP = "com.signbox.singbox_mm.action.STOP"
        const val EXTRA_STATE = "state"

        /// Proves a toggle came from our own widget — see [isOwnToggle].
        const val EXTRA_TOKEN = "token"
        private const val KEY_TOGGLE_TOKEN = "toggleToken"
        const val TUNNEL_SERVICE_CLASS = "com.signbox.singbox_mm.SignboxLibboxVpnService"

        const val WIDGET_LINK_CONNECT = "fatvpn://widget/connect"
        const val WIDGET_LINK_DISCONNECT = "fatvpn://widget/disconnect"

        private const val REQUEST_OPEN_APP = 0x7A01
        private const val REQUEST_TOGGLE = 0x7A02

        /// Breakpoints for the two layouts, in dp. A launcher cell is ~70dp
        /// wide, so "compact" covers 2x1 and 3x1 tiles and "wide" starts at the
        /// 4-cell row where a location line and a clock actually fit.
        private const val COMPACT_MAX_WIDTH_DP = 200f
        private const val COMPACT_MAX_HEIGHT_DP = 60f
        private const val WIDE_WIDTH_DP = 250f

        /// The wide layout needs three text lines plus 28dp of padding, so it
        /// is offered only from two launcher rows up. Measured against the real
        /// thing: a one-row placement on a Redmi Note 7 gives about 85dp, and
        /// the three-line layout wants ~100.
        private const val WIDE_HEIGHT_DP = 110f

        /// The 2×2 tile: two launcher cells each way, which is about 110dp at
        /// the smallest a launcher will hand out. Both numbers are the square
        /// layout's own minimum, not the tile's typical size — the size map on
        /// API 31+ picks the largest layout that *fits*, so claiming more than
        /// the layout needs would leave a real 2×2 with the compact layout
        /// stretched across it.
        private const val SQUARE_WIDTH_DP = 110f
        private const val SQUARE_HEIGHT_DP = 110f

        /// Every provider the app declares. Two of them, and they differ in
        /// nothing but the size the launcher places them at: the 2×2 is a
        /// separate entry in the widget picker (that is the only way to offer a
        /// second default size), and it draws through this same class.
        private val PROVIDERS = listOf(
            FatVpnWidgetProvider::class.java,
            FatVpnWidgetSquareProvider::class.java,
        )

        /// Redraws every placed widget, of either size. Called from here on a
        /// tap and from [FatVpnWidgetChannel] whenever the app publishes a new
        /// snapshot.
        fun notifyWidgets(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            for (provider in PROVIDERS) {
                val ids = manager.getAppWidgetIds(ComponentName(context, provider))
                if (ids.isEmpty()) continue
                val intent = Intent(context, provider)
                    .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                context.sendBroadcast(intent)
            }
        }
    }
}
