package com.kurban.xue_hua_navite_background_downloader

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Native multi-task background downloader implementation for Android.
 *
 * Features:
 * - Priority-ordered multi-task queue with configurable `maxConcurrentTasks`
 * - Local JSON persistence across app restarts (`xue_hua_downloader_tasks.json`)
 * - HTTP `Range` (`206 Partial Content`) pause/resume using `.part` files and `ETag` validation
 * - MD5 and SHA-256 post-download file integrity verification
 * - Built-in system notifications and Foreground Service keep-alive
 * - Unmetered network (Wi-Fi / Ethernet) verification
 */
class XueHuaNaviteBackgroundDownloaderPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var applicationContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: Result? = null

    // Global downloader configuration
    @Volatile
    private var maxConcurrentTasks: Int = 3
    @Volatile
    private var connectTimeoutMs: Int = 15000
    @Volatile
    private var readTimeoutMs: Int = 30000
    @Volatile
    private var progressUpdateIntervalMs: Long = 250L
    @Volatile
    private var enableNotifications: Boolean = true
    @Volatile
    private var notificationChannelId: String = "xue_hua_background_downloader"
    @Volatile
    private var notificationChannelName: String = "Background Downloads"
    @Volatile
    private var userAgent: String = "XueHuaNativeBackgroundDownloader/1.0.0"
    @Volatile
    private var defaultHeaders: Map<String, String> = emptyMap()
    @Volatile
    private var autoResumeOnStartup: Boolean = false

    private val tasks = ConcurrentHashMap<String, TaskRecord>()
    private val activeWorkers = ConcurrentHashMap<String, WorkerControl>()
    private val workerPool = Executors.newCachedThreadPool()
    private val queueLock = Any()
    private val persistenceLock = Any()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        methodChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "com.kurban.xue_hua_navite_background_downloader/methods"
        )
        eventChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            "com.kurban.xue_hua_navite_background_downloader/events"
        )
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        ensureNotificationChannel()
        loadPersistedTasks()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == REQUEST_CODE_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
            return true
        }
        return false
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "configure" -> {
                val args = call.arguments as? Map<*, *>
                if (args != null) {
                    maxConcurrentTasks = ((args["maxConcurrentTasks"] as? Number)?.toInt() ?: 3).coerceIn(1, 16)
                    connectTimeoutMs = ((args["connectTimeoutMs"] as? Number)?.toInt() ?: 15000).coerceAtLeast(1000)
                    readTimeoutMs = ((args["readTimeoutMs"] as? Number)?.toInt() ?: 30000).coerceAtLeast(1000)
                    progressUpdateIntervalMs = ((args["progressUpdateIntervalMs"] as? Number)?.toLong() ?: 250L).coerceAtLeast(50L)
                    enableNotifications = args["enableNotifications"] as? Boolean ?: true
                    notificationChannelId = args["notificationChannelId"] as? String ?: "xue_hua_background_downloader"
                    notificationChannelName = args["notificationChannelName"] as? String ?: "Background Downloads"
                    userAgent = args["userAgent"] as? String ?: "XueHuaNativeBackgroundDownloader/1.0.0"
                    autoResumeOnStartup = args["autoResumeOnStartup"] as? Boolean ?: false

                    val rawHeaders = args["defaultHeaders"] as? Map<*, *>
                    defaultHeaders = rawHeaders?.entries?.associate {
                        it.key.toString() to (it.value?.toString() ?: "")
                    } ?: emptyMap()
                }
                ensureNotificationChannel()
                scheduleQueue()
                result.success(null)
            }

            "getCapabilities" -> {
                val defaultDir = getDefaultDownloadDirectory().absolutePath
                result.success(
                    mapOf(
                        "platform" to "android",
                        "nativeEngine" to "HttpURLConnection + ForegroundService",
                        "supportsBackgroundExecution" to true,
                        "supportsPauseResume" to true,
                        "supportsSystemNotifications" to true,
                        "supportsPersistence" to true,
                        "supportsChecksumVerification" to true,
                        "supportsNetworkConstraints" to true,
                        "defaultDownloadDirectory" to defaultDir
                    )
                )
            }

            "requestNotificationPermission" -> {
                handleRequestNotificationPermission(result)
            }

            "enqueue" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error("invalid_arguments", "Expected request map", null)
                    return
                }
                val record = createOrResetTaskFromRequest(args)
                scheduleQueue()
                result.success(record.toMap())
            }

            "enqueueAll" -> {
                val args = call.arguments as? Map<*, *>
                val list = args?.get("requests") as? List<*> ?: emptyList<Any>()
                val created = mutableListOf<Map<String, Any?>>()
                for (item in list) {
                    val reqMap = item as? Map<*, *> ?: continue
                    val record = createOrResetTaskFromRequest(reqMap)
                    created.add(record.toMap())
                }
                scheduleQueue()
                result.success(created)
            }

            "pause" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                val updated = pauseInternal(taskId)
                scheduleQueue()
                result.success(updated?.toMap())
            }

            "resume" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                val updated = resumeInternal(taskId)
                scheduleQueue()
                result.success(updated?.toMap())
            }

            "cancel" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                val deletePartial = call.argument<Boolean>("deletePartialFile") ?: true
                val updated = cancelInternal(taskId, deletePartial)
                scheduleQueue()
                result.success(updated?.toMap())
            }

            "retry" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                val updated = retryInternal(taskId)
                scheduleQueue()
                result.success(updated?.toMap())
            }

            "removeTask" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                val deleteFile = call.argument<Boolean>("deleteFile") ?: false
                val removed = removeTaskInternal(taskId, deleteFile)
                scheduleQueue()
                result.success(removed)
            }

            "pauseAll" -> {
                val group = call.argument<String>("group")
                val affected = mutableListOf<Map<String, Any?>>()
                for (record in tasks.values) {
                    if (group != null && record.group != group) continue
                    if (record.status == "queued" || record.status == "running") {
                        pauseInternal(record.taskId)?.let { affected.add(it.toMap()) }
                    }
                }
                scheduleQueue()
                result.success(affected)
            }

            "resumeAll" -> {
                val group = call.argument<String>("group")
                val affected = mutableListOf<Map<String, Any?>>()
                for (record in tasks.values) {
                    if (group != null && record.group != group) continue
                    if (record.status == "paused") {
                        resumeInternal(record.taskId)?.let { affected.add(it.toMap()) }
                    }
                }
                scheduleQueue()
                result.success(affected)
            }

            "cancelAll" -> {
                val group = call.argument<String>("group")
                val deletePartial = call.argument<Boolean>("deletePartialFiles") ?: true
                val affected = mutableListOf<Map<String, Any?>>()
                for (record in tasks.values) {
                    if (group != null && record.group != group) continue
                    if (record.status == "queued" || record.status == "running" || record.status == "paused") {
                        cancelInternal(record.taskId, deletePartial)?.let { affected.add(it.toMap()) }
                    }
                }
                scheduleQueue()
                result.success(affected)
            }

            "clearCompleted" -> {
                val group = call.argument<String>("group")
                val deleteFiles = call.argument<Boolean>("deleteFiles") ?: false
                var count = 0
                val iterator = tasks.entries.iterator()
                while (iterator.hasNext()) {
                    val entry = iterator.next()
                    val record = entry.value
                    if (group != null && record.group != group) continue
                    if (record.status == "completed") {
                        if (deleteFiles) {
                            runCatching { File(record.savePath).delete() }
                        }
                        cancelTaskNotification(record.taskId)
                        iterator.remove()
                        count++
                    }
                }
                if (count > 0) {
                    persistTasks()
                }
                result.success(count)
            }

            "getTask" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                result.success(tasks[taskId]?.toMap())
            }

            "getAllTasks" -> {
                val group = call.argument<String>("group")
                val list = tasks.values
                    .filter { group == null || it.group == group }
                    .sortedByDescending { it.createdAtMs }
                    .map { it.toMap() }
                result.success(list)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleRequestNotificationPermission(result: Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = applicationContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.success(false)
            return
        }
        pendingPermissionResult = result
        currentActivity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE_NOTIFICATIONS
        )
    }

    private fun createOrResetTaskFromRequest(args: Map<*, *>): TaskRecord {
        val url = (args["url"] as? String ?: "").trim()
        val rawTaskId = (args["taskId"] as? String)?.trim()
        val taskId = if (!rawTaskId.isNullOrEmpty()) rawTaskId else UUID.randomUUID().toString()

        val rawSaveDir = (args["saveDirectory"] as? String)?.trim()
        val saveDirFile = if (!rawSaveDir.isNullOrEmpty()) {
            File(rawSaveDir)
        } else {
            getDefaultDownloadDirectory()
        }
        if (!saveDirFile.exists()) {
            saveDirFile.mkdirs()
        }

        val rawFileName = (args["fileName"] as? String)?.trim()
        val resolvedFileName = if (!rawFileName.isNullOrEmpty()) {
            sanitizeFileName(rawFileName)
        } else {
            inferFileNameFromUrl(url)
        }

        val conflictResolution = args["conflictResolution"] as? String ?: "overwrite"
        val finalFile = resolveDestinationFile(saveDirFile, resolvedFileName, conflictResolution)

        val mergedHeaders = mutableMapOf<String, String>()
        mergedHeaders.putAll(defaultHeaders)
        (args["headers"] as? Map<*, *>)?.forEach { (k, v) ->
            if (k != null && v != null) {
                mergedHeaders[k.toString()] = v.toString()
            }
        }

        val metadata = mutableMapOf<String, String>()
        (args["metadata"] as? Map<*, *>)?.forEach { (k, v) ->
            if (k != null && v != null) {
                metadata[k.toString()] = v.toString()
            }
        }

        val notifMap = args["notificationConfig"] as? Map<*, *>
        val notifConfig = NotificationConfigRecord(
            enabled = notifMap?.get("enabled") as? Boolean ?: true,
            title = notifMap?.get("title") as? String,
            runningBody = notifMap?.get("runningBody") as? String,
            completedBody = notifMap?.get("completedBody") as? String,
            failedBody = notifMap?.get("failedBody") as? String,
            showProgress = notifMap?.get("showProgress") as? Boolean ?: true
        )

        val now = System.currentTimeMillis()
        activeWorkers.remove(taskId)?.cancel()

        val record = TaskRecord(
            taskId = taskId,
            url = url,
            saveDirectory = saveDirFile.absolutePath,
            fileName = finalFile.name,
            savePath = finalFile.absolutePath,
            status = "queued",
            group = args["group"] as? String ?: "default",
            priority = args["priority"] as? String ?: "normal",
            conflictResolution = conflictResolution,
            method = args["method"] as? String ?: "GET",
            postBody = args["postBody"] as? String,
            downloadedBytes = 0L,
            totalBytes = -1L,
            progress = 0.0,
            bytesPerSecond = 0.0,
            estimatedRemainingMs = -1L,
            retryCount = 0,
            maxRetries = ((args["maxRetries"] as? Number)?.toInt() ?: 2).coerceAtLeast(0),
            supportsResume = args["allowPause"] as? Boolean ?: true,
            allowPause = args["allowPause"] as? Boolean ?: true,
            requiresUnmeteredNetwork = args["requiresUnmeteredNetwork"] as? Boolean ?: false,
            expectedChecksum = (args["expectedChecksum"] as? String)?.trim()?.takeIf { it.isNotEmpty() },
            checksumAlgorithm = args["checksumAlgorithm"] as? String ?: "sha256",
            computedChecksum = null,
            mimeType = null,
            eTag = null,
            error = null,
            createdAtMs = now,
            updatedAtMs = now,
            completedAtMs = null,
            headers = mergedHeaders,
            metadata = metadata,
            notificationConfig = notifConfig
        )

        tasks[taskId] = record
        persistTasks()
        emitTaskUpdate(record)
        return record
    }

    private fun pauseInternal(taskId: String): TaskRecord? {
        val record = tasks[taskId] ?: return null
        synchronized(record) {
            if (record.status != "running" && record.status != "queued") {
                return record
            }
            record.status = "paused"
            record.bytesPerSecond = 0.0
            record.estimatedRemainingMs = -1L
            record.updatedAtMs = System.currentTimeMillis()
        }
        activeWorkers.remove(taskId)?.pause()
        persistTasks()
        emitTaskUpdate(record)
        updateTaskNotification(record)
        return record
    }

    private fun resumeInternal(taskId: String): TaskRecord? {
        val record = tasks[taskId] ?: return null
        synchronized(record) {
            if (record.status != "paused" && record.status != "failed") {
                return record
            }
            val partFile = File("${record.savePath}.part")
            if (partFile.exists()) {
                record.downloadedBytes = partFile.length()
            } else {
                record.downloadedBytes = 0L
                record.eTag = null
            }
            record.status = "queued"
            record.error = null
            record.updatedAtMs = System.currentTimeMillis()
        }
        persistTasks()
        emitTaskUpdate(record)
        return record
    }

    private fun cancelInternal(taskId: String, deletePartialFile: Boolean): TaskRecord? {
        val record = tasks[taskId] ?: return null
        synchronized(record) {
            if (record.status == "completed" || record.status == "canceled") {
                return record
            }
            record.status = "canceled"
            record.bytesPerSecond = 0.0
            record.estimatedRemainingMs = -1L
            record.updatedAtMs = System.currentTimeMillis()
            if (deletePartialFile) {
                record.downloadedBytes = 0L
                record.progress = 0.0
            }
        }
        activeWorkers.remove(taskId)?.cancel()
        if (deletePartialFile) {
            runCatching { File("${record.savePath}.part").delete() }
        }
        cancelTaskNotification(taskId)
        persistTasks()
        emitTaskUpdate(record)
        return record
    }

    private fun retryInternal(taskId: String): TaskRecord? {
        val record = tasks[taskId] ?: return null
        activeWorkers.remove(taskId)?.cancel()
        synchronized(record) {
            val partFile = File("${record.savePath}.part")
            if (partFile.exists() && record.allowPause) {
                record.downloadedBytes = partFile.length()
            } else {
                runCatching { partFile.delete() }
                record.downloadedBytes = 0L
                record.progress = 0.0
                record.eTag = null
            }
            record.status = "queued"
            record.retryCount = 0
            record.error = null
            record.bytesPerSecond = 0.0
            record.estimatedRemainingMs = -1L
            record.updatedAtMs = System.currentTimeMillis()
        }
        persistTasks()
        emitTaskUpdate(record)
        return record
    }

    private fun removeTaskInternal(taskId: String, deleteFile: Boolean): Boolean {
        activeWorkers.remove(taskId)?.cancel()
        val removed = tasks.remove(taskId) ?: return false
        runCatching { File("${removed.savePath}.part").delete() }
        if (deleteFile) {
            runCatching { File(removed.savePath).delete() }
        }
        cancelTaskNotification(taskId)
        persistTasks()
        return true
    }

    private fun scheduleQueue() {
        synchronized(queueLock) {
            val runningCount = activeWorkers.size
            val availableSlots = maxConcurrentTasks - runningCount
            if (availableSlots <= 0) {
                updateForegroundServiceState()
                return
            }

            val candidates = tasks.values
                .filter { it.status == "queued" && !activeWorkers.containsKey(it.taskId) }
                .sortedWith(
                    compareByDescending<TaskRecord> { priorityLevel(it.priority) }
                        .thenBy { it.createdAtMs }
                )
                .take(availableSlots)

            for (record in candidates) {
                synchronized(record) {
                    record.status = "running"
                    record.updatedAtMs = System.currentTimeMillis()
                }
                emitTaskUpdate(record)
                val control = WorkerControl()
                activeWorkers[record.taskId] = control
                control.future = workerPool.submit {
                    executeDownload(record, control)
                }
            }
            updateForegroundServiceState()
        }
    }

    private fun executeDownload(record: TaskRecord, control: WorkerControl) {
        try {
            val targetFile = File(record.savePath)
            targetFile.parentFile?.mkdirs()

            // Handle conflict resolution before network request
            if (targetFile.exists()) {
                when (record.conflictResolution) {
                    "skip" -> {
                        val existingLen = targetFile.length()
                        synchronized(record) {
                            record.downloadedBytes = existingLen
                            record.totalBytes = existingLen
                            record.progress = 1.0
                            record.bytesPerSecond = 0.0
                            record.estimatedRemainingMs = 0L
                            record.status = "completed"
                            val now = System.currentTimeMillis()
                            record.updatedAtMs = now
                            record.completedAtMs = now
                        }
                        finishWorker(record)
                        return
                    }
                    "fail" -> {
                        failTask(
                            record,
                            code = "file_exists",
                            message = "Destination file already exists at ${record.savePath}",
                            httpStatus = null,
                            recoverable = false
                        )
                        return
                    }
                    "uniqueName" -> {
                        val unique = resolveDestinationFile(
                            File(record.saveDirectory),
                            record.fileName,
                            "uniqueName"
                        )
                        synchronized(record) {
                            record.fileName = unique.name
                            record.savePath = unique.absolutePath
                        }
                    }
                }
            }

            var attempt = 0
            while (!control.isStopped()) {
                if (record.requiresUnmeteredNetwork && !isUnmeteredNetworkAvailable()) {
                    failTask(
                        record,
                        code = "unmetered_network_required",
                        message = "Active connection is metered or unavailable while requiresUnmeteredNetwork is enabled.",
                        httpStatus = null,
                        recoverable = true
                    )
                    return
                }

                val outcome = performSingleAttempt(record, control)
                if (outcome.completed || control.isStopped()) {
                    return
                }

                if (outcome.recoverable && attempt < record.maxRetries) {
                    attempt++
                    synchronized(record) {
                        record.retryCount = attempt
                        record.updatedAtMs = System.currentTimeMillis()
                    }
                    emitTaskUpdate(record)
                    Thread.sleep((500L * attempt).coerceAtMost(3000L))
                    continue
                } else {
                    failTask(
                        record,
                        code = outcome.errorCode ?: "network_error",
                        message = outcome.errorMessage ?: "Download failed",
                        httpStatus = outcome.httpStatus,
                        recoverable = outcome.recoverable
                    )
                    return
                }
            }
        } finally {
            activeWorkers.remove(record.taskId)
            scheduleQueue()
        }
    }

    private fun performSingleAttempt(record: TaskRecord, control: WorkerControl): AttemptOutcome {
        var connection: HttpURLConnection? = null
        val partFile = File("${record.savePath}.part")
        try {
            val existingOffset = if (record.allowPause && partFile.exists()) partFile.length() else 0L
            val urlObj = URL(record.url)
            connection = (urlObj.openConnection() as HttpURLConnection).apply {
                requestMethod = record.method
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
                instanceFollowRedirects = true
                useCaches = false
                setRequestProperty("User-Agent", userAgent)
                setRequestProperty("Accept-Encoding", "identity")
                for ((k, v) in record.headers) {
                    setRequestProperty(k, v)
                }
                if (existingOffset > 0L) {
                    setRequestProperty("Range", "bytes=$existingOffset-")
                    record.eTag?.let { setRequestProperty("If-Range", it) }
                }
                if (record.method.equals("POST", ignoreCase = true) && !record.postBody.isNullOrEmpty()) {
                    doOutput = true
                    val bodyBytes = record.postBody.toByteArray(Charsets.UTF_8)
                    outputStream.use { it.write(bodyBytes) }
                }
            }

            connection.connect()
            if (control.isStopped()) {
                return AttemptOutcome(completed = false, recoverable = true)
            }

            val status = connection.responseCode
            // If server returns 416 Range Not Satisfiable, reset partial file and retry fresh
            if (status == HttpURLConnection.HTTP_MULT_CHOICE + 116 || status == 416) {
                runCatching { partFile.delete() }
                synchronized(record) {
                    record.downloadedBytes = 0L
                    record.eTag = null
                }
                return AttemptOutcome(
                    completed = false,
                    recoverable = true,
                    errorCode = "http_range_error",
                    errorMessage = "HTTP 416 Range Not Satisfiable",
                    httpStatus = status
                )
            }

            if (status !in 200..299) {
                val recoverable = status == 408 || status == 429 || status in 500..599
                return AttemptOutcome(
                    completed = false,
                    recoverable = recoverable,
                    errorCode = "http_error",
                    errorMessage = "HTTP $status ${connection.responseMessage ?: ""}".trim(),
                    httpStatus = status
                )
            }

            val isPartial = status == HttpURLConnection.HTTP_PARTIAL && existingOffset > 0L
            val acceptRanges = connection.getHeaderField("Accept-Ranges")
            val supportsRange = isPartial || acceptRanges?.contains("bytes", ignoreCase = true) == true
            val contentLength = connection.contentLengthLong
            val totalBytes = when {
                isPartial && contentLength > 0 -> existingOffset + contentLength
                contentLength > 0 -> contentLength
                else -> -1L
            }

            val startBytes = if (isPartial) existingOffset else 0L
            synchronized(record) {
                record.supportsResume = record.allowPause && supportsRange
                record.totalBytes = totalBytes
                record.downloadedBytes = startBytes
                record.mimeType = connection.contentType
                connection.getHeaderField("ETag")?.let { record.eTag = it }
            }

            partFile.parentFile?.mkdirs()
            RandomAccessFile(partFile, "rw").use { raf ->
                if (isPartial) {
                    raf.seek(existingOffset)
                } else {
                    raf.setLength(0L)
                    raf.seek(0L)
                }

                BufferedInputStream(connection.inputStream, 32 * 1024).use { input ->
                    val buffer = ByteArray(32 * 1024)
                    var currentBytes = startBytes
                    var lastEmitTime = System.currentTimeMillis()
                    var lastEmitBytes = currentBytes
                    var smoothedSpeed = 0.0

                    while (!control.isStopped()) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        raf.write(buffer, 0, read)
                        currentBytes += read

                        val now = System.currentTimeMillis()
                        val elapsed = now - lastEmitTime
                        if (elapsed >= progressUpdateIntervalMs) {
                            val deltaBytes = currentBytes - lastEmitBytes
                            val instantSpeed = if (elapsed > 0) (deltaBytes * 1000.0) / elapsed else 0.0
                            smoothedSpeed = if (smoothedSpeed <= 0.0) {
                                instantSpeed
                            } else {
                                smoothedSpeed * 0.65 + instantSpeed * 0.35
                            }

                            val progress = if (totalBytes > 0) {
                                (currentBytes.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0)
                            } else {
                                -1.0
                            }
                            val remainingMs = if (totalBytes > currentBytes && smoothedSpeed > 1.0) {
                                (((totalBytes - currentBytes) / smoothedSpeed) * 1000.0).toLong()
                            } else {
                                -1L
                            }

                            synchronized(record) {
                                record.downloadedBytes = currentBytes
                                record.progress = progress
                                record.bytesPerSecond = smoothedSpeed
                                record.estimatedRemainingMs = remainingMs
                                record.updatedAtMs = now
                            }
                            emitTaskUpdate(record)
                            updateTaskNotification(record)
                            lastEmitTime = now
                            lastEmitBytes = currentBytes
                        }
                    }
                }
            }

            if (control.isStopped()) {
                return AttemptOutcome(completed = false, recoverable = true)
            }

            // Compute checksum if configured or requested
            val computedHash = if (!record.expectedChecksum.isNullOrEmpty()) {
                computeFileHash(partFile, record.checksumAlgorithm)
            } else {
                null
            }

            if (!record.expectedChecksum.isNullOrEmpty() &&
                !computedHash.equals(record.expectedChecksum, ignoreCase = true)
            ) {
                runCatching { partFile.delete() }
                return AttemptOutcome(
                    completed = false,
                    recoverable = false,
                    errorCode = "checksum_mismatch",
                    errorMessage = "Checksum mismatch: expected ${record.expectedChecksum}, got $computedHash"
                )
            }

            val destFile = File(record.savePath)
            if (destFile.exists()) {
                destFile.delete()
            }
            if (!partFile.renameTo(destFile)) {
                partFile.copyTo(destFile, overwrite = true)
                partFile.delete()
            }

            val finalSize = destFile.length()
            val now = System.currentTimeMillis()
            synchronized(record) {
                record.downloadedBytes = finalSize
                if (record.totalBytes <= 0) {
                    record.totalBytes = finalSize
                }
                record.progress = 1.0
                record.bytesPerSecond = 0.0
                record.estimatedRemainingMs = 0L
                record.computedChecksum = computedHash
                record.status = "completed"
                record.error = null
                record.updatedAtMs = now
                record.completedAtMs = now
            }
            finishWorker(record)
            return AttemptOutcome(completed = true, recoverable = false)
        } catch (e: Exception) {
            if (control.isStopped()) {
                return AttemptOutcome(completed = false, recoverable = true)
            }
            return AttemptOutcome(
                completed = false,
                recoverable = true,
                errorCode = "network_error",
                errorMessage = e.message ?: e.javaClass.simpleName
            )
        } finally {
            runCatching { connection?.disconnect() }
        }
    }

    private fun finishWorker(record: TaskRecord) {
        persistTasks()
        emitTaskUpdate(record)
        updateTaskNotification(record)
    }

    private fun failTask(
        record: TaskRecord,
        code: String,
        message: String,
        httpStatus: Int?,
        recoverable: Boolean
    ) {
        synchronized(record) {
            record.status = "failed"
            record.bytesPerSecond = 0.0
            record.estimatedRemainingMs = -1L
            record.error = ErrorRecord(
                code = code,
                message = message,
                httpStatusCode = httpStatus,
                isRecoverable = recoverable
            )
            record.updatedAtMs = System.currentTimeMillis()
        }
        persistTasks()
        emitTaskUpdate(record)
        updateTaskNotification(record)
    }

    private fun emitTaskUpdate(record: TaskRecord) {
        val snapshot = synchronized(record) { record.toMap() }
        mainHandler.post {
            eventSink?.success(snapshot)
        }
    }

    // --- Notifications & Foreground Service ---

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                notificationChannelId,
                notificationChannelName,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background file download progress notifications"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun updateForegroundServiceState() {
        if (!enableNotifications) return
        val activeCount = activeWorkers.size
        val intent = Intent(applicationContext, XueHuaDownloadForegroundService::class.java)
        try {
            if (activeCount > 0) {
                intent.action = XueHuaDownloadForegroundService.ACTION_START
                intent.putExtra(XueHuaDownloadForegroundService.EXTRA_CHANNEL_ID, notificationChannelId)
                intent.putExtra(XueHuaDownloadForegroundService.EXTRA_CHANNEL_NAME, notificationChannelName)
                intent.putExtra(XueHuaDownloadForegroundService.EXTRA_ACTIVE_COUNT, activeCount)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    applicationContext.startForegroundService(intent)
                } else {
                    applicationContext.startService(intent)
                }
            } else {
                intent.action = XueHuaDownloadForegroundService.ACTION_STOP
                applicationContext.startService(intent)
            }
        } catch (_: Throwable) {
            // Foreground service start may be denied on Android 12+ if initiated strictly from background.
        }
    }

    private fun updateTaskNotification(record: TaskRecord) {
        if (!enableNotifications || !record.notificationConfig.enabled) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = applicationContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) return
        }

        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val title = record.notificationConfig.title?.takeIf { it.isNotEmpty() } ?: record.fileName
        val pct = if (record.progress >= 0.0) (record.progress * 100.0).roundToInt().coerceIn(0, 100) else 0
        val speedText = formatSpeed(record.bytesPerSecond)

        val body = when (record.status) {
            "running" -> formatTemplate(
                record.notificationConfig.runningBody ?: "Downloading ({progress}%) - {speed}",
                record.fileName,
                pct,
                speedText
            )
            "paused" -> "Paused ($pct%)"
            "completed" -> formatTemplate(
                record.notificationConfig.completedBody ?: "Download complete: {fileName}",
                record.fileName,
                100,
                speedText
            )
            "failed" -> formatTemplate(
                record.notificationConfig.failedBody ?: "Download failed: {fileName}",
                record.fileName,
                pct,
                speedText
            )
            else -> return
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(applicationContext, notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(applicationContext)
        }

        val icon = when (record.status) {
            "completed" -> android.R.drawable.stat_sys_download_done
            "failed" -> android.R.drawable.stat_notify_error
            else -> android.R.drawable.stat_sys_download
        }

        builder.setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(icon)
            .setOngoing(record.status == "running")
            .setAutoCancel(record.status != "running")

        if (record.status == "running" && record.notificationConfig.showProgress) {
            val indeterminate = record.totalBytes <= 0L
            builder.setProgress(100, pct, indeterminate)
        }

        runCatching {
            manager.notify(notificationIdForTask(record.taskId), builder.build())
        }
    }

    private fun cancelTaskNotification(taskId: String) {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching {
            manager.cancel(notificationIdForTask(taskId))
        }
    }

    private fun notificationIdForTask(taskId: String): Int =
        100000 + (taskId.hashCode() and 0x7FFFFFFF) % 800000

    private fun formatTemplate(template: String, fileName: String, progressPct: Int, speed: String): String {
        return template
            .replace("{fileName}", fileName)
            .replace("{progress}", progressPct.toString())
            .replace("{speed}", speed)
    }

    private fun formatSpeed(bytesPerSecond: Double): String {
        if (bytesPerSecond <= 0.0) return "0 B/s"
        val kb = bytesPerSecond / 1024.0
        if (kb < 1024.0) return String.format("%.1f KB/s", kb)
        val mb = kb / 1024.0
        return String.format("%.2f MB/s", mb)
    }

    // --- Persistence ---

    private fun getPersistenceFile(): File =
        File(applicationContext.filesDir, "xue_hua_downloader_tasks.json")

    private fun persistTasks() {
        synchronized(persistenceLock) {
            runCatching {
                val arr = JSONArray()
                for (record in tasks.values) {
                    val json = synchronized(record) { record.toJson() }
                    arr.put(json)
                }
                getPersistenceFile().writeText(arr.toString(), Charsets.UTF_8)
            }
        }
    }

    private fun loadPersistedTasks() {
        synchronized(persistenceLock) {
            val file = getPersistenceFile()
            if (!file.exists()) return
            runCatching {
                val text = file.readText(Charsets.UTF_8)
                val arr = JSONArray(text)
                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    val record = TaskRecord.fromJson(obj)
                    if (record.status == "running" || record.status == "queued") {
                        record.status = if (autoResumeOnStartup) "queued" else "paused"
                        record.bytesPerSecond = 0.0
                        record.estimatedRemainingMs = -1L
                    }
                    val partFile = File("${record.savePath}.part")
                    if (record.status != "completed" && partFile.exists()) {
                        record.downloadedBytes = partFile.length()
                        if (record.totalBytes > 0) {
                            record.progress = (record.downloadedBytes.toDouble() / record.totalBytes.toDouble())
                                .coerceIn(0.0, 1.0)
                        }
                    }
                    tasks[record.taskId] = record
                }
            }
        }
    }

    // --- Utilities ---

    private fun getDefaultDownloadDirectory(): File {
        val extDir = applicationContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        val dir = extDir ?: File(applicationContext.filesDir, "downloads")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    private fun sanitizeFileName(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        return cleaned.ifEmpty { "download_${System.currentTimeMillis()}.bin" }
    }

    private fun inferFileNameFromUrl(url: String): String {
        return try {
            val path = URL(url).path
            val rawLast = path.substringAfterLast('/', "")
            val decoded = URLDecoder.decode(rawLast, "UTF-8")
            sanitizeFileName(decoded.ifEmpty { "download_${System.currentTimeMillis()}.bin" })
        } catch (_: Exception) {
            "download_${System.currentTimeMillis()}.bin"
        }
    }

    private fun resolveDestinationFile(dir: File, fileName: String, conflictResolution: String): File {
        val initial = File(dir, fileName)
        if (conflictResolution != "uniqueName" || !initial.exists()) {
            return initial
        }
        val dotIndex = fileName.lastIndexOf('.')
        val base = if (dotIndex > 0) fileName.substring(0, dotIndex) else fileName
        val ext = if (dotIndex > 0) fileName.substring(dotIndex) else ""
        var counter = 1
        while (true) {
            val candidate = File(dir, "$base ($counter)$ext")
            if (!candidate.exists() && !File("${candidate.absolutePath}.part").exists()) {
                return candidate
            }
            counter++
        }
    }

    private fun computeFileHash(file: File, algorithm: String): String {
        val digestName = if (algorithm.equals("md5", ignoreCase = true)) "MD5" else "SHA-256"
        val digest = MessageDigest.getInstance(digestName)
        FileInputStream(file).use { fis ->
            val buf = ByteArray(16 * 1024)
            var r: Int
            while (fis.read(buf).also { r = it } != -1) {
                digest.update(buf, 0, r)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun isUnmeteredNetworkAvailable(): Boolean {
        val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true
        val net = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(net) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    private fun priorityLevel(priority: String): Int = when (priority) {
        "critical" -> 3
        "high" -> 2
        "normal" -> 1
        else -> 0
    }

    private class WorkerControl {
        private val stopped = AtomicBoolean(false)
        @Volatile
        var future: Future<*>? = null

        fun pause() {
            stopped.set(true)
        }

        fun cancel() {
            stopped.set(true)
            future?.cancel(true)
        }

        fun isStopped(): Boolean = stopped.get()
    }

    private data class AttemptOutcome(
        val completed: Boolean,
        val recoverable: Boolean,
        val errorCode: String? = null,
        val errorMessage: String? = null,
        val httpStatus: Int? = null
    )

    private data class NotificationConfigRecord(
        val enabled: Boolean,
        val title: String?,
        val runningBody: String?,
        val completedBody: String?,
        val failedBody: String?,
        val showProgress: Boolean
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "enabled" to enabled,
            "title" to title,
            "runningBody" to runningBody,
            "completedBody" to completedBody,
            "failedBody" to failedBody,
            "showProgress" to showProgress
        )

        fun toJson(): JSONObject = JSONObject().apply {
            put("enabled", enabled)
            put("title", title)
            put("runningBody", runningBody)
            put("completedBody", completedBody)
            put("failedBody", failedBody)
            put("showProgress", showProgress)
        }

        companion object {
            fun fromJson(obj: JSONObject?): NotificationConfigRecord {
                if (obj == null) {
                    return NotificationConfigRecord(true, null, null, null, null, true)
                }
                return NotificationConfigRecord(
                    enabled = obj.optBoolean("enabled", true),
                    title = obj.optString("title", "").takeIf { it.isNotEmpty() },
                    runningBody = obj.optString("runningBody", "").takeIf { it.isNotEmpty() },
                    completedBody = obj.optString("completedBody", "").takeIf { it.isNotEmpty() },
                    failedBody = obj.optString("failedBody", "").takeIf { it.isNotEmpty() },
                    showProgress = obj.optBoolean("showProgress", true)
                )
            }
        }
    }

    private data class ErrorRecord(
        val code: String,
        val message: String,
        val httpStatusCode: Int?,
        val isRecoverable: Boolean
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "code" to code,
            "message" to message,
            "httpStatusCode" to httpStatusCode,
            "isRecoverable" to isRecoverable
        )

        fun toJson(): JSONObject = JSONObject().apply {
            put("code", code)
            put("message", message)
            if (httpStatusCode != null) put("httpStatusCode", httpStatusCode)
            put("isRecoverable", isRecoverable)
        }

        companion object {
            fun fromJson(obj: JSONObject?): ErrorRecord? {
                if (obj == null) return null
                return ErrorRecord(
                    code = obj.optString("code", "unknown_error"),
                    message = obj.optString("message", "Unknown error"),
                    httpStatusCode = if (obj.has("httpStatusCode")) obj.optInt("httpStatusCode") else null,
                    isRecoverable = obj.optBoolean("isRecoverable", true)
                )
            }
        }
    }

    private data class TaskRecord(
        val taskId: String,
        val url: String,
        val saveDirectory: String,
        var fileName: String,
        var savePath: String,
        var status: String,
        val group: String,
        val priority: String,
        val conflictResolution: String,
        val method: String,
        val postBody: String?,
        var downloadedBytes: Long,
        var totalBytes: Long,
        var progress: Double,
        var bytesPerSecond: Double,
        var estimatedRemainingMs: Long,
        var retryCount: Int,
        val maxRetries: Int,
        var supportsResume: Boolean,
        val allowPause: Boolean,
        val requiresUnmeteredNetwork: Boolean,
        val expectedChecksum: String?,
        val checksumAlgorithm: String,
        var computedChecksum: String?,
        var mimeType: String?,
        var eTag: String?,
        var error: ErrorRecord?,
        val createdAtMs: Long,
        var updatedAtMs: Long,
        var completedAtMs: Long?,
        val headers: Map<String, String>,
        val metadata: Map<String, String>,
        val notificationConfig: NotificationConfigRecord
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "taskId" to taskId,
            "url" to url,
            "saveDirectory" to saveDirectory,
            "fileName" to fileName,
            "savePath" to savePath,
            "status" to status,
            "group" to group,
            "priority" to priority,
            "conflictResolution" to conflictResolution,
            "downloadedBytes" to downloadedBytes,
            "totalBytes" to totalBytes,
            "progress" to progress,
            "bytesPerSecond" to bytesPerSecond,
            "estimatedRemainingMs" to estimatedRemainingMs,
            "retryCount" to retryCount,
            "maxRetries" to maxRetries,
            "supportsResume" to supportsResume,
            "requiresUnmeteredNetwork" to requiresUnmeteredNetwork,
            "expectedChecksum" to expectedChecksum,
            "checksumAlgorithm" to checksumAlgorithm,
            "computedChecksum" to computedChecksum,
            "mimeType" to mimeType,
            "eTag" to eTag,
            "error" to error?.toMap(),
            "createdAtMs" to createdAtMs,
            "updatedAtMs" to updatedAtMs,
            "completedAtMs" to completedAtMs,
            "headers" to headers,
            "metadata" to metadata,
            "notificationConfig" to notificationConfig.toMap()
        )

        fun toJson(): JSONObject = JSONObject().apply {
            put("taskId", taskId)
            put("url", url)
            put("saveDirectory", saveDirectory)
            put("fileName", fileName)
            put("savePath", savePath)
            put("status", status)
            put("group", group)
            put("priority", priority)
            put("conflictResolution", conflictResolution)
            put("method", method)
            if (postBody != null) put("postBody", postBody)
            put("downloadedBytes", downloadedBytes)
            put("totalBytes", totalBytes)
            put("progress", progress)
            put("retryCount", retryCount)
            put("maxRetries", maxRetries)
            put("supportsResume", supportsResume)
            put("allowPause", allowPause)
            put("requiresUnmeteredNetwork", requiresUnmeteredNetwork)
            if (expectedChecksum != null) put("expectedChecksum", expectedChecksum)
            put("checksumAlgorithm", checksumAlgorithm)
            if (computedChecksum != null) put("computedChecksum", computedChecksum)
            if (mimeType != null) put("mimeType", mimeType)
            if (eTag != null) put("eTag", eTag)
            if (error != null) put("error", error!!.toJson())
            put("createdAtMs", createdAtMs)
            put("updatedAtMs", updatedAtMs)
            if (completedAtMs != null) put("completedAtMs", completedAtMs!!)
            put("headers", JSONObject(headers))
            put("metadata", JSONObject(metadata))
            put("notificationConfig", notificationConfig.toJson())
        }

        companion object {
            fun fromJson(obj: JSONObject): TaskRecord {
                val headersObj = obj.optJSONObject("headers")
                val headers = mutableMapOf<String, String>()
                headersObj?.keys()?.forEach { k ->
                    headers[k] = headersObj.optString(k, "")
                }
                val metaObj = obj.optJSONObject("metadata")
                val metadata = mutableMapOf<String, String>()
                metaObj?.keys()?.forEach { k ->
                    metadata[k] = metaObj.optString(k, "")
                }

                return TaskRecord(
                    taskId = obj.optString("taskId"),
                    url = obj.optString("url"),
                    saveDirectory = obj.optString("saveDirectory"),
                    fileName = obj.optString("fileName"),
                    savePath = obj.optString("savePath"),
                    status = obj.optString("status", "paused"),
                    group = obj.optString("group", "default"),
                    priority = obj.optString("priority", "normal"),
                    conflictResolution = obj.optString("conflictResolution", "overwrite"),
                    method = obj.optString("method", "GET"),
                    postBody = obj.optString("postBody", "").takeIf { it.isNotEmpty() },
                    downloadedBytes = max(0L, obj.optLong("downloadedBytes", 0L)),
                    totalBytes = obj.optLong("totalBytes", -1L),
                    progress = obj.optDouble("progress", 0.0),
                    bytesPerSecond = 0.0,
                    estimatedRemainingMs = -1L,
                    retryCount = obj.optInt("retryCount", 0),
                    maxRetries = obj.optInt("maxRetries", 2),
                    supportsResume = obj.optBoolean("supportsResume", true),
                    allowPause = obj.optBoolean("allowPause", true),
                    requiresUnmeteredNetwork = obj.optBoolean("requiresUnmeteredNetwork", false),
                    expectedChecksum = obj.optString("expectedChecksum", "").takeIf { it.isNotEmpty() },
                    checksumAlgorithm = obj.optString("checksumAlgorithm", "sha256"),
                    computedChecksum = obj.optString("computedChecksum", "").takeIf { it.isNotEmpty() },
                    mimeType = obj.optString("mimeType", "").takeIf { it.isNotEmpty() },
                    eTag = obj.optString("eTag", "").takeIf { it.isNotEmpty() },
                    error = ErrorRecord.fromJson(obj.optJSONObject("error")),
                    createdAtMs = obj.optLong("createdAtMs", System.currentTimeMillis()),
                    updatedAtMs = obj.optLong("updatedAtMs", System.currentTimeMillis()),
                    completedAtMs = if (obj.has("completedAtMs")) obj.optLong("completedAtMs") else null,
                    headers = headers,
                    metadata = metadata,
                    notificationConfig = NotificationConfigRecord.fromJson(obj.optJSONObject("notificationConfig"))
                )
            }
        }
    }

    companion object {
        private const val REQUEST_CODE_NOTIFICATIONS = 48102
    }
}
