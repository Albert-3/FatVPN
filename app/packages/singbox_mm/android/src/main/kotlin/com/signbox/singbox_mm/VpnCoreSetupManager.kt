package com.signbox.singbox_mm

import android.content.Context
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File

internal object VpnCoreSetupManager {
    @Volatile
    private var setupDone = false

    private val setupLock = Any()

    fun ensure(context: Context) {
        if (setupDone) {
            return
        }

        synchronized(setupLock) {
            if (setupDone) {
                return
            }

            val basePath = context.filesDir.path
            // Internal storage, not getExternalFilesDir: the working directory
            // holds sing-box's stderr — node addresses, SNI, DNS queries, the
            // whole shape of the infrastructure — and on /sdcard that is
            // readable over MTP/adb without root, by any app holding
            // READ_EXTERNAL_STORAGE on API ≤ 28, and by anything restoring a
            // device backup.
            val workingPath = context.filesDir.path
            val tempPath = context.cacheDir.path

            val setupOptions = SetupOptions().apply {
                this.basePath = basePath
                this.workingPath = workingPath
                this.tempPath = tempPath
                this.fixAndroidStack = false
            }
            Libbox.setup(setupOptions)
            runCatching {
                Libbox.redirectStderr(File(workingPath, "stderr.log").path)
            }

            setupDone = true
        }
    }
}
