package com.kurban.xue_hua_navite_background_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Foreground service that keeps the host Android process alive while active background
 * download tasks are executing.
 *
 * Lifecycle coordination rules:
 * - Never issue `startService(ACTION_STOP)` when the service has not been requested or started.
 * - While already running in the foreground, active-count updates refresh the summary
 *   notification in place rather than issuing redundant `startForegroundService(ACTION_START)`
 *   calls.
 * - If active tasks drop to 0 after `startForegroundService(ACTION_START)` was called but before
 *   `onStartCommand` invokes `startForeground()`, mark a pending stop so `onStartCommand` still
 *   satisfies the Android foreground service contract before stopping via `stopSelf(startId)`.
 * - Stopping an active service from the plugin is serialized onto the main thread with a
 *   double-check under `stateLock` so it never races with `onStartCommand` or strips foreground
 *   state from a newly started task.
 * - All stop requests inside the service use `stopSelf(startId)` (never no-arg `stopSelf()`).
 * - Always return `START_NOT_STICKY`.
 */
open class XueHuaDownloadForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelfWithStartId(startId)
            return START_NOT_STICKY
        }

        val action = intent.action
        if (action == ACTION_STOP) {
            val shouldStop = synchronized(stateLock) {
                if (activeService === this) {
                    isForegroundRunning = false
                }
                !isRequested || stopPending
            }
            if (shouldStop) {
                stopForegroundCompat()
                stopSelfWithStartId(startId)
            }
            return START_NOT_STICKY
        }

        val channelId = intent.getStringExtra(EXTRA_CHANNEL_ID) ?: DEFAULT_CHANNEL_ID
        val channelName = intent.getStringExtra(EXTRA_CHANNEL_NAME) ?: DEFAULT_CHANNEL_NAME
        val activeCount = intent.getIntExtra(EXTRA_ACTIVE_COUNT, 1)

        ensureChannel(channelId, channelName)
        val notification = buildSummaryNotification(channelId, activeCount)

        try {
            startForegroundCompat(notification)
        } catch (_: Throwable) {
            synchronized(stateLock) {
                if (activeService === this) {
                    activeService = null
                }
                isRequested = false
                isForegroundRunning = false
                stopPending = false
            }
            stopSelfWithStartId(startId)
            return START_NOT_STICKY
        }

        val shouldStopImmediately = synchronized(stateLock) {
            lastStartId = startId
            if (stopPending || !isRequested) {
                if (activeService === this) {
                    activeService = null
                }
                isRequested = false
                isForegroundRunning = false
                stopPending = false
                true
            } else {
                activeService = this
                isForegroundRunning = true
                stopPending = false
                false
            }
        }

        if (shouldStopImmediately) {
            stopForegroundCompat()
            stopSelfWithStartId(startId)
        }

        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        synchronized(stateLock) {
            if (activeService === this) {
                activeService = null
            }
            isRequested = false
            isForegroundRunning = false
            stopPending = false
        }
        stopForegroundCompat()
        stopSelfWithStartId(startId)
    }

    override fun onDestroy() {
        synchronized(stateLock) {
            if (activeService === this) {
                activeService = null
                isForegroundRunning = false
                if (!stopPending) {
                    isRequested = false
                }
            }
        }
        super.onDestroy()
    }

    internal open fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                SUMMARY_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(SUMMARY_NOTIFICATION_ID, notification)
        }
    }

    internal open fun ensureChannel(channelId: String, channelName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val existing = manager.getNotificationChannel(channelId)
            if (existing == null) {
                val channel = NotificationChannel(
                    channelId,
                    channelName,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Background file download progress notifications"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    internal open fun buildSummaryNotification(channelId: String, activeCount: Int): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Background Downloader")
            .setContentText("$activeCount download task(s) in progress")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()
    }

    internal open fun updateSummaryNotification(
        channelId: String,
        channelName: String,
        activeCount: Int
    ) {
        try {
            ensureChannel(channelId, channelName)
            val notification = buildSummaryNotification(channelId, activeCount)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.notify(SUMMARY_NOTIFICATION_ID, notification)
        } catch (_: Throwable) {
            // Ignore notification update errors on restricted contexts.
        }
    }

    internal open fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }

    internal open fun stopSelfWithStartId(startId: Int) {
        stopSelf(startId)
    }

    internal fun stopFromPlugin(startId: Int) {
        stopForegroundCompat()
        stopSelfWithStartId(startId)
    }

    internal interface ServiceDispatcher {
        fun startService(channelId: String, channelName: String, activeCount: Int)
        fun stopService()
    }

    companion object {
        const val ACTION_START = "com.kurban.xue_hua_navite_background_downloader.START_FG"
        const val ACTION_STOP = "com.kurban.xue_hua_navite_background_downloader.STOP_FG"
        const val EXTRA_CHANNEL_ID = "channel_id"
        const val EXTRA_CHANNEL_NAME = "channel_name"
        const val EXTRA_ACTIVE_COUNT = "active_count"
        const val DEFAULT_CHANNEL_ID = "xue_hua_background_downloader"
        const val DEFAULT_CHANNEL_NAME = "Background Downloads"
        const val SUMMARY_NOTIFICATION_ID = 98400

        private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }
        internal var mainThreadPoster: (Runnable) -> Unit = { mainHandler.post(it) }

        private val stateLock = Any()
        private var isRequested: Boolean = false
        private var isForegroundRunning: Boolean = false
        private var stopPending: Boolean = false
        private var lastStartId: Int = -1
        private var activeService: XueHuaDownloadForegroundService? = null

        internal fun defaultDispatcher(context: Context): ServiceDispatcher {
            val appContext = context.applicationContext
            return object : ServiceDispatcher {
                override fun startService(channelId: String, channelName: String, activeCount: Int) {
                    val intent = Intent(appContext, XueHuaDownloadForegroundService::class.java).apply {
                        action = ACTION_START
                        putExtra(EXTRA_CHANNEL_ID, channelId)
                        putExtra(EXTRA_CHANNEL_NAME, channelName)
                        putExtra(EXTRA_ACTIVE_COUNT, activeCount)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appContext.startForegroundService(intent)
                    } else {
                        appContext.startService(intent)
                    }
                }

                override fun stopService() {
                    val intent = Intent(appContext, XueHuaDownloadForegroundService::class.java)
                    appContext.stopService(intent)
                }
            }
        }

        internal fun syncServiceState(
            shouldRun: Boolean,
            channelId: String,
            channelName: String,
            activeCount: Int,
            dispatcher: ServiceDispatcher
        ) {
            if (shouldRun && activeCount > 0) {
                val runningService = synchronized(stateLock) {
                    stopPending = false
                    isRequested = true
                    if (isForegroundRunning && activeService != null) {
                        activeService
                    } else {
                        null
                    }
                }
                if (runningService != null) {
                    // Already running in foreground: update summary notification in place without
                    // queuing redundant startForegroundService() calls and extra startIds.
                    runningService.updateSummaryNotification(channelId, channelName, activeCount)
                    return
                }
                try {
                    dispatcher.startService(channelId, channelName, activeCount)
                } catch (_: Throwable) {
                    synchronized(stateLock) {
                        if (!isForegroundRunning) {
                            isRequested = false
                            stopPending = false
                        }
                    }
                }
                return
            }

            // Active count dropped to 0 (or notifications disabled).
            var runningService: XueHuaDownloadForegroundService? = null
            var targetStartId = -1
            var fallbackStopService = false

            synchronized(stateLock) {
                if (!isRequested && !isForegroundRunning) {
                    // Service was never started or already stopped — do not touch startService/stopService.
                    return
                }
                if (isRequested && !isForegroundRunning) {
                    // startForegroundService() was called but onStartCommand() has not yet
                    // invoked startForeground(). Defer stopping until onStartCommand() satisfies
                    // the Android foreground service contract.
                    isRequested = false
                    stopPending = true
                    return
                }
                // Service is actively running in foreground. Mark stop intent under stateLock
                // and serialize the actual stop onto the main thread to avoid racing with
                // onStartCommand() or a newly started task.
                isRequested = false
                stopPending = true
                runningService = activeService
                targetStartId = lastStartId
                if (runningService == null || targetStartId < 0) {
                    activeService = null
                    isForegroundRunning = false
                    stopPending = false
                    fallbackStopService = true
                }
            }

            val svc = runningService
            if (svc != null && targetStartId >= 0) {
                mainThreadPoster(Runnable {
                    val shouldExecuteStop = synchronized(stateLock) {
                        if (!isRequested && activeService === svc && lastStartId == targetStartId) {
                            activeService = null
                            isForegroundRunning = false
                            stopPending = false
                            true
                        } else {
                            false
                        }
                    }
                    if (shouldExecuteStop) {
                        try {
                            svc.stopFromPlugin(targetStartId)
                        } catch (_: Throwable) {
                            try {
                                dispatcher.stopService()
                            } catch (_: Throwable) {
                            }
                        }
                    }
                })
            } else if (fallbackStopService) {
                try {
                    dispatcher.stopService()
                } catch (_: Throwable) {
                }
            }
        }

        internal fun resetStateForTesting() {
            synchronized(stateLock) {
                isRequested = false
                isForegroundRunning = false
                stopPending = false
                lastStartId = -1
                activeService = null
            }
            mainThreadPoster = { mainHandler.post(it) }
        }

        internal fun isStopPendingForTesting(): Boolean = synchronized(stateLock) { stopPending }

        internal fun isRequestedForTesting(): Boolean = synchronized(stateLock) { isRequested }

        internal fun isForegroundRunningForTesting(): Boolean =
            synchronized(stateLock) { isForegroundRunning }
    }
}
