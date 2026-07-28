package com.fatvpn.fatvpn_app.widget

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.fatvpn.fatvpn_app.R
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/// Brings the tunnel up from a widget tap, without opening the app.
///
/// The button on the widget has to *be* a button — the user asked for the tunnel
/// to come up, not for an app to be launched at them — and stopping was already
/// done here (the tunnel is our own service). Starting is the hard direction,
/// because it is not "launch a service": it needs a live entitlement check
/// (`/servers` answers 402 the moment a subscription lapses), a fresh
/// subscription config, and a choice of node. All of that already exists — in
/// Dart. So instead of a second, half-correct implementation in Kotlin, this
/// runs the *same* code in a background Flutter engine with no UI attached
/// (`widgetConnectMain`, lib/widget_connect_entry.dart).
///
/// Why a foreground service and not just the broadcast receiver: a receiver is
/// given about ten seconds and this takes longer — a `/config` round trip plus a
/// ping of every candidate node. A background process holding a Flutter engine
/// is a candidate for being killed the moment the receiver returns; a foreground
/// service is not, and the "Connecting…" notification is honest about what the
/// tap set off. It goes away as soon as the tunnel's own notification appears.
class WidgetConnectService : Service() {

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private var finished = false

    private val timeout = Runnable {
        Log.w(TAG, "Connect took too long — giving up and opening the app")
        finish(OUTCOME_HAND_OVER)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A tap that arrives between `stopSelf` and the service actually going
        // away is delivered to *this* instance, and it is a new attempt: without
        // clearing the flag, [finish] would no-op and the engine below would run
        // with nothing left to stop it.
        if (engine == null) finished = false
        if (!startForegroundWithNotice()) {
            // The platform refused to let this run in the foreground, which is
            // the one thing it has to do before it can spend twenty seconds
            // connecting. Hand the job to the app rather than risk being killed
            // mid-connect — or, on API 31+, crash on the exception that refusal
            // is delivered as.
            finish(OUTCOME_HAND_OVER)
            return START_NOT_STICKY
        }
        // A second tap while the first connect is still running is the user
        // being impatient, not a request to start twice: two engines would
        // fetch two configs and race each other into the same tunnel.
        if (engine != null) {
            Log.i(TAG, "A connect is already running — ignoring this tap")
            return START_NOT_STICKY
        }
        try {
            startEngine()
        } catch (e: Throwable) {
            // Every reason this can fail (no Flutter assets, an engine that
            // refuses to start) leaves the user with a button that did nothing.
            // The app can always connect, so fall back to it.
            Log.e(TAG, "Could not start the background engine: $e")
            finish(OUTCOME_HAND_OVER)
            return START_NOT_STICKY
        }
        handler.postDelayed(timeout, CONNECT_TIMEOUT_MS)
        return START_NOT_STICKY
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)

