package com.signbox.singbox_mm

import android.content.Context
import android.util.Log
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.PlatformInterface
import java.io.File

internal class VpnCoreServiceCoordinator(
    private val context: Context,
    private val platformInterface: PlatformInterface,
    private val commandHandler: CommandServerHandler,
    private val runtimeSession: VpnCoreRuntimeSession,
    private val runtimeStateBridge: VpnServiceRuntimeStateBridge,
    private val notificationRuntime: VpnServiceNotificationRuntime,
    private val trafficMonitor: NotificationTrafficMonitor,
    private val liveNotificationTicker: VpnLiveNotificationTicker,
    private val healthWatchdog: VpnTunnelHealthWatchdog,
    private val readPrivateDnsHost: () -> String?,
    private val protectSocket: (Int) -> Boolean,
    private val logTag: String,
    private val defaultProfileLabel: String,
    private val commandPort: Int,
    private val statePreparing: String,
    private val stateConnecting: String,
    private val stateConnected: String,
    private val stateDisconnected: String,
    private val stateError: String,
) {
    private companion object {
        const val RESTART_CLOSE_SUPPRESSION_MS: Long = 15_000L
    }

    fun start(configPath: String?) {
        when (
            val result = VpnCoreStartFlow.execute(
                request = VpnCoreStartRequest(
                    context = context,
                    configPath = configPath,
                    privateDnsHost = readPrivateDnsHost(),
                    defaultProfileLabel = defaultProfileLabel,
                    logTag = logTag,
                    commandPort = commandPort,
                    platformInterface = platformInterface,
                    commandHandler = commandHandler,
                    beforeRuntimeStart = {
                        // Avoid multiple core instances when start is triggered repeatedly.
                        stop(emitDisconnected = false)
                    },
                    onPreparing = { profileLabel ->
                        runtimeSession.bindPreparedProfile(profileLabel)
                        runtimeStateBridge.publish(statePreparing, null)
                    },
                    startAuxiliaryCore = {
                        VpnXrayEngine.applyConfig(
                            configFile = resolveXrayConfigFile(configPath),
                            protectSocket = protectSocket,
                            logTag = logTag,
                        )
                    },
                    onConnecting = {
                        runtimeStateBridge.publish(stateConnecting, null)
                    },
                ),
            )
        ) {
            is VpnCoreStartResult.Failure -> {
                result.cause?.let { Log.e(logTag, "libbox startup failed", it) }
                if (result.shouldCleanup) {
                    stop(emitDisconnected = false)
                }
                runtimeStateBridge.publish(stateError, result.errorMessage)
            }

            is VpnCoreStartResult.Success -> {
                runtimeSession.bindStartOutcome(result.startOutcome)
                runtimeStateBridge.persistSnapshot()
                VpnTrafficSessionCoordinator.initialize(
                    monitor = trafficMonitor,
                    lastPublishedState = runtimeStateBridge.state,
                    lastPublishedError = runtimeStateBridge.error,
                    persistSnapshot = { _, _ ->
                        runtimeStateBridge.persistSnapshot()
                    },
                )
                liveNotificationTicker.start()
                // Only now is there a tunnel worth watching — and it is watched
                // from in here rather than from Dart because this service
                // outlives the Flutter engine (see [VpnTunnelHealthWatchdog]).
                healthWatchdog.start()
                notificationRuntime.notify(
                    status = VpnNotificationStatus.CONNECTED,
                    detail = runtimeSession.coreNotificationDetail,
                )
                runtimeStateBridge.publish(stateConnected, null)
            }
        }
    }

    /// The Xray config the app left next to the sing-box one it is handing us.
    ///
    /// Derived from the config path rather than carried as its own extra so
    /// that the restarts this service schedules for itself — the health
    /// watchdog's, above all — find it without anyone re-sending it.
    private fun resolveXrayConfigFile(configPath: String?): File {
        val directory = configPath?.let { File(it).parentFile }
            ?: File(context.filesDir, "singbox")
        return File(directory, PluginRuntimeConfigStore.XRAY_CONFIG_FILE_NAME)
    }

    fun stop(
        emitDisconnected: Boolean,
        disconnectError: String? = null,
    ) {
        liveNotificationTicker.stop()
        healthWatchdog.stop()
        if (!emitDisconnected) {
            // Internal restart/reload closes the old service and may trigger
            // postServiceClose callbacks. Suppress those so we don't stopSelf
            // while a replacement core is starting.
            runtimeSession.suppressPostServiceCloseFor(RESTART_CLOSE_SUPPRESSION_MS)
        }

        VpnCoreStopFlow.execute(
            request = VpnCoreStopRequest(
                commandServer = runtimeSession.commandServer,
                tunFileDescriptor = runtimeSession.tunFileDescriptor,
                trafficMonitor = trafficMonitor,
                lastPublishedState = runtimeStateBridge.state,
                lastPublishedError = runtimeStateBridge.error,
                persistSnapshot = { _, _ ->
                    runtimeStateBridge.persistSnapshot()
                },
            ),
        )
        runtimeSession.clearRuntimeHandles()
        // After sing-box, mirroring the start order: while sing-box is winding
        // down it can still push traffic at the SOCKS port.
        VpnXrayEngine.stop(logTag)

        if (emitDisconnected) {
            runtimeSession.clearProfileAndConfig()
            runtimeStateBridge.publish(stateDisconnected, disconnectError)
        }
    }
}
