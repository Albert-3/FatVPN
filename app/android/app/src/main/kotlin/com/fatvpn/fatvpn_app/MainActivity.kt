package com.fatvpn.fatvpn_app

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "fatvpn/apps"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Runs off the main thread: enumerating launcher apps and
                    // decoding/compressing every icon takes seconds and would
                    // otherwise freeze the UI (including the screen transition).
                    "getLaunchableApps" -> Thread {
                        val apps = getLaunchableApps()
                        runOnUiThread { result.success(apps) }
                    }.start()
                    else -> result.notImplemented()
                }
            }
    }

    /// Apps that appear in the launcher (app drawer) — the right set for the
    /// split-tunneling picker. Excludes background services/overlays and self.
    private fun getLaunchableApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN, null).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any?>>()
        for (info in pm.queryIntentActivities(intent, 0)) {
            val pkg = info.activityInfo.packageName
            if (pkg == packageName || !seen.add(pkg)) continue
            apps.add(
                mapOf(
                    "name" to info.loadLabel(pm).toString(),
                    "packageName" to pkg,
                    "icon" to drawableToPng(info.loadIcon(pm)),
                )
            )
        }
        return apps
    }

    private fun drawableToPng(drawable: Drawable?): ByteArray? {
        if (drawable == null) return null
        return try {
            // Cap icon size — the picker renders them at 36dp, so full-res
            // adaptive icons (often 288px+) just waste decode/compress time.
            val bmp = Bitmap.createBitmap(ICON_SIZE_PX, ICON_SIZE_PX, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private companion object {
        const val ICON_SIZE_PX = 96
    }
}
