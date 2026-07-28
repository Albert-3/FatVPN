package com.signbox.singbox_mm

import android.content.Context
import io.nekohasekai.libbox.Libbox
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.util.concurrent.ExecutorService

internal class PluginConfigOperations(
    private val context: Context,
    private val executor: ExecutorService,
    private val runtimeConfigStore: PluginRuntimeConfigStore,
    private val postSuccess: (Result, Any?) -> Unit,
    private val postError: (Result, String, String) -> Unit,
) {
    fun initialize(arguments: Any?, result: Result) {
        executor.execute {
            try {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any?> ?: emptyMap()
                runtimeConfigStore.initialize(args)
                postSuccess(result, null)
            } catch (error: Throwable) {
                postError(result, "INIT_FAILED", error.message ?: "Initialization failed")
            }
        }
    }

    fun validateConfig(arguments: Any?, result: Result) {
        executor.execute {
            try {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any?> ?: emptyMap()
                val config = args["config"] as? String
                if (config.isNullOrBlank()) {
                    postError(result, "INVALID_CONFIG", "Missing config payload")
                    return@execute
                }

                VpnCoreSetupManager.ensure(context)
                Libbox.checkConfig(config)
                val normalized =
                    runCatching {
                        Libbox.formatConfig(config).value
                    }.getOrNull().takeUnless { it.isNullOrBlank() } ?: config
                postSuccess(result, normalized)
            } catch (error: Throwable) {
                postError(
                    result,
                    "CONFIG_VALIDATE_FAILED",
                    error.message ?: "Config validation failed",
                )
            }
        }
    }

    fun setConfig(arguments: Any?, result: Result) {
        executor.execute {
            try {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any?> ?: emptyMap()
                val config = args["config"] as? String
                if (config.isNullOrBlank()) {
                    postError(result, "INVALID_CONFIG", "Missing config payload")
                    return@execute
                }

                runtimeConfigStore.writeConfig(config)
                postSuccess(result, null)
            } catch (error: Throwable) {
                postError(result, "CONFIG_WRITE_FAILED", error.message ?: "Could not write config")
            }
        }
    }

    /// Erases everything this plugin persists about the subscription that was
    /// running: both config files (sing-box and Xray — each quotes the node
    /// credentials verbatim), sing-box's stderr log (node addresses, SNI, DNS
    /// queries), and the runtime-state snapshot (whose stored error quotes the
    /// same stderr). Called on sign-out and on a deliberate power-off — was a
    /// silent no-op on Android (`notImplemented`, swallowed by the Dart side's
    /// `_invokeOptional`), so the config with the subscription's UUID used to
    /// survive logout.
    ///
    /// Best-effort per artifact: one file refusing to go must not keep the
    /// others alive, and the call itself never fails — failing a sign-out over
    /// cleanup would be the worse trade.
    fun clearPersistedState(result: Result) {
        executor.execute {
            runCatching { runtimeConfigStore.deletePersistedConfigs() }
            runCatching { File(context.filesDir, "stderr.log").delete() }
            runCatching { RuntimeStateStore.clear(context) }
            postSuccess(result, null)
        }
    }

    /// Stores the Xray config for the next tunnel start, or clears it when the
    /// caller passes null.
    ///
    /// Unlike [setConfig] a missing payload is not an error — it is how the app
    /// says "this node needs only sing-box".
    fun setXrayConfig(arguments: Any?, result: Result) {
        executor.execute {
            try {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any?> ?: emptyMap()
                runtimeConfigStore.writeXrayConfig(args["config"] as? String)
                postSuccess(result, null)
            } catch (error: Throwable) {
                postError(
                    result,
                    "XRAY_CONFIG_WRITE_FAILED",
                    error.message ?: "Could not write xray config",
                )
            }
        }
    }
}
