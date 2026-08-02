package com.fatvpn.fatvpn_app

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.fatvpn.fatvpn_app.widget.FatVpnWidgetChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "fatvpn/apps"
    private var channel: MethodChannel? = null

    /// Mirrors the session into the home-screen widget. Bound to the
    /// application context, not this Activity: what it writes outlives the UI.
    private var widgetChannel: FatVpnWidgetChannel? = null

    /// One daemon worker instead of a thread per call: the only caller is the
    /// split-tunnel picker, and two overlapping enumerations would compete for
    /// the same PackageManager rather than finish sooner.
    private var worker: ExecutorService? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "fatvpn-apps").apply { isDaemon = true }
        }
        widgetChannel = FatVpnWidgetChannel(applicationContext).apply {
            attach(flutterEngine.dartExecutor.binaryMessenger)
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        // Off the main thread: enumerating launcher apps and
                        // decoding/compressing every icon takes seconds and would
                        // otherwise freeze the UI (including the transition).
                        "getLaunchableApps" -> worker?.execute {
                            val apps = getLaunchableApps()
                            runOnUiThread { result.success(apps) }
                        } ?: result.error("UNAVAILABLE", "Activity is shutting down", null)
                        "getDeviceIdentifier" -> result.success(deviceIdentifier())
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The handler holds this Activity; without clearing it, an engine that
        // outlives the Activity keeps it (and its window) alive.
        channel?.setMethodCallHandler(null)
        channel = null
        widgetChannel?.detach()
        widgetChannel = null
        worker?.shutdownNow()
        worker = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /// A device identity that survives reinstalling the app, for the trial's
    /// `attestationToken` — the anti-abuse gap was that a purely local random
    /// key resets with the install, so uninstall → reinstall meant a fresh
    /// free trial forever.
    ///
    /// SSAID (ANDROID_ID) is stable per device + user + *signing key*, and in
    /// particular survives an uninstall. Hashed before it leaves the process:
    /// the server only ever needs a stable opaque string (it salts and hashes
    /// it again), and the raw SSAID is a cross-checkable device identifier
    /// that shouldn't travel. Returns null on the values that are known not
    /// to identify a device (empty, and the infamous constant that a batch of
    /// old handsets all shared), so Dart falls back to the random key.
    private fun deviceIdentifier(): String? {
        return try {
            val ssaid = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            if (ssaid.isNullOrEmpty() || ssaid == "9774d56d682e549c") return null
            MessageDigest.getInstance("SHA-256")
                .digest("fatvpn-device:$ssaid".toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            null
        }
    }

    /// Apps that appear in the launcher (app drawer) — the right set for the
    /// split-tunneling picker. Excludes background services/overlays and self.
    private fun getLaunchableApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN, null).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any?>>()
        var iconFailures = 0
        for (info in pm.queryIntentActivities(intent, 0)) {
            val pkg = info.activityInfo.packageName
            if (pkg == packageName || !seen.add(pkg)) continue
            val icon = iconBytesFor(pm, info, pkg)
            if (icon == null) iconFailures++
            apps.add(
                mapOf(
                    "name" to info.loadLabel(pm).toString(),
                    "packageName" to pkg,
                    "icon" to icon,
                )
            )
        }
        // A picker that comes back with names and no pictures has been seen
        // once and never explained, because every failure below was swallowed.
        // One line per enumeration is enough to tell "the icons never rendered"
        // apart from "the bytes never survived the trip to Dart".
        Log.i(TAG, "launchable apps: ${apps.size}, icons missing: $iconFailures")
        return apps
    }

    /// The activity's own icon, falling back to the application icon: an
    /// activity-level icon can fail to load on its own (a stale resource
    /// reference in a package updated under us), and the app icon is the same
    /// picture to anyone reading this list.
    private fun iconBytesFor(
        pm: android.content.pm.PackageManager,
        info: android.content.pm.ResolveInfo,
        pkg: String,
    ): ByteArray? {
        drawableToImageBytes(info.loadIcon(pm), pkg)?.let { return it }
        return try {
            drawableToImageBytes(pm.getApplicationIcon(pkg), pkg)
        } catch (e: Exception) {
            Log.w(TAG, "no application icon for $pkg", e)
            null
        }
    }

    /// Renders an app icon small enough to travel over the platform channel.
    ///
    /// Lossy WEBP rather than lossless PNG: a phone with 200 apps sent 1.5-3 MB
    /// in a single message, and serialising that blocks the UI thread for
    /// hundreds of milliseconds. At quality 80 the same icons are roughly a
    /// fifth of the size and indistinguishable at the 36dp the picker draws.
    private fun drawableToImageBytes(drawable: Drawable?, pkg: String): ByteArray? {
        if (drawable == null) return null
        var bmp: Bitmap? = null
        return try {
            // Cap icon size — the picker renders them at 36dp, so full-res
            // adaptive icons (often 288px+) just waste decode/compress time.
            bmp = Bitmap.createBitmap(ICON_SIZE_PX, ICON_SIZE_PX, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            val stream = ByteArrayOutputStream()
            // compress() answers false rather than throwing when the encoder
            // refuses the bitmap; an empty byte array reaches Dart as bytes
            // that decode to nothing, which is worse than no icon at all.
            if (!bmp.compress(webpFormat(), ICON_QUALITY, stream)) {
                Log.w(TAG, "icon compress refused for $pkg")
                return null
            }
            val bytes = stream.toByteArray()
            if (bytes.isEmpty()) null else bytes
        } catch (e: Exception) {
            Log.w(TAG, "icon render failed for $pkg", e)
            null
        } finally {
            // ~200 apps × 96×96 ARGB_8888 is 7 MB of bitmaps allocated in one
            // tight loop; leaving them to the collector is how the second run
            // of this method meets memory pressure the first one never did.
            bmp?.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private fun webpFormat(): Bitmap.CompressFormat =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Bitmap.CompressFormat.WEBP_LOSSY
        } else {
            Bitmap.CompressFormat.WEBP
        }

    private companion object {
        const val TAG = "FatVpnApps"
        const val ICON_SIZE_PX = 96
        const val ICON_QUALITY = 80
    }
}
