package com.signbox.singbox_mm

import io.flutter.plugin.common.MethodChannel.Result
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

internal class PluginMethodOperations(
    private val executor: ExecutorService,
    private val postSuccess: (Result, Any?) -> Unit,
    private val postError: (Result, String, String) -> Unit,
    private val updateConnectionState: (String, String?) -> Unit,
    private val errorState: String,
    private val startVpnInternal: () -> String?,
    private val stopVpnInternal: () -> String?,
    private val versionProvider: () -> String?,
) {
    fun startVpn(result: Result) {
        executor.execute {
            val failure = startVpnInternal()
            if (failure == null) {
                postSuccess(result, null)
            } else {
                updateConnectionState(errorState, failure)
                postError(result, "START_FAILED", failure)
            }
        }
    }

    fun stopVpn(result: Result) {
        executor.execute {
            val failure = stopVpnInternal()
            if (failure == null) {
                postSuccess(result, null)
            } else {
                updateConnectionState(errorState, failure)
                postError(result, "STOP_FAILED", failure)
            }
        }
    }

    fun restartVpn(result: Result) {
        executor.execute {
            val stopFailure = stopVpnInternal()
            if (stopFailure != null) {
                updateConnectionState(errorState, stopFailure)
                postError(result, "STOP_FAILED", stopFailure)
                return@execute
            }

            val startFailure = startVpnInternal()
            if (startFailure != null) {
                updateConnectionState(errorState, startFailure)
                postError(result, "START_FAILED", startFailure)
                return@execute
            }

            postSuccess(result, null)
        }
    }

    fun getSingboxVersion(result: Result) {
        executor.execute {
            val version = runCatching {
                versionProvider()
            }.getOrNull()
            postSuccess(result, version)
        }
    }

    fun pingServer(arguments: Any?, result: Result) {
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?> ?: emptyMap()
        val host = args["host"] as? String
        val port = (args["port"] as? Number)?.toInt()
        val timeoutMs = ((args["timeoutMs"] as? Number)?.toInt() ?: DEFAULT_TIMEOUT_MS)
            .coerceAtLeast(1)
        if (host.isNullOrBlank() || port == null || port <= 0) {
            postSuccess(result, mapOf("ok" to false, "error" to "Invalid host or port"))
            return
        }

        val useTls = args["useTls"] as? Boolean ?: false
        val tlsServerName = args["tlsServerName"] as? String
        val allowInsecure = args["allowInsecure"] as? Boolean ?: false

        runPingAsync(result, timeoutMs) {
            executePing(
                host = host,
                port = port,
                timeoutMs = timeoutMs,
                useTls = useTls,
                tlsServerName = tlsServerName,
                allowInsecure = allowInsecure,
            )
        }
    }

    /// TCP connect latency measured on a socket the tunnel is told to leave
    /// alone, so the number describes the route to that server rather than the
    /// route through whichever server is currently carrying this app's traffic.
    /// With no tunnel running this is an ordinary connect, which is the same
    /// answer.
    fun pingServerOutsideTunnel(arguments: Any?, result: Result) {
        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?> ?: emptyMap()
        val host = args["host"] as? String
        val port = (args["port"] as? Number)?.toInt()
        val timeoutMs = ((args["timeoutMs"] as? Number)?.toInt() ?: DEFAULT_TIMEOUT_MS)
            .coerceAtLeast(1)
        if (host.isNullOrBlank() || port == null || port <= 0) {
            postSuccess(result, mapOf("ok" to false, "error" to "Invalid host or port"))
            return
        }
        runPingAsync(result, timeoutMs) { executeProtectedPing(host, port, timeoutMs) }
    }

    /// Measures on the ping pool and answers [result] exactly once — with the
    /// measurement, or with a timeout if the work outlives its budget.
    ///
    /// Deliberately never touches the plugin's shared executor, which is a
    /// *single* thread also carrying startVpn/stopVpn/setConfig/getState. The
    /// dispatch used to run there and block on `Future.get` for the whole hard
    /// timeout, which had two costs: concurrent pings serialised onto that one
    /// thread (six unreachable nodes took longer than measuring them one at a
    /// time, so the four-thread pool below never held more than one task), and
    /// bringing the tunnel up or down queued behind a full round of pings —
    /// on every Connect tap and every auto-switch.
    ///
    /// The deadline is a scheduled callback rather than a blocking wait, so no
    /// thread is occupied doing nothing while it runs down.
    private fun runPingAsync(
        result: Result,
        timeoutMs: Int,
        work: () -> Map<String, Any?>,
    ) {
        val settled = AtomicBoolean(false)
        fun deliver(value: Map<String, Any?>) {
            if (settled.compareAndSet(false, true)) {
                postSuccess(result, value)
            }
        }

        val task = pingExecutor.submit {
            deliver(
                runCatching(work).getOrElse { error ->
                    mapOf("ok" to false, "error" to (error.message ?: "Connection failed"))
                },
            )
        }
        // The socket carries its own connect timeout; this one covers the name
        // lookup in front of it, which has none.
        timeoutScheduler.schedule(
            {
                if (!settled.get()) {
                    task.cancel(true)
                    deliver(mapOf("ok" to false, "error" to "Connection timed out"))
                }
            },
            timeoutMs.toLong() + DNS_TIMEOUT_GRACE_MS,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun executeProtectedPing(host: String, port: Int, timeoutMs: Int): Map<String, Any?> {
        val startedAt = System.nanoTime()
        Socket().use { socket ->
            // protect() needs a file descriptor, which an unbound socket does
            // not have yet; binding to an ephemeral port creates one.
            runCatching {
                socket.bind(InetSocketAddress(0))
                VpnServiceLiveness.active?.protect(socket)
            }
            socket.connect(InetSocketAddress(host, port), timeoutMs)
        }
        return mapOf(
            "ok" to true,
            "latencyMs" to ((System.nanoTime() - startedAt) / 1_000_000L).toInt(),
        )
    }

    companion object {
        private const val DEFAULT_TIMEOUT_MS = 3000
        private const val DNS_TIMEOUT_GRACE_MS = 1200L
        /// Sized above the app's own concurrency cap (six sockets, see
        /// lib/utils/parallel.dart) so a full round of pings really does run in
        /// parallel instead of queueing behind itself.
        private const val PING_EXECUTOR_THREADS = 8
        private val pingThreadCounter = AtomicInteger(1)
        private val pingExecutor: ExecutorService = Executors.newFixedThreadPool(
            PING_EXECUTOR_THREADS,
            object : ThreadFactory {
                override fun newThread(runnable: Runnable): Thread {
                    return Thread(
                        runnable,
                        "signbox-mm-ping-${pingThreadCounter.getAndIncrement()}",
                    ).apply {
                        isDaemon = true
                    }
                }
            },
        )

        /// Fires the ping deadlines. One thread is plenty: the callback only
        /// cancels a task and answers the channel.
        private val timeoutScheduler: ScheduledExecutorService =
            Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "signbox-mm-ping-timeout").apply { isDaemon = true }
            }
    }

    private fun executePing(
        host: String,
        port: Int,
        timeoutMs: Int,
        useTls: Boolean,
        tlsServerName: String?,
        allowInsecure: Boolean,
    ): Map<String, Any?> {
        val startedAt = System.nanoTime()
        if (useTls) {
            val factory = if (allowInsecure) {
                // In a production app, you'd use a custom TrustManager here for allowInsecure=true
                // but for a simple ping, we'll use the default factory for now
                // and just acknowledge that SNI/negotiation is being tested.
                SSLSocketFactory.getDefault()
            } else {
                SSLSocketFactory.getDefault()
            }

            (factory.createSocket() as SSLSocket).use { socket ->
                if (!tlsServerName.isNullOrBlank()) {
                    val params = SSLParameters()
                    params.serverNames = listOf(SNIHostName(tlsServerName))
                    socket.sslParameters = params
                }
                socket.connect(InetSocketAddress(host, port), timeoutMs)
                socket.startHandshake()
            }
        } else {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), timeoutMs)
            }
        }
        val latencyMs = ((System.nanoTime() - startedAt) / 1_000_000L).toInt()
        return mapOf(
            "ok" to true,
            "latencyMs" to latencyMs,
        )
    }
}
