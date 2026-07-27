package com.signbox.singbox_mm

import android.util.Log
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/// What a health probe concluded about the live tunnel.
///
/// [UNKNOWN] is deliberately distinct from [DEAD]: the probe could not be
/// carried out at all (no control API, the core is mid-restart, the device has
/// no upstream), and an unprovable claim must never be turned into a reason to
/// tear a working tunnel down.
internal enum class VpnTunnelHealthVerdict {
    HEALTHY,
    DEAD,
    UNKNOWN,
}

/// Asks the running sing-box instance whether its proxy outbound still carries
/// traffic, over the core's own control API (`experimental.clash_api`).
///
/// Why go through sing-box rather than just issuing a request from here: this
/// process's sockets are deliberately kept out of the tun device (see
/// [VpnTunBuilderConfigurator] — "prevent self-capture loops"), so anything we
/// dial ourselves travels the *underlay* and comes back successful no matter
/// how dead the tunnel is. The control API's delay test dials the probe URL
/// through the active outbound, which is the question we actually want answered.
internal class VpnTunnelHealthProbe(
    private val readConfigPath: () -> String?,
    private val logTag: String,
) {
    private companion object {
        /// Two independent captive-portal endpoints, both empty 204s served from
        /// everywhere. A verdict of [VpnTunnelHealthVerdict.DEAD] requires *both*
        /// to fail: a single blocked host would otherwise be enough to make the
        /// watchdog restart a perfectly healthy tunnel in a loop.
        val PROBE_URLS = listOf(
            "https://www.gstatic.com/generate_204",
            "http://cp.cloudflare.com/generate_204",
        )

        const val PROBE_TIMEOUT_MS = 8_000
        const val CONTROL_API_TIMEOUT_MS = 5_000

        /// Outbound types that are not the server we want to test.
        val NON_PROXY_OUTBOUND_TYPES = setOf(
            "direct",
            "block",
            "reject",
            "dns",
            "selector",
            "urltest",
            "compatible",
            "fallback",
        )
    }

    /// `host:port` of the core's control API, cached per config file so a probe
    /// every minute doesn't re-read and re-parse the config from disk.
    ///
    /// Volatile because the watchdog gives each tunnel a fresh probe thread:
    /// probes never run concurrently, but they do run on different threads over
    /// the life of the service.
    @Volatile
    private var cachedControllerForConfig: Pair<String, String>? = null

    fun run(): VpnTunnelHealthVerdict {
        val controller = resolveController() ?: return VpnTunnelHealthVerdict.UNKNOWN
        // Reading the outbound tag doubles as a liveness check on the API
        // itself: once this succeeds, anything that goes wrong afterwards is
        // about the outbound rather than about our ability to ask.
        val tag = activeOutboundTag(controller) ?: return VpnTunnelHealthVerdict.UNKNOWN
        for (probeUrl in PROBE_URLS) {
            if (delayTestSucceeds(controller, tag, probeUrl)) {
                return VpnTunnelHealthVerdict.HEALTHY
            }
        }
        return VpnTunnelHealthVerdict.DEAD
    }

    /// Tag of the proxy outbound currently in use, read back from the core
    /// rather than assumed: the tag is the config link's own fragment, which
    /// need not match anything the app knows the node by.
    private fun activeOutboundTag(controller: String): String? {
        val response = httpGet("http://$controller/proxies", CONTROL_API_TIMEOUT_MS)
        if (response == null || response.code != HttpURLConnection.HTTP_OK) {
            return null
        }
        return runCatching {
            val proxies = JSONObject(response.body).optJSONObject("proxies") ?: return@runCatching null
            proxies.keys().asSequence().firstOrNull { key ->
                val type = proxies.optJSONObject(key)?.optString("type")?.lowercase()
                type != null && type.isNotEmpty() && type !in NON_PROXY_OUTBOUND_TYPES
            }
        }.getOrNull()
    }

    private fun delayTestSucceeds(controller: String, tag: String, probeUrl: String): Boolean {
        val encodedTag = URLEncoder.encode(tag, "UTF-8")
        val encodedUrl = URLEncoder.encode(probeUrl, "UTF-8")
        val response = httpGet(
            url = "http://$controller/proxies/$encodedTag/delay" +
                "?url=$encodedUrl&timeout=$PROBE_TIMEOUT_MS",
            // A dead outbound makes this request hang rather than fail: sing-box
            // accepts the connection and then never answers, ignoring the
            // `timeout` parameter. Our own read timeout is therefore the verdict,
            // so it has to outlast the one we asked for.
            timeoutMs = PROBE_TIMEOUT_MS + 4_000,
        )
        return response != null && response.code == HttpURLConnection.HTTP_OK
    }

    /// `host:port` the core's control API listens on, or null when the config
    /// doesn't enable one (nothing can be probed then).
    private fun resolveController(): String? {
        val configPath = readConfigPath() ?: return null
        cachedControllerForConfig?.let { (path, controller) ->
            if (path == configPath) return controller
        }
        val controller = runCatching {
            val config = JSONObject(File(configPath).readText())
            config.optJSONObject("experimental")
                ?.optJSONObject("clash_api")
                ?.optString("external_controller")
                ?.takeIf { it.isNotEmpty() }
                ?.let(::normalizeController)
        }.onFailure {
            Log.w(logTag, "Health probe could not read the control API address", it)
        }.getOrNull() ?: return null
        cachedControllerForConfig = configPath to controller
        return controller
    }

    /// Turns a listen address into one we can dial. A core listening on a
    /// wildcard (`0.0.0.0:16756`, `:::16756`) is reachable on loopback, which is
    /// the only interface this probe may use.
    private fun normalizeController(external: String): String {
        val port = external.substringAfterLast(':', missingDelimiterValue = "")
        if (port.isEmpty() || port.toIntOrNull() == null) return external
        val host = external.substringBeforeLast(':')
        return when (host) {
            "", "0.0.0.0", "::", "[::]", "*" -> "127.0.0.1:$port"
            else -> "$host:$port"
        }
    }

    private data class HttpResponse(val code: Int, val body: String)

    /// Plain GET against the loopback control API. Returns null when the request
    /// couldn't be carried out at all.
    private fun httpGet(url: String, timeoutMs: Int): HttpResponse? {
        var opened: HttpURLConnection? = null
        return runCatching {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = CONTROL_API_TIMEOUT_MS
                readTimeout = timeoutMs
                useCaches = false
            }
            opened = connection
            val code = connection.responseCode
            val stream = if (code in 200..399) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            HttpResponse(code, body)
        }.getOrNull().also {
            runCatching { opened?.disconnect() }
        }
    }
}
