import Cocoa
import CryptoKit
import FlutterMacOS
import Foundation
import Network
import UserNotifications

/// Native multi-task background downloader implementation for macOS.
///
/// Features:
/// - Priority-ordered multi-task concurrency queue with configurable `maxConcurrentTasks`
/// - Local JSON task persistence in `Application Support/xue_hua_background_downloader/tasks.json`
/// - Streaming `URLSessionDataTask` + `.part` file HTTP `Range` (`206 Partial Content`) pause/resume
///   with `ProcessInfo.processInfo.beginActivity` background activity assertion
/// - Post-download MD5 and SHA-256 checksum verification via `CryptoKit`
/// - Built-in `UNUserNotificationCenter` system notifications
/// - Unmetered network (`NWPathMonitor` `isExpensive`) verification
public final class XueHuaNaviteBackgroundDownloaderPlugin: NSObject,
  FlutterPlugin,
  FlutterStreamHandler,
  URLSessionDataDelegate,
  UNUserNotificationCenterDelegate
{
  public static let shared = XueHuaNaviteBackgroundDownloaderPlugin()

  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private weak var previousNotificationDelegate: UNUserNotificationCenterDelegate?

  private let stateQueue = DispatchQueue(
    label: "com.kurban.xue_hua_navite_background_downloader.macos.state"
  )
  private var urlSession: URLSession!
  private let sessionDelegateQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "com.kurban.xue_hua_navite_background_downloader.macos.session"
    q.maxConcurrentOperationCount = 1
    return q
  }()

  private let pathMonitor = NWPathMonitor()
  private var isNetworkAvailable: Bool = true
  private var isNetworkExpensive: Bool = false

  private var backgroundActivity: NSObjectProtocol?

  // Global configuration
  private var maxConcurrentTasks: Int = 3
  private var connectTimeoutMs: Int = 15000
  private var readTimeoutMs: Int = 30000
  private var progressUpdateIntervalMs: Int64 = 250
  private var enableNotifications: Bool = true
  private var userAgent: String = "XueHuaNativeBackgroundDownloader/1.0.0"
  private var defaultHeaders: [String: String] = [:]
  private var autoResumeOnStartup: Bool = false

  private var tasks: [String: TaskRecord] = [:]
  private var activeSessions: [Int: ActiveTransfer] = [:]
  private var taskIdToSessionTaskId: [String: Int] = [:]

  public override init() {
    super.init()
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15.0
    config.timeoutIntervalForResource = 3600.0
    config.httpMaximumConnectionsPerHost = 16
    config.waitsForConnectivity = false
    urlSession = URLSession(
      configuration: config,
      delegate: self,
      delegateQueue: sessionDelegateQueue
    )

    pathMonitor.pathUpdateHandler = { [weak self] path in
      self?.isNetworkAvailable = (path.status == .satisfied)
      self?.isNetworkExpensive = path.isExpensive
    }
    pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

    stateQueue.async {
      self.loadPersistedTasks()
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = XueHuaNaviteBackgroundDownloaderPlugin.shared
    let methodChannel = FlutterMethodChannel(
      name: "com.kurban.xue_hua_navite_background_downloader/methods",
      binaryMessenger: registrar.messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "com.kurban.xue_hua_navite_background_downloader/events",
      binaryMessenger: registrar.messenger
    )
    instance.methodChannel = methodChannel
    instance.eventChannel = eventChannel
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)

    let center = UNUserNotificationCenter.current()
    if center.delegate !== instance {
      instance.previousNotificationDelegate = center.delegate
      center.delegate = instance
    }
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.identifier.hasPrefix("xue_hua_dl_") {
      completionHandler([.banner, .list, .sound])
    } else if let prev = previousNotificationDelegate,
      prev.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)))
    {
      prev.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
    } else {
      completionHandler([.banner, .list, .sound])
    }
  }

  // MARK: - FlutterStreamHandler

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  // MARK: - MethodCall Handler

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      let args = call.arguments as? [String: Any] ?? [:]
      stateQueue.async {
        self.maxConcurrentTasks = min(16, max(1, args["maxConcurrentTasks"] as? Int ?? 3))
        self.connectTimeoutMs = max(1000, args["connectTimeoutMs"] as? Int ?? 15000)
        self.readTimeoutMs = max(1000, args["readTimeoutMs"] as? Int ?? 30000)
        self.progressUpdateIntervalMs = max(
          50,
          Int64(args["progressUpdateIntervalMs"] as? Int ?? 250)
        )
        self.enableNotifications = args["enableNotifications"] as? Bool ?? true
        self.userAgent =
          args["userAgent"] as? String ?? "XueHuaNativeBackgroundDownloader/1.0.0"
        self.autoResumeOnStartup = args["autoResumeOnStartup"] as? Bool ?? false
        if let headers = args["defaultHeaders"] as? [String: Any] {
          var mapped: [String: String] = [:]
          for (k, v) in headers {
            mapped[k] = "\(v)"
          }
          self.defaultHeaders = mapped
        }
        self.scheduleQueueLocked()
        DispatchQueue.main.async { result(nil) }
      }

    case "getCapabilities":
      let defaultDir = Self.defaultDownloadDirectory().path
      result([
        "platform": "macos",
        "nativeEngine": "URLSession + NSProcessInfo Activity",
        "supportsBackgroundExecution": true,
        "supportsPauseResume": true,
        "supportsSystemNotifications": true,
        "supportsPersistence": true,
        "supportsChecksumVerification": true,
        "supportsNetworkConstraints": true,
        "defaultDownloadDirectory": defaultDir,
        "taskStorePath": Self.persistenceFileURL().path,
      ])

    case "requestNotificationPermission":
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { granted, _ in
        DispatchQueue.main.async {
          result(granted)
        }
      }

    case "enqueue":
      guard let args = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Expected request map",
            details: nil
          )
        )
        return
      }
      stateQueue.async {
        let record = self.createOrResetTaskLocked(from: args)
        self.scheduleQueueLocked()
        let map = record.toMap()
        DispatchQueue.main.async { result(map) }
      }

    case "enqueueAll":
      let args = call.arguments as? [String: Any]
      let reqList = args?["requests"] as? [[String: Any]] ?? []
      stateQueue.async {
        var created: [[String: Any?]] = []
        for req in reqList {
          let record = self.createOrResetTaskLocked(from: req)
          created.append(record.toMap())
        }
        self.scheduleQueueLocked()
        DispatchQueue.main.async { result(created) }
      }

    case "pause":
      let args = call.arguments as? [String: Any]
      let taskId = args?["taskId"] as? String ?? ""
      stateQueue.async {
        let record = self.pauseLocked(taskId: taskId)
        self.scheduleQueueLocked()
        let map = record?.toMap()
        DispatchQueue.main.async { result(map) }
      }

    case "resume":
      let args = call.arguments as? [String: Any]
      let taskId = args?["taskId"] as? String ?? ""
      stateQueue.async {
        let record = self.resumeLocked(taskId: taskId)
        self.scheduleQueueLocked()
        let map = record?.toMap()
        DispatchQueue.main.async { result(map) }
      }

    case "cancel":
      let args = call.arguments as? [String: Any]
      let taskId = args?["taskId"] as? String ?? ""
      let deletePartial = args?["deletePartialFile"] as? Bool ?? true
      stateQueue.async {
        let record = self.cancelLocked(taskId: taskId, deletePartialFile: deletePartial)
        self.scheduleQueueLocked()
        let map = record?.toMap()
        DispatchQueue.main.async { result(map) }
      }

    case "retry":
      let args = call.arguments as? [String: Any]
      let taskId = args?["taskId"] as? String ?? ""
      stateQueue.async {
        let record = self.retryLocked(taskId: taskId)
        self.scheduleQueueLocked()
        let map = record?.toMap()
        DispatchQueue.main.async { result(map) }
      }

    case "removeTask":
      let args = call.arguments as? [String: Any]
      let taskId = args?["taskId"] as? String ?? ""
      let deleteFile = args?["deleteFile"] as? Bool ?? false
      stateQueue.async {
        let removed = self.removeTaskLocked(taskId: taskId, deleteFile: deleteFile)
        self.scheduleQueueLocked()
        DispatchQueue.main.async { result(removed) }
      }

    case "pauseAll":
      let args = call.arguments as? [String: Any]
      let group = args?["group"] as? String
      stateQueue.async {
        var updated: [[String: Any?]] = []
        for record in self.tasks.values {
          if let g = group, record.group != g { continue }
          if record.status == "queued" || record.status == "running" {
            if let paused = self.pauseLocked(taskId: record.taskId) {
              updated.append(paused.toMap())
            }
          }
        }
        self.scheduleQueueLocked()
        DispatchQueue.main.async { result(updated) }
      }

    case "resumeAll":
      let args = call.arguments as? [String: Any]
      let group = args?["group"] as? String
      stateQueue.async {
        var updated: [[String: Any?]] = []
        for record in self.tasks.values {
          if let g = group, record.group != g { continue }
          if record.status == "paused" {
            if let resumed = self.resumeLocked(taskId: record.taskId) {
              updated.append(resumed.toMap())
            }
          }
        }
        self.scheduleQueueLocked()
        DispatchQueue.main.async { result(updated) }
      }

    case "cancelAll":
      let args = call.arguments as? [String: Any]
      let group = args?["group"] as? String
      let deletePartial = args?["deletePartialFiles"] as? Bool ?? true
      stateQueue.async {
        var updated: [[String: Any?]] = []
        for record in self.tasks.values {
          if let g = group, record.group != g { continue }
          if record.status == "queued" || record.status == "running" || record.status == "paused" {
            if let canceled = self.cancelLocked(
              taskId: record.taskId,
              deletePartialFile: deletePartial
            ) {
              updated.append(canceled.toMap())
            }
          }
        }
        self.scheduleQueueLocked()
        DispatchQueue.main.async { result(updated) }
      }

    case "clearCompleted":
      let args = call.arguments as? [String: Any]
      let group = args?["group"] as? String
      let deleteFiles = args?["deleteFiles"] as? Bool ?? false
      stateQueue.async {
        var removedIds: [String] = []
        for (id, record) in self.tasks {
          if let g = group, record.group != g { continue }
          if record.status == "completed" {
            if deleteFiles {
              try? FileManager.default.removeItem(atPath: record.savePath)
            }
            removedIds.append(id)
          }
        }
        for id in removedIds {
          self.tasks.removeValue(forKey: id)
        }
        if !removedIds.isEmpty {
          self.persistTasksLocked()
        }
        DispatchQueue.main.async { result(removedIds.count) }
      }

    case "getTask":
      let args = call.arguments as? [String: Any]
      let taskId = args?["taskId"] as? String ?? ""
      stateQueue.async {
        let map = self.tasks[taskId]?.toMap()
        DispatchQueue.main.async { result(map) }
      }

    case "getAllTasks":
      let args = call.arguments as? [String: Any]
      let group = args?["group"] as? String
      stateQueue.async {
        let list = self.tasks.values
          .filter { group == nil || $0.group == group }
          .sorted { $0.createdAtMs > $1.createdAtMs }
          .map { $0.toMap() }
        DispatchQueue.main.async { result(list) }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Task Management

  private func createOrResetTaskLocked(from args: [String: Any]) -> TaskRecord {
    let url = (args["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let rawId = (args["taskId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let taskId = (rawId?.isEmpty == false) ? rawId! : UUID().uuidString

    if let existingSessionTaskId = taskIdToSessionTaskId.removeValue(forKey: taskId),
      let transfer = activeSessions.removeValue(forKey: existingSessionTaskId)
    {
      transfer.stoppedIntentionally = true
      transfer.dataTask.cancel()
      try? transfer.fileHandle?.close()
    }

    let rawDir = (args["saveDirectory"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let dirURL: URL
    if let d = rawDir, !d.isEmpty {
      dirURL = URL(fileURLWithPath: d, isDirectory: true)
    } else {
      dirURL = Self.defaultDownloadDirectory()
    }
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    let rawFileName = (args["fileName"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let initialName =
      (rawFileName?.isEmpty == false)
      ? Self.sanitizeFileName(rawFileName!)
      : Self.inferFileName(from: url)
    let conflict = args["conflictResolution"] as? String ?? "overwrite"
    let resolvedURL = Self.resolveDestinationURL(
      dir: dirURL,
      fileName: initialName,
      conflictResolution: conflict
    )

    var mergedHeaders = defaultHeaders
    if let customHeaders = args["headers"] as? [String: Any] {
      for (k, v) in customHeaders {
        mergedHeaders[k] = "\(v)"
      }
    }

    var meta: [String: String] = [:]
    if let rawMeta = args["metadata"] as? [String: Any] {
      for (k, v) in rawMeta {
        meta[k] = "\(v)"
      }
    }

    let notifMap = args["notificationConfig"] as? [String: Any]
    let notif = NotificationConfigRecord(from: notifMap)
    let now = Self.nowMs()
    let allowPause = args["allowPause"] as? Bool ?? true

    let record = TaskRecord(
      taskId: taskId,
      url: url,
      saveDirectory: dirURL.path,
      fileName: resolvedURL.lastPathComponent,
      savePath: resolvedURL.path,
      status: "queued",
      group: args["group"] as? String ?? "default",
      priority: args["priority"] as? String ?? "normal",
      conflictResolution: conflict,
      method: args["method"] as? String ?? "GET",
      postBody: args["postBody"] as? String,
      downloadedBytes: 0,
      totalBytes: -1,
      progress: 0.0,
      bytesPerSecond: 0.0,
      estimatedRemainingMs: -1,
      retryCount: 0,
      maxRetries: max(0, args["maxRetries"] as? Int ?? 2),
      supportsResume: allowPause,
      allowPause: allowPause,
      requiresUnmeteredNetwork: args["requiresUnmeteredNetwork"] as? Bool ?? false,
      expectedChecksum: (args["expectedChecksum"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      checksumAlgorithm: args["checksumAlgorithm"] as? String ?? "sha256",
      computedChecksum: nil,
      mimeType: nil,
      eTag: nil,
      error: nil,
      createdAtMs: now,
      updatedAtMs: now,
      completedAtMs: nil,
      headers: mergedHeaders,
      metadata: meta,
      notificationConfig: notif
    )

    tasks[taskId] = record
    persistTasksLocked()
    emitTaskUpdate(record)
    return record
  }

  private func pauseLocked(taskId: String) -> TaskRecord? {
    guard let record = tasks[taskId] else { return nil }
    guard record.status == "running" || record.status == "queued" else { return record }

    if let sessionTaskId = taskIdToSessionTaskId.removeValue(forKey: taskId),
      let transfer = activeSessions.removeValue(forKey: sessionTaskId)
    {
      transfer.stoppedIntentionally = true
      transfer.dataTask.cancel()
      try? transfer.fileHandle?.synchronize()
      try? transfer.fileHandle?.close()
    }

    let partPath = record.savePath + ".part"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
      let size = attrs[.size] as? NSNumber
    {
      record.downloadedBytes = size.int64Value
    }

    record.status = "paused"
    record.bytesPerSecond = 0.0
    record.estimatedRemainingMs = -1
    record.updatedAtMs = Self.nowMs()
    persistTasksLocked()
    emitTaskUpdate(record)
    return record
  }

  private func resumeLocked(taskId: String) -> TaskRecord? {
    guard let record = tasks[taskId] else { return nil }
    guard record.status == "paused" || record.status == "failed" else { return record }

    let partPath = record.savePath + ".part"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
      let size = attrs[.size] as? NSNumber
    {
      record.downloadedBytes = size.int64Value
    } else {
      record.downloadedBytes = 0
      record.eTag = nil
    }

    record.status = "queued"
    record.error = nil
    record.updatedAtMs = Self.nowMs()
    persistTasksLocked()
    emitTaskUpdate(record)
    return record
  }

  private func cancelLocked(taskId: String, deletePartialFile: Bool) -> TaskRecord? {
    guard let record = tasks[taskId] else { return nil }
    if record.status == "completed" || record.status == "canceled" {
      return record
    }

    if let sessionTaskId = taskIdToSessionTaskId.removeValue(forKey: taskId),
      let transfer = activeSessions.removeValue(forKey: sessionTaskId)
    {
      transfer.stoppedIntentionally = true
      transfer.dataTask.cancel()
      try? transfer.fileHandle?.close()
    }

    if deletePartialFile {
      try? FileManager.default.removeItem(atPath: record.savePath + ".part")
      record.downloadedBytes = 0
      record.progress = 0.0
    }

    record.status = "canceled"
    record.bytesPerSecond = 0.0
    record.estimatedRemainingMs = -1
    record.updatedAtMs = Self.nowMs()
    persistTasksLocked()
    emitTaskUpdate(record)
    return record
  }

  private func retryLocked(taskId: String) -> TaskRecord? {
    guard let record = tasks[taskId] else { return nil }
    if let sessionTaskId = taskIdToSessionTaskId.removeValue(forKey: taskId),
      let transfer = activeSessions.removeValue(forKey: sessionTaskId)
    {
      transfer.stoppedIntentionally = true
      transfer.dataTask.cancel()
      try? transfer.fileHandle?.close()
    }

    let partPath = record.savePath + ".part"
    if record.allowPause,
      let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
      let size = attrs[.size] as? NSNumber
    {
      record.downloadedBytes = size.int64Value
    } else {
      try? FileManager.default.removeItem(atPath: partPath)
      record.downloadedBytes = 0
      record.progress = 0.0
      record.eTag = nil
    }

    record.status = "queued"
    record.retryCount = 0
    record.error = nil
    record.bytesPerSecond = 0.0
    record.estimatedRemainingMs = -1
    record.updatedAtMs = Self.nowMs()
    persistTasksLocked()
    emitTaskUpdate(record)
    return record
  }

  private func removeTaskLocked(taskId: String, deleteFile: Bool) -> Bool {
    if let sessionTaskId = taskIdToSessionTaskId.removeValue(forKey: taskId),
      let transfer = activeSessions.removeValue(forKey: sessionTaskId)
    {
      transfer.stoppedIntentionally = true
      transfer.dataTask.cancel()
      try? transfer.fileHandle?.close()
    }
    guard let removed = tasks.removeValue(forKey: taskId) else { return false }
    try? FileManager.default.removeItem(atPath: removed.savePath + ".part")
    if deleteFile {
      try? FileManager.default.removeItem(atPath: removed.savePath)
    }
    persistTasksLocked()
    return true
  }

  // MARK: - Queue Scheduler

  private func scheduleQueueLocked() {
    let runningCount = activeSessions.count
    let available = maxConcurrentTasks - runningCount
    if available <= 0 {
      updateBackgroundKeepAliveLocked()
      return
    }

    let candidates = tasks.values
      .filter { $0.status == "queued" && taskIdToSessionTaskId[$0.taskId] == nil }
      .sorted {
        let p0 = Self.priorityLevel($0.priority)
        let p1 = Self.priorityLevel($1.priority)
        if p0 != p1 { return p0 > p1 }
        return $0.createdAtMs < $1.createdAtMs
      }
      .prefix(available)

    for record in candidates {
      startTaskTransferLocked(record)
    }
    updateBackgroundKeepAliveLocked()
  }

  private func startTaskTransferLocked(_ record: TaskRecord) {
    let destURL = URL(fileURLWithPath: record.savePath)
    try? FileManager.default.createDirectory(
      at: destURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: record.savePath) {
      switch record.conflictResolution {
      case "skip":
        let size =
          (try? FileManager.default.attributesOfItem(atPath: record.savePath)[.size] as? NSNumber)?
          .int64Value ?? 0
        record.downloadedBytes = size
        record.totalBytes = size
        record.progress = 1.0
        record.bytesPerSecond = 0.0
        record.estimatedRemainingMs = 0
        record.status = "completed"
        let now = Self.nowMs()
        record.updatedAtMs = now
        record.completedAtMs = now
        persistTasksLocked()
        emitTaskUpdate(record)
        postNotificationIfNeeded(for: record)
        return

      case "fail":
        failTaskLocked(
          record,
          code: "file_exists",
          message: "Destination file already exists at \(record.savePath)",
          httpStatus: nil,
          recoverable: false
        )
        return

      case "uniqueName":
        let unique = Self.resolveDestinationURL(
          dir: URL(fileURLWithPath: record.saveDirectory, isDirectory: true),
          fileName: record.fileName,
          conflictResolution: "uniqueName"
        )
        record.fileName = unique.lastPathComponent
        record.savePath = unique.path

      default:
        break
      }
    }

    if record.requiresUnmeteredNetwork && (!isNetworkAvailable || isNetworkExpensive) {
      failTaskLocked(
        record,
        code: "unmetered_network_required",
        message: "Active connection is metered while requiresUnmeteredNetwork is enabled.",
        httpStatus: nil,
        recoverable: true
      )
      return
    }

    guard let requestURL = URL(string: record.url) else {
      failTaskLocked(
        record,
        code: "invalid_url",
        message: "Malformed download URL: \(record.url)",
        httpStatus: nil,
        recoverable: false
      )
      return
    }

    let partPath = record.savePath + ".part"
    let existingOffset: Int64
    if record.allowPause,
      let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
      let size = attrs[.size] as? NSNumber
    {
      existingOffset = size.int64Value
    } else {
      existingOffset = 0
    }

    var urlRequest = URLRequest(url: requestURL)
    urlRequest.httpMethod = record.method
    urlRequest.timeoutInterval = Double(readTimeoutMs) / 1000.0
    urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    for (k, v) in record.headers {
      urlRequest.setValue(v, forHTTPHeaderField: k)
    }
    if existingOffset > 0 {
      urlRequest.setValue("bytes=\(existingOffset)-", forHTTPHeaderField: "Range")
      if let eTag = record.eTag, !eTag.isEmpty {
        urlRequest.setValue(eTag, forHTTPHeaderField: "If-Range")
      }
    }
    if record.method.uppercased() == "POST", let body = record.postBody, !body.isEmpty {
      urlRequest.httpBody = body.data(using: .utf8)
    }

    record.status = "running"
    record.updatedAtMs = Self.nowMs()
    emitTaskUpdate(record)

    let dataTask = urlSession.dataTask(with: urlRequest)
    let transfer = ActiveTransfer(
      taskId: record.taskId,
      dataTask: dataTask,
      requestedOffset: existingOffset
    )
    activeSessions[dataTask.taskIdentifier] = transfer
    taskIdToSessionTaskId[record.taskId] = dataTask.taskIdentifier
    dataTask.resume()
  }

  // MARK: - URLSessionDataDelegate

  public func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    stateQueue.async {
      guard let transfer = self.activeSessions[dataTask.taskIdentifier],
        let record = self.tasks[transfer.taskId]
      else {
        completionHandler(.cancel)
        return
      }

      let httpResp = response as? HTTPURLResponse
      let statusCode = httpResp?.statusCode ?? 200
      transfer.httpStatusCode = statusCode

      if statusCode == 416 {
        try? FileManager.default.removeItem(atPath: record.savePath + ".part")
        record.downloadedBytes = 0
        record.eTag = nil
        completionHandler(.cancel)
        return
      }

      if !(200...299).contains(statusCode) {
        completionHandler(.cancel)
        return
      }

      let isPartial = (statusCode == 206 && transfer.requestedOffset > 0)
      let expectedContentLength = response.expectedContentLength
      let totalBytes: Int64
      if expectedContentLength > 0 {
        totalBytes =
          isPartial ? (transfer.requestedOffset + expectedContentLength) : expectedContentLength
      } else {
        totalBytes = -1
      }

      let acceptRanges = httpResp?.value(forHTTPHeaderField: "Accept-Ranges") ?? ""
      record.supportsResume =
        record.allowPause && (isPartial || acceptRanges.lowercased().contains("bytes"))
      record.totalBytes = totalBytes
      record.downloadedBytes = isPartial ? transfer.requestedOffset : 0
      record.mimeType = response.mimeType
      if let eTag = httpResp?.value(forHTTPHeaderField: "ETag") {
        record.eTag = eTag
      }

      let partPath = record.savePath + ".part"
      if !isPartial || !FileManager.default.fileExists(atPath: partPath) {
        FileManager.default.createFile(atPath: partPath, contents: nil)
      }
      if let handle = FileHandle(forWritingAtPath: partPath) {
        if isPartial {
          _ = try? handle.seekToEnd()
        } else {
          try? handle.truncate(atOffset: 0)
        }
        transfer.fileHandle = handle
      }

      transfer.currentBytes = record.downloadedBytes
      transfer.lastEmitBytes = record.downloadedBytes
      transfer.lastEmitMs = Self.nowMs()
      completionHandler(.allow)
    }
  }

  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
  {
    stateQueue.async {
      guard let transfer = self.activeSessions[dataTask.taskIdentifier],
        !transfer.stoppedIntentionally,
        let record = self.tasks[transfer.taskId]
      else {
        return
      }

      do {
        if let handle = transfer.fileHandle {
          try handle.write(contentsOf: data)
        }
      } catch {
        transfer.writeError = error.localizedDescription
        dataTask.cancel()
        return
      }

      transfer.currentBytes += Int64(data.count)
      let now = Self.nowMs()
      let elapsed = now - transfer.lastEmitMs
      if elapsed >= self.progressUpdateIntervalMs {
        let delta = transfer.currentBytes - transfer.lastEmitBytes
        let instantSpeed = elapsed > 0 ? (Double(delta) * 1000.0 / Double(elapsed)) : 0.0
        transfer.smoothedSpeed =
          transfer.smoothedSpeed <= 0.0
          ? instantSpeed
          : (transfer.smoothedSpeed * 0.65 + instantSpeed * 0.35)

        record.downloadedBytes = transfer.currentBytes
        if record.totalBytes > 0 {
          record.progress = min(
            1.0,
            max(0.0, Double(transfer.currentBytes) / Double(record.totalBytes))
          )
        } else {
          record.progress = -1.0
        }
        record.bytesPerSecond = transfer.smoothedSpeed
        if record.totalBytes > transfer.currentBytes && transfer.smoothedSpeed > 1.0 {
          record.estimatedRemainingMs = Int64(
            (Double(record.totalBytes - transfer.currentBytes) / transfer.smoothedSpeed) * 1000.0
          )
        } else {
          record.estimatedRemainingMs = -1
        }
        record.updatedAtMs = now
        self.emitTaskUpdate(record)
        transfer.lastEmitMs = now
        transfer.lastEmitBytes = transfer.currentBytes
      }
    }
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    stateQueue.async {
      guard let transfer = self.activeSessions.removeValue(forKey: task.taskIdentifier) else {
        return
      }
      self.taskIdToSessionTaskId.removeValue(forKey: transfer.taskId)
      try? transfer.fileHandle?.synchronize()
      try? transfer.fileHandle?.close()
      transfer.fileHandle = nil

      guard let record = self.tasks[transfer.taskId] else {
        self.scheduleQueueLocked()
        return
      }

      if transfer.stoppedIntentionally {
        self.scheduleQueueLocked()
        return
      }

      if let writeErr = transfer.writeError {
        self.failTaskLocked(
          record,
          code: "disk_error",
          message: writeErr,
          httpStatus: nil,
          recoverable: true
        )
        self.scheduleQueueLocked()
        return
      }

      let status = transfer.httpStatusCode
      if status != 0 && !(200...299).contains(status) {
        let recoverable = (status == 408 || status == 416 || status == 429 || (500...599).contains(status))
        self.handleRetryOrFailLocked(
          record,
          code: "http_error",
          message: "HTTP \(status)",
          httpStatus: status,
          recoverable: recoverable
        )
        self.scheduleQueueLocked()
        return
      }

      if let err = error {
        self.handleRetryOrFailLocked(
          record,
          code: "network_error",
          message: err.localizedDescription,
          httpStatus: status > 0 ? status : nil,
          recoverable: true
        )
        self.scheduleQueueLocked()
        return
      }

      let partURL = URL(fileURLWithPath: record.savePath + ".part")
      let destURL = URL(fileURLWithPath: record.savePath)

      if let expected = record.expectedChecksum, !expected.isEmpty {
        let computed = Self.computeChecksum(fileURL: partURL, algorithm: record.checksumAlgorithm)
        record.computedChecksum = computed
        if computed?.lowercased() != expected.lowercased() {
          try? FileManager.default.removeItem(at: partURL)
          self.failTaskLocked(
            record,
            code: "checksum_mismatch",
            message: "Checksum mismatch: expected \(expected), got \(computed ?? "nil")",
            httpStatus: nil,
            recoverable: false
          )
          self.scheduleQueueLocked()
          return
        }
      }

      do {
        if FileManager.default.fileExists(atPath: destURL.path) {
          try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: partURL, to: destURL)
      } catch {
        self.failTaskLocked(
          record,
          code: "disk_error",
          message: error.localizedDescription,
          httpStatus: nil,
          recoverable: false
        )
        self.scheduleQueueLocked()
        return
      }

      let finalSize =
        (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?
        .int64Value ?? transfer.currentBytes
      let now = Self.nowMs()
      record.downloadedBytes = finalSize
      if record.totalBytes <= 0 {
        record.totalBytes = finalSize
      }
      record.progress = 1.0
      record.bytesPerSecond = 0.0
      record.estimatedRemainingMs = 0
      record.status = "completed"
      record.error = nil
      record.updatedAtMs = now
      record.completedAtMs = now

      self.persistTasksLocked()
      self.emitTaskUpdate(record)
      self.postNotificationIfNeeded(for: record)
      self.scheduleQueueLocked()
    }
  }

  private func handleRetryOrFailLocked(
    _ record: TaskRecord,
    code: String,
    message: String,
    httpStatus: Int?,
    recoverable: Bool
  ) {
    if recoverable && record.retryCount < record.maxRetries {
      record.retryCount += 1
      record.status = "queued"
      record.updatedAtMs = Self.nowMs()
      emitTaskUpdate(record)
      let delaySeconds = min(3.0, 0.5 * Double(record.retryCount))
      stateQueue.asyncAfter(deadline: .now() + delaySeconds) {
        self.scheduleQueueLocked()
      }
      return
    }
    failTaskLocked(
      record,
      code: code,
      message: message,
      httpStatus: httpStatus,
      recoverable: recoverable
    )
  }

  private func failTaskLocked(
    _ record: TaskRecord,
    code: String,
    message: String,
    httpStatus: Int?,
    recoverable: Bool
  ) {
    record.status = "failed"
    record.bytesPerSecond = 0.0
    record.estimatedRemainingMs = -1
    record.error = ErrorRecord(
      code: code,
      message: message,
      httpStatusCode: httpStatus,
      isRecoverable: recoverable
    )
    record.updatedAtMs = Self.nowMs()
    persistTasksLocked()
    emitTaskUpdate(record)
    postNotificationIfNeeded(for: record)
  }

  private func emitTaskUpdate(_ record: TaskRecord) {
    let map = record.toMap()
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(map)
    }
  }

  // MARK: - Background Keep-Alive & Notifications

  private func updateBackgroundKeepAliveLocked() {
    let hasActive = !activeSessions.isEmpty
    if hasActive && backgroundActivity == nil {
      backgroundActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .idleSystemSleepDisabled],
        reason: "XueHuaBackgroundDownloader active downloads"
      )
    } else if !hasActive, let activity = backgroundActivity {
      ProcessInfo.processInfo.endActivity(activity)
      backgroundActivity = nil
    }
  }

  private func postNotificationIfNeeded(for record: TaskRecord) {
    guard enableNotifications && record.notificationConfig.enabled else { return }
    let content = UNMutableNotificationContent()
    content.title =
      (record.notificationConfig.title?.isEmpty == false)
      ? record.notificationConfig.title!
      : record.fileName

    switch record.status {
    case "completed":
      let tpl = record.notificationConfig.completedBody ?? "Download complete: {fileName}"
      content.body = tpl.replacingOccurrences(of: "{fileName}", with: record.fileName)
      content.sound = .default
    case "failed":
      let tpl = record.notificationConfig.failedBody ?? "Download failed: {fileName}"
      content.body = tpl.replacingOccurrences(of: "{fileName}", with: record.fileName)
    default:
      return
    }

    let request = UNNotificationRequest(
      identifier: "xue_hua_dl_\(record.taskId)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  // MARK: - Persistence

  private static func persistenceFileURL() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("xue_hua_background_downloader", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("tasks.json")
  }

  private func persistTasksLocked() {
    let array = tasks.values.map { $0.toMap() }
    guard JSONSerialization.isValidJSONObject(array),
      let data = try? JSONSerialization.data(withJSONObject: array, options: [])
    else {
      return
    }
    try? data.write(to: Self.persistenceFileURL(), options: .atomic)
  }

  private func loadPersistedTasks() {
    let url = Self.persistenceFileURL()
    guard let data = try? Data(contentsOf: url),
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return
    }
    for item in array {
      let record = TaskRecord(from: item)
      if record.status == "running" || record.status == "queued" {
        record.status = autoResumeOnStartup ? "queued" : "paused"
        record.bytesPerSecond = 0.0
        record.estimatedRemainingMs = -1
      }
      let partPath = record.savePath + ".part"
      if record.status != "completed",
        let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
        let size = attrs[.size] as? NSNumber
      {
        record.downloadedBytes = size.int64Value
        if record.totalBytes > 0 {
          record.progress = min(1.0, max(0.0, Double(record.downloadedBytes) / Double(record.totalBytes)))
        }
      }
      tasks[record.taskId] = record
    }
  }

  // MARK: - Helpers

  private static func defaultDownloadDirectory() -> URL {
    let docs =
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = docs.appendingPathComponent("XueHuaDownloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func sanitizeFileName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "download_\(nowMs()).bin" : cleaned
  }

  private static func inferFileName(from urlString: String) -> String {
    if let url = URL(string: urlString) {
      let last = url.lastPathComponent
      if !last.isEmpty && last != "/" {
        return sanitizeFileName(last)
      }
    }
    return "download_\(nowMs()).bin"
  }

  private static func resolveDestinationURL(
    dir: URL,
    fileName: String,
    conflictResolution: String
  ) -> URL {
    let initial = dir.appendingPathComponent(fileName)
    if conflictResolution != "uniqueName"
      || !FileManager.default.fileExists(atPath: initial.path)
    {
      return initial
    }
    let ext = initial.pathExtension
    let base = initial.deletingPathExtension().lastPathComponent
    var counter = 1
    while true {
      let candidateName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
      let candidate = dir.appendingPathComponent(candidateName)
      if !FileManager.default.fileExists(atPath: candidate.path)
        && !FileManager.default.fileExists(atPath: candidate.path + ".part")
      {
        return candidate
      }
      counter += 1
    }
  }

  private static func computeChecksum(fileURL: URL, algorithm: String) -> String? {
    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
    if algorithm.lowercased() == "md5" {
      let digest = Insecure.MD5.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    } else {
      let digest = SHA256.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  private static func priorityLevel(_ priority: String) -> Int {
    switch priority {
    case "critical": return 3
    case "high": return 2
    case "normal": return 1
    default: return 0
    }
  }

  private static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
  }
}

// MARK: - Internal Records

private final class ActiveTransfer {
  let taskId: String
  let dataTask: URLSessionDataTask
  let requestedOffset: Int64
  var fileHandle: FileHandle?
  var currentBytes: Int64 = 0
  var lastEmitBytes: Int64 = 0
  var lastEmitMs: Int64 = 0
  var smoothedSpeed: Double = 0.0
  var httpStatusCode: Int = 0
  var stoppedIntentionally: Bool = false
  var writeError: String?

  init(taskId: String, dataTask: URLSessionDataTask, requestedOffset: Int64) {
    self.taskId = taskId
    self.dataTask = dataTask
    self.requestedOffset = requestedOffset
  }
}

private struct NotificationConfigRecord {
  let enabled: Bool
  let title: String?
  let runningBody: String?
  let completedBody: String?
  let failedBody: String?
  let showProgress: Bool

  init(from map: [String: Any]?) {
    self.enabled = map?["enabled"] as? Bool ?? true
    self.title = map?["title"] as? String
    self.runningBody = map?["runningBody"] as? String
    self.completedBody = map?["completedBody"] as? String
    self.failedBody = map?["failedBody"] as? String
    self.showProgress = map?["showProgress"] as? Bool ?? true
  }

  func toMap() -> [String: Any?] {
    [
      "enabled": enabled,
      "title": title,
      "runningBody": runningBody,
      "completedBody": completedBody,
      "failedBody": failedBody,
      "showProgress": showProgress,
    ]
  }
}

private struct ErrorRecord {
  let code: String
  let message: String
  let httpStatusCode: Int?
  let isRecoverable: Bool

  init(code: String, message: String, httpStatusCode: Int?, isRecoverable: Bool) {
    self.code = code
    self.message = message
    self.httpStatusCode = httpStatusCode
    self.isRecoverable = isRecoverable
  }

  init?(from map: [String: Any]?) {
    guard let map = map else { return nil }
    self.code = map["code"] as? String ?? "unknown_error"
    self.message = map["message"] as? String ?? "Unknown error"
    self.httpStatusCode = map["httpStatusCode"] as? Int
    self.isRecoverable = map["isRecoverable"] as? Bool ?? true
  }

  func toMap() -> [String: Any?] {
    [
      "code": code,
      "message": message,
      "httpStatusCode": httpStatusCode,
      "isRecoverable": isRecoverable,
    ]
  }
}

private final class TaskRecord {
  let taskId: String
  let url: String
  let saveDirectory: String
  var fileName: String
  var savePath: String
  var status: String
  let group: String
  let priority: String
  let conflictResolution: String
  let method: String
  let postBody: String?
  var downloadedBytes: Int64
  var totalBytes: Int64
  var progress: Double
  var bytesPerSecond: Double
  var estimatedRemainingMs: Int64
  var retryCount: Int
  let maxRetries: Int
  var supportsResume: Bool
  let allowPause: Bool
  let requiresUnmeteredNetwork: Bool
  let expectedChecksum: String?
  let checksumAlgorithm: String
  var computedChecksum: String?
  var mimeType: String?
  var eTag: String?
  var error: ErrorRecord?
  let createdAtMs: Int64
  var updatedAtMs: Int64
  var completedAtMs: Int64?
  let headers: [String: String]
  let metadata: [String: String]
  let notificationConfig: NotificationConfigRecord

  init(
    taskId: String,
    url: String,
    saveDirectory: String,
    fileName: String,
    savePath: String,
    status: String,
    group: String,
    priority: String,
    conflictResolution: String,
    method: String,
    postBody: String?,
    downloadedBytes: Int64,
    totalBytes: Int64,
    progress: Double,
    bytesPerSecond: Double,
    estimatedRemainingMs: Int64,
    retryCount: Int,
    maxRetries: Int,
    supportsResume: Bool,
    allowPause: Bool,
    requiresUnmeteredNetwork: Bool,
    expectedChecksum: String?,
    checksumAlgorithm: String,
    computedChecksum: String?,
    mimeType: String?,
    eTag: String?,
    error: ErrorRecord?,
    createdAtMs: Int64,
    updatedAtMs: Int64,
    completedAtMs: Int64?,
    headers: [String: String],
    metadata: [String: String],
    notificationConfig: NotificationConfigRecord
  ) {
    self.taskId = taskId
    self.url = url
    self.saveDirectory = saveDirectory
    self.fileName = fileName
    self.savePath = savePath
    self.status = status
    self.group = group
    self.priority = priority
    self.conflictResolution = conflictResolution
    self.method = method
    self.postBody = postBody
    self.downloadedBytes = downloadedBytes
    self.totalBytes = totalBytes
    self.progress = progress
    self.bytesPerSecond = bytesPerSecond
    self.estimatedRemainingMs = estimatedRemainingMs
    self.retryCount = retryCount
    self.maxRetries = maxRetries
    self.supportsResume = supportsResume
    self.allowPause = allowPause
    self.requiresUnmeteredNetwork = requiresUnmeteredNetwork
    self.expectedChecksum = expectedChecksum
    self.checksumAlgorithm = checksumAlgorithm
    self.computedChecksum = computedChecksum
    self.mimeType = mimeType
    self.eTag = eTag
    self.error = error
    self.createdAtMs = createdAtMs
    self.updatedAtMs = updatedAtMs
    self.completedAtMs = completedAtMs
    self.headers = headers
    self.metadata = metadata
    self.notificationConfig = notificationConfig
  }

  convenience init(from map: [String: Any]) {
    let rawHeaders = map["headers"] as? [String: Any] ?? [:]
    var parsedHeaders: [String: String] = [:]
    for (k, v) in rawHeaders { parsedHeaders[k] = "\(v)" }

    let rawMeta = map["metadata"] as? [String: Any] ?? [:]
    var parsedMeta: [String: String] = [:]
    for (k, v) in rawMeta { parsedMeta[k] = "\(v)" }

    self.init(
      taskId: map["taskId"] as? String ?? UUID().uuidString,
      url: map["url"] as? String ?? "",
      saveDirectory: map["saveDirectory"] as? String ?? "",
      fileName: map["fileName"] as? String ?? "",
      savePath: map["savePath"] as? String ?? "",
      status: map["status"] as? String ?? "paused",
      group: map["group"] as? String ?? "default",
      priority: map["priority"] as? String ?? "normal",
      conflictResolution: map["conflictResolution"] as? String ?? "overwrite",
      method: map["method"] as? String ?? "GET",
      postBody: map["postBody"] as? String,
      downloadedBytes: (map["downloadedBytes"] as? NSNumber)?.int64Value ?? 0,
      totalBytes: (map["totalBytes"] as? NSNumber)?.int64Value ?? -1,
      progress: (map["progress"] as? NSNumber)?.doubleValue ?? 0.0,
      bytesPerSecond: 0.0,
      estimatedRemainingMs: -1,
      retryCount: map["retryCount"] as? Int ?? 0,
      maxRetries: map["maxRetries"] as? Int ?? 2,
      supportsResume: map["supportsResume"] as? Bool ?? true,
      allowPause: map["allowPause"] as? Bool ?? true,
      requiresUnmeteredNetwork: map["requiresUnmeteredNetwork"] as? Bool ?? false,
      expectedChecksum: map["expectedChecksum"] as? String,
      checksumAlgorithm: map["checksumAlgorithm"] as? String ?? "sha256",
      computedChecksum: map["computedChecksum"] as? String,
      mimeType: map["mimeType"] as? String,
      eTag: map["eTag"] as? String,
      error: ErrorRecord(from: map["error"] as? [String: Any]),
      createdAtMs: (map["createdAtMs"] as? NSNumber)?.int64Value ?? 0,
      updatedAtMs: (map["updatedAtMs"] as? NSNumber)?.int64Value ?? 0,
      completedAtMs: (map["completedAtMs"] as? NSNumber)?.int64Value,
      headers: parsedHeaders,
      metadata: parsedMeta,
      notificationConfig: NotificationConfigRecord(from: map["notificationConfig"] as? [String: Any])
    )
  }

  func toMap() -> [String: Any?] {
    [
      "taskId": taskId,
      "url": url,
      "saveDirectory": saveDirectory,
      "fileName": fileName,
      "savePath": savePath,
      "status": status,
      "group": group,
      "priority": priority,
      "conflictResolution": conflictResolution,
      "method": method,
      "postBody": postBody,
      "downloadedBytes": downloadedBytes,
      "totalBytes": totalBytes,
      "progress": progress,
      "bytesPerSecond": bytesPerSecond,
      "estimatedRemainingMs": estimatedRemainingMs,
      "retryCount": retryCount,
      "maxRetries": maxRetries,
      "supportsResume": supportsResume,
      "allowPause": allowPause,
      "requiresUnmeteredNetwork": requiresUnmeteredNetwork,
      "expectedChecksum": expectedChecksum,
      "checksumAlgorithm": checksumAlgorithm,
      "computedChecksum": computedChecksum,
      "mimeType": mimeType,
      "eTag": eTag,
      "error": error?.toMap(),
      "createdAtMs": createdAtMs,
      "updatedAtMs": updatedAtMs,
      "completedAtMs": completedAtMs,
      "headers": headers,
      "metadata": metadata,
      "notificationConfig": notificationConfig.toMap(),
    ]
  }
}