        // `automaticallyRegisterPlugins = false`, with the registrant called by
        // hand below. The one-argument constructor registers plugins itself, by
        // reflection, inside the constructor — before this service can attach
        // its own channels — and calling the registrant as well would then bind
        // every plugin twice on the same engine.
        val created = FlutterEngine(applicationContext, null, false)
        // The Dart side publishes the widget snapshot over this channel exactly
        // as the app does; without it a connect made from the widget would show
        // the tunnel's state but never the country it landed in.
        val widgetChannel = FatVpnWidgetChannel(applicationContext).apply {
            attach(created.dartExecutor.binaryMessenger)
        }
        channel = MethodChannel(
            created.dartExecutor.binaryMessenger,
            OUTCOME_CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "finished") {
                    result.success(null)
                    val outcome = call.arguments as? String ?: OUTCOME_FAILED
                    // Posted, not run here: tearing the engine down from inside
                    // the dispatch of one of its own platform messages is asking
                    // for a crash. By the next loop turn the message is done.
                    handler.post {
                        widgetChannel.detach()
                        finish(outcome)
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
        // Same set of plugins the app runs on: this engine reads the session
        // from secure storage and drives the tunnel through the same plugin.
        GeneratedPluginRegistrant.registerWith(created)
        // Two arguments, not three: the entrypoint lives in the app's root
        // library (lib/main.dart). Naming a library here would work just as
        // well for the engine, but an entrypoint in a library nothing imports is
        // not in a release snapshot at all — see widgetConnectMain's comment.
        created.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), DART_ENTRYPOINT),
        )
        engine = created
    }

    /// Ends the run, whatever it was: tears the engine down, drops the
    /// "connecting" marker the widget is drawing from, and — when the connect
    /// could not be finished here — opens the app so the user lands somewhere
    /// they can act (a consent dialog, the renew screen, an error).
    private fun finish(outcome: String) {
        if (finished) return
        finished = true
        handler.removeCallbacks(timeout)
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        FatVpnWidgetState.clearConnectMarker(this)
        if (outcome == OUTCOME_HAND_OVER) {
            openApp()
        }
        FatVpnWidgetProvider.notifyWidgets(this)
        stopForegroundCompat()
        stopSelf()
    }

    private fun openApp() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(FatVpnWidgetProvider.WIDGET_LINK_CONNECT))
            .setPackage(packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try {
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Could not open the app after a widget connect: $e")
        }
    }

    /// Goes into the foreground with a "Connecting…" notice. False when the
    /// platform said no — see the caller.
    ///
    /// Every start of this service is a widget tap, which is exactly the case
    /// the background-start rules exempt (the launcher hands its own permission
    /// over with the PendingIntent), so this should not fail. "Should not" is
    /// not "cannot", and the refusal arrives as an exception thrown out of
    /// `startForeground` on API 31+ rather than as a failed start, so it has to
    /// be caught here and nowhere else.
    private fun startForegroundWithNotice(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
            // IMPORTANCE_LOW: no sound, no heads-up. This notification exists
            // because the platform requires one, not because a connect the user
            // just asked for is news.
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL,
                getString(R.string.widget_connect_channel),
                NotificationManager.IMPORTANCE_LOW,
            )
            manager.createNotificationChannel(channel)
        }
        val localized = FatVpnWidgetState.localized(
            this,
            FatVpnWidgetState.read(this).language,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_widget_power)
            .setContentTitle(localized.getString(R.string.widget_name))
            .setContentText(localized.getString(R.string.widget_status_connecting))
            .setOngoing(true)
            .setContentIntent(appPendingIntent())
            .build()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Not allowed to run the connect in the foreground: $e")
            false
        }
    }

    private fun appPendingIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            REQUEST_OPEN_APP,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(timeout)
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        // A service killed from outside must not leave the widget claiming a
        // connect is still in progress.
        FatVpnWidgetState.clearConnectMarker(this)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "FatVpnWidgetConnect"

        private const val OUTCOME_CHANNEL = "fatvpn/widget_connect"

        /// Top-level function in lib/main.dart, looked up by name.
        private const val DART_ENTRYPOINT = "widgetConnectMain"

        /// Mirrors `WidgetConnectOutcome` on the Dart side. Only "handOverToApp"
        /// is acted on here; the rest differ only in what was logged.
        private const val OUTCOME_HAND_OVER = "handOverToApp"
        private const val OUTCOME_FAILED = "failed"

        private const val NOTIFICATION_CHANNEL = "fatvpn_widget_connect"
        private const val NOTIFICATION_ID = 0x7A11
        private const val REQUEST_OPEN_APP = 0x7A03

        /// Ceiling on one attempt. Generous because the work behind it is two
        /// network round trips and a ping of every node in the subscription, on
        /// whatever connection the user has; past this the honest thing is to
        /// stop pretending and open the app.
        private const val CONNECT_TIMEOUT_MS = 90_000L

        fun start(context: Context) {
            val intent = Intent(context, WidgetConnectService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
