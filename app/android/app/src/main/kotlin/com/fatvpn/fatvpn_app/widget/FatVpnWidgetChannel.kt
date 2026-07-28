package com.fatvpn.fatvpn_app.widget

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/// Receives the snapshot the app publishes (see `HomeWidgetBridge` on the Dart
/// side) and stores it where the widget can read it without the app.
///
/// Nothing here talks to the tunnel: the tunnel's own state comes from the
/// plugin's store (see [FatVpnWidgetState]). This channel carries only what the
/// app alone knows — the chosen location, the language, the subscription.
class FatVpnWidgetChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "publish" -> {
                val arguments = call.arguments as? Map<*, *>
                if (arguments == null) {
                    result.error("BAD_ARGS", "publish expects a map", null)
                    return
                }
                publish(arguments)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun publish(arguments: Map<*, *>) {
        val json = JSONObject()
        // Copied field by field rather than via JSONObject(Map): the map comes
        // from another language's serializer, and a silent `null` or a Double
        // where a Long belongs would surface as a widget that renders "1970".
        json.put("v", (arguments["v"] as? Number)?.toInt() ?: 0)
        putIfPresent(json, "state", arguments["state"] as? String)
        putIfPresent(json, "lang", arguments["lang"] as? String)
        json.put("signedIn", arguments["signedIn"] as? Boolean ?: false)
        putIfPresent(json, "locationLabel", arguments["locationLabel"] as? String)
        putIfPresent(json, "flagEmoji", arguments["flagEmoji"] as? String)
        putIfPresent(json, "connectedAtMillis", (arguments["connectedAtMillis"] as? Number)?.toLong())
        putIfPresent(json, "expiresAtMillis", (arguments["expiresAtMillis"] as? Number)?.toLong())

        val prefs = context.getSharedPreferences(
            FatVpnWidgetState.WIDGET_PREFS,
            Context.MODE_PRIVATE,
        )
        val editor = prefs.edit().putString(FatVpnWidgetState.WIDGET_KEY_SNAPSHOT, json.toString())
        // The app confirming the tunnel is down settles any stop this widget
        // asked for; leaving the marker would keep it saying "disconnecting"
        // for the rest of its optimism window.
        if (arguments["state"] == FatVpnWidgetModel.STATE_DISCONNECTED) {
            editor.remove(FatVpnWidgetState.WIDGET_KEY_STOP_REQUESTED_AT)
        }
        // commit(), not apply(): the widget update below reads these prefs back
        // from a different component, and apply()'s write is asynchronous.
        editor.commit()

        FatVpnWidgetProvider.notifyWidgets(context)
    }

    private fun putIfPresent(json: JSONObject, key: String, value: Any?) {
        if (value == null) return
        json.put(key, value)
    }

    private companion object {
        const val CHANNEL_NAME = "fatvpn/widget"
    }
}
