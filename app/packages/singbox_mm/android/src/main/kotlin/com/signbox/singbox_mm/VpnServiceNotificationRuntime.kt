package com.signbox.singbox_mm

import android.app.Notification
import android.app.Service
import android.content.Context

internal class VpnServiceNotificationRuntime(
    private val context: Context,
    private val channelId: String,
    private val channelName: String,
    private val notificationId: Int,
    private val defaultProfileLabel: String,
    private val appPackageName: String,
    private val serviceClass: Class<out Service>,
    private val openAppRequestCode: Int,
    private val stopRequestCode: Int,
    private val restartRequestCode: Int,
    private val stopAction: String,
    private val restartAction: String,
    private val configPathExtraKey: String,
    private val resolveSmallIcon: () -> Int,
    private val readProfileLabel: () -> String?,
    private val readConfigPath: () -> String?,
    private val readConnectedSinceMillis: () -> Long?,
    private val captureTrafficSnapshot: () -> NotificationTrafficSnapshot?,
    private val readConnectedDetail: () -> String?,
) {
    fun ensureChannel() {
        VpnNotificationRuntimeCoordinator.ensureChannel(
            context = context,
            channelId = channelId,
            channelName = channelName,
        )
    }

    fun buildNotification(status: String, detail: String? = null): Notification {
        return VpnForegroundNotificationFactory.build(
            context = context,
            channelId = channelId,
            status = status,
            detail = detail,
            profileLabel = readProfileLabel(),
            defaultProfileLabel = defaultProfileLabel,
            currentConfigPath = readConfigPath(),
            connectedSinceMillis = readConnectedSinceMillis(),
            appPackageName = appPackageName,
            serviceClass = serviceClass,
            openAppRequestCode = openAppRequestCode,
            stopRequestCode = stopRequestCode,
            restartRequestCode = restartRequestCode,
            stopAction = stopAction,
            restartAction = restartAction,
            configPathExtraKey = configPathExtraKey,
            smallIcon = resolveSmallIcon(),
            captureTrafficSnapshot = captureTrafficSnapshot,
        )
    }

    fun notify(status: String, detail: String? = null) {
        val notification = buildNotification(status = status, detail = detail)
        lastRenderedText = renderedTextOf(notification)
        VpnNotificationRuntimeCoordinator.notify(
            context = context,
            notificationId = notificationId,
            notification = notification,
        )
    }

    /// What the shade last showed, so the live ticker can skip a post that would
    /// change nothing. An idle tunnel renders the same speeds every tick, and
    /// the cost of posting is the IPC and the redraw, not the build.
    private var lastRenderedText: String? = null

    fun notifyIfChanged(status: String, detail: String? = null) {
        val notification = buildNotification(status = status, detail = detail)
        val rendered = renderedTextOf(notification)
        if (rendered == lastRenderedText) {
            return
        }
        lastRenderedText = rendered
        VpnNotificationRuntimeCoordinator.notify(
            context = context,
            notificationId = notificationId,
            notification = notification,
        )
    }

    private fun renderedTextOf(notification: Notification): String {
        val extras = notification.extras ?: return ""
        return buildString {
            append(extras.getCharSequence(Notification.EXTRA_TITLE) ?: "")
            append('\u0000')
            append(extras.getCharSequence(Notification.EXTRA_TEXT) ?: "")
            append('\u0000')
            append(extras.getCharSequence(Notification.EXTRA_SUB_TEXT) ?: "")
        }
    }

    fun notifyForState(state: String, error: String?) {
        val (status, detail) = VpnNotificationRuntimeCoordinator.statusForState(
            state = state,
            error = error,
            connectedDetail = readConnectedDetail(),
        )
        notify(status = status, detail = detail)
    }
}
