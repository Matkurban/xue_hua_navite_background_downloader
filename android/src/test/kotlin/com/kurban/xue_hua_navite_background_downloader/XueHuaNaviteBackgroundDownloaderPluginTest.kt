package com.kurban.xue_hua_navite_background_downloader

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class XueHuaNaviteBackgroundDownloaderPluginTest {

    private lateinit var tempDir: File

    @BeforeTest
    fun setUp() {
        XueHuaDownloadForegroundService.resetStateForTesting()
        XueHuaDownloadForegroundService.mainThreadPoster = { it.run() }
        tempDir = createTempDirectory("xue_hua_downloader_test_").toFile()
    }

    @AfterTest
    fun tearDown() {
        XueHuaDownloadForegroundService.resetStateForTesting()
        tempDir.deleteRecursively()
    }

    @Test
    fun onMethodCall_unknownMethod_returnsNotImplemented() {
        val plugin = XueHuaNaviteBackgroundDownloaderPlugin()
        val call = MethodCall("unknownMethod", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)
        Mockito.verify(mockResult).notImplemented()
    }

    @Test
    fun configureThenEnqueue_neverStopsWhenServiceNotStarted_andStartsOnEnqueue() {
        val plugin = XueHuaNaviteBackgroundDownloaderPlugin()
        val mockContext = Mockito.mock(Context::class.java)
        Mockito.`when`(mockContext.filesDir).thenReturn(tempDir)
        plugin.applicationContext = mockContext
        plugin.sdkIntProvider = { 24 }
        plugin.mainThreadPoster = { it.run() }

        val recordedEvents = mutableListOf<String>()
        plugin.foregroundServiceDispatcher = object : XueHuaDownloadForegroundService.ServiceDispatcher {
            override fun startService(channelId: String, channelName: String, activeCount: Int) {
                recordedEvents.add("start:$activeCount")
            }

            override fun stopService() {
                recordedEvents.add("stop")
            }
        }

        // configure() with activeCount == 0 must NOT dispatch start or stop.
        val configResult = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(
            MethodCall("configure", mapOf("enableNotifications" to true, "maxConcurrentTasks" to 2)),
            configResult
        )
        Mockito.verify(configResult).success(null)
        assertTrue(recordedEvents.isEmpty(), "Expected no FGS calls on configure() when idle, got $recordedEvents")

        // cancel() on unknown task with activeCount == 0 must NOT dispatch stop.
        val cancelResult = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(
            MethodCall("cancel", mapOf("taskId" to "non_existent")),
            cancelResult
        )
        assertTrue(recordedEvents.isEmpty(), "Expected no FGS calls on cancel() when idle, got $recordedEvents")

        // enqueue() immediately after configure() must start FGS without any prior ACTION_STOP.
        val enqueueResult = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(
            MethodCall(
                "enqueue",
                mapOf(
                    "taskId" to "task_1",
                    "url" to "https://example.invalid/test.bin",
                    "saveDirectory" to tempDir.absolutePath,
                    "fileName" to "test.bin",
                    "maxRetries" to 0
                )
            ),
            enqueueResult
        )
        assertTrue(
            recordedEvents.isNotEmpty() && recordedEvents.first().startsWith("start:"),
            "Expected first FGS event to be start:, got $recordedEvents"
        )
        assertFalse(
            recordedEvents.contains("stop"),
            "Expected no stopService() before onStartCommand fulfills startForeground(), got $recordedEvents"
        )
    }

    @Test
    fun enqueueThenInstantFinishBeforeOnStartCommand_callsStartForegroundThenStopSelfWithStartId() {
        val dispatcher = RecordingDispatcher()

        // 1. Worker starts -> request FGS start
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )
        assertEquals(listOf("start:1"), dispatcher.events)
        assertTrue(XueHuaDownloadForegroundService.isRequestedForTesting())
        assertFalse(XueHuaDownloadForegroundService.isForegroundRunningForTesting())

        // 2. Worker fails/completes/cancels immediately BEFORE onStartCommand runs
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = false,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 0,
            dispatcher = dispatcher
        )
        // Must NOT call stopService() prematurely; instead mark stopPending = true
        assertEquals(listOf("start:1"), dispatcher.events)
        assertTrue(XueHuaDownloadForegroundService.isStopPendingForTesting())

        // 3. System delivers onStartCommand for ACTION_START
        val service = TestableForegroundService()
        val intent = mockStartIntent()
        val returnMode = service.onStartCommand(intent, 0, 42)

        assertEquals(Service.START_NOT_STICKY, returnMode)
        assertEquals(
            listOf("startForeground", "stopForeground", "stopSelf(42)"),
            service.lifecycleCalls
        )
        assertFalse(XueHuaDownloadForegroundService.isRequestedForTesting())
        assertFalse(XueHuaDownloadForegroundService.isForegroundRunningForTesting())
        assertFalse(XueHuaDownloadForegroundService.isStopPendingForTesting())
    }

    @Test
    fun activeForegroundService_stoppedViaInProcessStopSelfWithStartId() {
        val dispatcher = RecordingDispatcher()
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )

        val service = TestableForegroundService()
        val returnMode = service.onStartCommand(mockStartIntent(), 0, 17)
        assertEquals(Service.START_NOT_STICKY, returnMode)
        assertEquals(listOf("startForeground"), service.lifecycleCalls)
        assertTrue(XueHuaDownloadForegroundService.isForegroundRunningForTesting())

        // Active count drops to 0 while running in foreground -> stops via in-process stopSelf(17)
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = false,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 0,
            dispatcher = dispatcher
        )
        assertEquals(
            listOf("startForeground", "stopForeground", "stopSelf(17)"),
            service.lifecycleCalls
        )
        assertEquals(listOf("start:1"), dispatcher.events)
    }

    @Test
    fun onStartCommand_nullIntent_stopsSelfWithStartIdWithoutStartForeground() {
        val service = TestableForegroundService()
        val returnMode = service.onStartCommand(null, 0, 7)

        assertEquals(Service.START_NOT_STICKY, returnMode)
        assertEquals(listOf("stopSelf(7)"), service.lifecycleCalls)
    }

    @Test
    fun onStartCommand_startForegroundThrows_stopsSelfWithStartIdAndResetsState() {
        val dispatcher = RecordingDispatcher()
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )

        val service = TestableForegroundService(throwOnStartForeground = true)
        val returnMode = service.onStartCommand(mockStartIntent(), 0, 9)

        assertEquals(Service.START_NOT_STICKY, returnMode)
        assertEquals(listOf("startForeground:throws", "stopSelf(9)"), service.lifecycleCalls)
        assertFalse(XueHuaDownloadForegroundService.isRequestedForTesting())
        assertFalse(XueHuaDownloadForegroundService.isForegroundRunningForTesting())
    }

    @Test
    fun onTimeout_stopsForegroundAndCallsStopSelfWithStartId() {
        val service = TestableForegroundService()
        service.onTimeout(15, 1)

        assertEquals(listOf("stopForeground", "stopSelf(15)"), service.lifecycleCalls)
    }

    @Test
    fun requestNotificationPermission_concurrentCalls_singlePromptAndSingleReplyPerResult() {
        val plugin = XueHuaNaviteBackgroundDownloaderPlugin()
        val mockContext = Mockito.mock(Context::class.java)
        Mockito.`when`(mockContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        plugin.applicationContext = mockContext
        plugin.sdkIntProvider = { 33 }

        val mockActivity = Mockito.mock(Activity::class.java)
        val mockBinding = Mockito.mock(ActivityPluginBinding::class.java)
        Mockito.`when`(mockBinding.activity).thenReturn(mockActivity)
        plugin.onAttachedToActivity(mockBinding)

        val result1 = Mockito.mock(MethodChannel.Result::class.java)
        val result2 = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(MethodCall("requestNotificationPermission", null), result1)
        plugin.onMethodCall(MethodCall("requestNotificationPermission", null), result2)

        // System permission prompt should only be triggered once for concurrent calls.
        Mockito.verify(mockActivity, Mockito.times(1)).requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            48102
        )

        // Deliver permission grant result.
        val handled = plugin.onRequestPermissionsResult(
            48102,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            intArrayOf(PackageManager.PERMISSION_GRANTED)
        )
        assertTrue(handled)
        Mockito.verify(result1, Mockito.times(1)).success(true)
        Mockito.verify(result2, Mockito.times(1)).success(true)

        // A duplicate callback must not re-invoke either Result.
        plugin.onRequestPermissionsResult(
            48102,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            intArrayOf(PackageManager.PERMISSION_DENIED)
        )
        Mockito.verifyNoMoreInteractions(result1, result2)
    }

    @Test
    fun requestNotificationPermission_onDetachedFromActivity_completesPendingWithFalseOnce() {
        val plugin = XueHuaNaviteBackgroundDownloaderPlugin()
        val mockContext = Mockito.mock(Context::class.java)
        Mockito.`when`(mockContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
            .thenReturn(PackageManager.PERMISSION_DENIED)
        plugin.applicationContext = mockContext
        plugin.sdkIntProvider = { 33 }

        val mockActivity = Mockito.mock(Activity::class.java)
        val mockBinding = Mockito.mock(ActivityPluginBinding::class.java)
        Mockito.`when`(mockBinding.activity).thenReturn(mockActivity)
        plugin.onAttachedToActivity(mockBinding)

        val result1 = Mockito.mock(MethodChannel.Result::class.java)
        val result2 = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(MethodCall("requestNotificationPermission", null), result1)
        plugin.onMethodCall(MethodCall("requestNotificationPermission", null), result2)

        // Detach activity before user responds to the system dialog.
        plugin.onDetachedFromActivity()

        Mockito.verify(result1, Mockito.times(1)).success(false)
        Mockito.verify(result2, Mockito.times(1)).success(false)

        // Late permission callback after detach must not double-reply.
        plugin.onRequestPermissionsResult(
            48102,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            intArrayOf(PackageManager.PERMISSION_GRANTED)
        )
        Mockito.verifyNoMoreInteractions(result1, result2)
    }

    @Test
    fun runningService_secondQueuedStartThenAllTasksFinish_onStartCommandStopsImmediately() {
        val dispatcher = RecordingDispatcher()
        // 1. Task 1 enters foreground with startId = 1.
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )
        val service = TestableForegroundService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(mockStartIntent(), 0, 1))
        assertTrue(XueHuaDownloadForegroundService.isForegroundRunningForTesting())

        // 2. Simulate an already-queued startId = 2 in AMS while all active tasks finish -> 0.
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = false,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 0,
            dispatcher = dispatcher
        )
        // startId = 1 stop executed; AMS still delivers the queued startId = 2.
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(mockStartIntent(), 0, 2))

        assertEquals(
            listOf(
                "startForeground",
                "stopForeground",
                "stopSelf(1)",
                "startForeground",
                "stopForeground",
                "stopSelf(2)"
            ),
            service.lifecycleCalls
        )
        assertFalse(XueHuaDownloadForegroundService.isRequestedForTesting())
        assertFalse(XueHuaDownloadForegroundService.isForegroundRunningForTesting())
        assertFalse(XueHuaDownloadForegroundService.isStopPendingForTesting())
    }

    @Test
    fun stopAndRestartInterleaving_staleMainThreadStopCallbackDoesNotStripForegroundState() {
        val postedMainRunnables = mutableListOf<Runnable>()
        XueHuaDownloadForegroundService.mainThreadPoster = { postedMainRunnables.add(it) }

        val dispatcher = RecordingDispatcher()
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )
        val service = TestableForegroundService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(mockStartIntent(), 0, 10))
        assertTrue(XueHuaDownloadForegroundService.isForegroundRunningForTesting())

        // Active count drops to 0 -> stop runnable is queued on main thread, not yet executed.
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = false,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 0,
            dispatcher = dispatcher
        )
        assertEquals(1, postedMainRunnables.size)

        // Before the queued stop runs, a new task starts.
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )

        // Now execute the stale main-thread stop callback -> must be a no-op.
        postedMainRunnables.forEach { it.run() }

        assertEquals(listOf("startForeground", "updateNotification(1)"), service.lifecycleCalls)
        assertTrue(XueHuaDownloadForegroundService.isRequestedForTesting())
        assertTrue(XueHuaDownloadForegroundService.isForegroundRunningForTesting())
        assertFalse(XueHuaDownloadForegroundService.isStopPendingForTesting())
    }

    @Test
    fun runningService_newTaskEnqueued_updatesSummaryNotificationWithoutRestartingService() {
        val dispatcher = RecordingDispatcher()
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 1,
            dispatcher = dispatcher
        )
        val service = TestableForegroundService()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(mockStartIntent(), 0, 1))
        assertEquals(listOf("start:1"), dispatcher.events)

        // Second task becomes active while already running in foreground.
        XueHuaDownloadForegroundService.syncServiceState(
            shouldRun = true,
            channelId = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID,
            channelName = XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME,
            activeCount = 2,
            dispatcher = dispatcher
        )

        assertEquals(listOf("start:1"), dispatcher.events)
        assertEquals(listOf("startForeground", "updateNotification(2)"), service.lifecycleCalls)
    }

    @Test
    fun pausePreemptedByCancelDuringAwaitExit_doesNotOverwriteCanceledState_andControlErrorCompletesResult() {
        val plugin = XueHuaNaviteBackgroundDownloaderPlugin()
        val mockContext = Mockito.mock(Context::class.java)
        Mockito.`when`(mockContext.filesDir).thenReturn(tempDir)
        plugin.applicationContext = mockContext
        plugin.sdkIntProvider = { 24 }
        plugin.mainThreadPoster = { it.run() }
        plugin.foregroundServiceDispatcher = RecordingDispatcher()

        val emittedStatuses = CopyOnWriteArrayList<String>()
        plugin.onListen(null, object : EventChannel.EventSink {
            override fun success(event: Any?) {
                val map = event as? Map<*, *>
                val status = map?.get("status") as? String
                if (status != null) emittedStatuses.add(status)
            }
            override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {}
            override fun endOfStream() {}
        })

        val savePath = File(tempDir, "race.bin").absolutePath
        val partFile = File("$savePath.part")
        partFile.writeBytes(ByteArray(128))

        val pauseEnteredAwait = CountDownLatch(1)
        val releaseWorker = plugin.registerRunningTaskForTesting("task_race", savePath) {
            pauseEnteredAwait.countDown()
        }

        val pauseCompleted = CountDownLatch(1)
        var pauseReturnedStatus: String? = null
        val pauseResult = object : MethodChannel.Result {
            override fun success(result: Any?) {
                val map = result as? Map<*, *>
                pauseReturnedStatus = map?.get("status") as? String
                pauseCompleted.countDown()
            }
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                pauseCompleted.countDown()
            }
            override fun notImplemented() {
                pauseCompleted.countDown()
            }
        }

        plugin.onMethodCall(MethodCall("pause", mapOf("taskId" to "task_race")), pauseResult)
        assertTrue(pauseEnteredAwait.await(3, TimeUnit.SECONDS), "pauseInternal should invoke control.pause()")

        // Preempt with cancel while pauseInternal is waiting for worker exit.
        val cancelResult = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(
            MethodCall("cancel", mapOf("taskId" to "task_race", "deletePartialFile" to true)),
            cancelResult
        )

        // Allow worker exit so pauseInternal finishes.
        releaseWorker()
        assertTrue(pauseCompleted.await(3, TimeUnit.SECONDS), "pause Result must complete")

        // Task must remain canceled and not be overwritten back to paused.
        assertEquals("canceled", pauseReturnedStatus)
        assertEquals(listOf("canceled"), emittedStatuses.toList())

        // Verify controlExecutor exception path always completes Result with error.
        val errorLatch = CountDownLatch(1)
        var capturedErrorCode: String? = null
        var capturedErrorMessage: String? = null
        val errorResult = object : MethodChannel.Result {
            override fun success(result: Any?) { errorLatch.countDown() }
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                capturedErrorCode = errorCode
                capturedErrorMessage = errorMessage
                errorLatch.countDown()
            }
            override fun notImplemented() { errorLatch.countDown() }
        }
        plugin.executeControlAsync(errorResult) {
            throw IllegalStateException("simulated_control_failure")
        }
        assertTrue(errorLatch.await(3, TimeUnit.SECONDS), "control error Result must not hang")
        assertEquals("control_error", capturedErrorCode)
        assertEquals("simulated_control_failure", capturedErrorMessage)
    }

    private fun mockStartIntent(): Intent {
        val intent = Mockito.mock(Intent::class.java)
        Mockito.`when`(intent.action).thenReturn(XueHuaDownloadForegroundService.ACTION_START)
        Mockito.`when`(intent.getStringExtra(XueHuaDownloadForegroundService.EXTRA_CHANNEL_ID))
            .thenReturn(XueHuaDownloadForegroundService.DEFAULT_CHANNEL_ID)
        Mockito.`when`(intent.getStringExtra(XueHuaDownloadForegroundService.EXTRA_CHANNEL_NAME))
            .thenReturn(XueHuaDownloadForegroundService.DEFAULT_CHANNEL_NAME)
        Mockito.`when`(intent.getIntExtra(XueHuaDownloadForegroundService.EXTRA_ACTIVE_COUNT, 1))
            .thenReturn(1)
        return intent
    }

    private class RecordingDispatcher : XueHuaDownloadForegroundService.ServiceDispatcher {
        val events = mutableListOf<String>()

        override fun startService(channelId: String, channelName: String, activeCount: Int) {
            events.add("start:$activeCount")
        }

        override fun stopService() {
            events.add("stop")
        }
    }

    private class TestableForegroundService(
        private val throwOnStartForeground: Boolean = false
    ) : XueHuaDownloadForegroundService() {
        val lifecycleCalls = mutableListOf<String>()

        override fun ensureChannel(channelId: String, channelName: String) {
            // No-op in JVM unit test.
        }

        override fun buildSummaryNotification(channelId: String, activeCount: Int): Notification {
            return Mockito.mock(Notification::class.java)
        }

        override fun startForegroundCompat(notification: Notification) {
            if (throwOnStartForeground) {
                lifecycleCalls.add("startForeground:throws")
                throw SecurityException("Simulated foreground service start restriction")
            }
            lifecycleCalls.add("startForeground")
        }

        override fun updateSummaryNotification(
            channelId: String,
            channelName: String,
            activeCount: Int
        ) {
            lifecycleCalls.add("updateNotification($activeCount)")
        }

        override fun stopForegroundCompat() {
            lifecycleCalls.add("stopForeground")
        }

        override fun stopSelfWithStartId(startId: Int) {
            lifecycleCalls.add("stopSelf($startId)")
        }
    }
}
