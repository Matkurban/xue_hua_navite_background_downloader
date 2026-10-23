import 'download_enums.dart';

/// Configuration for per-task system notification display.
class DownloadNotificationConfig {
  /// Creates a notification configuration for a download task.
  const DownloadNotificationConfig({
    this.enabled = true,
    this.title,
    this.runningBody,
    this.completedBody,
    this.failedBody,
    this.showProgress = true,
  });

  /// Whether system notifications should be displayed for this task.
  final bool enabled;

  /// Custom notification title (defaults to the file name if omitted).
  final String? title;

  /// Custom notification body template while downloading.
  ///
  /// Supports `{progress}`, `{speed}`, and `{fileName}` placeholders on native platforms.
  final String? runningBody;

  /// Custom notification body displayed when the download completes.
  final String? completedBody;

  /// Custom notification body displayed when the download fails.
  final String? failedBody;

  /// Whether to show a determinate progress bar in the system notification when supported.
  final bool showProgress;

  /// Converts this configuration to a platform channel map.
  Map<String, Object?> toMap() => <String, Object?>{
    'enabled': enabled,
    'title': title,
    'runningBody': runningBody,
    'completedBody': completedBody,
    'failedBody': failedBody,
    'showProgress': showProgress,
  };

  /// Restores a [DownloadNotificationConfig] from a platform channel map.
  factory DownloadNotificationConfig.fromMap(Map<Object?, Object?>? map) {
    if (map == null) {
      return const DownloadNotificationConfig();
    }
    return DownloadNotificationConfig(
      enabled: map['enabled'] as bool? ?? true,
      title: map['title'] as String?,
      runningBody: map['runningBody'] as String?,
      completedBody: map['completedBody'] as String?,
      failedBody: map['failedBody'] as String?,
      showProgress: map['showProgress'] as bool? ?? true,
    );
  }
}

/// Describes a new download request to be scheduled by the native downloader.
class DownloadRequest {
  /// Creates a new [DownloadRequest].
  const DownloadRequest({
    required this.url,
    required this.saveDirectory,
    this.fileName,
    this.taskId,
    this.group = 'default',
    this.headers = const <String, String>{},
    this.method = DownloadHttpMethod.get,
    this.postBody,
    this.priority = DownloadPriority.normal,
    this.conflictResolution = DownloadConflictResolution.overwrite,
    this.requiresUnmeteredNetwork = false,
    this.allowPause = true,
    this.expectedChecksum,
    this.checksumAlgorithm = ChecksumAlgorithm.sha256,
    this.maxRetries = 2,
    this.notificationConfig = const DownloadNotificationConfig(),
    this.metadata = const <String, String>{},
  });

  /// Remote HTTP or HTTPS URL of the file to download.
  final String url;

  /// Absolute directory path where the downloaded file should be stored.
  ///
  /// If an empty string is passed, the native platform resolves the system
  /// application documents/downloads directory automatically.
  final String saveDirectory;

  /// Optional target file name.
  ///
  /// When omitted, the native downloader infers the file name from the
  /// `Content-Disposition` header or the last segment of [url].
  final String? fileName;

  /// Optional caller-supplied unique task identifier.
  ///
  /// When omitted, a deterministic or UUID-based identifier is generated natively.
  final String? taskId;

  /// Logical group name for organizing and filtering related tasks.
  final String group;

  /// Custom HTTP request headers (for example, `Authorization` or `User-Agent`).
  final Map<String, String> headers;

  /// HTTP request method (`GET` or `POST`).
  final DownloadHttpMethod method;

  /// Optional UTF-8 body payload when [method] is [DownloadHttpMethod.post].
  final String? postBody;

  /// Queue scheduling priority for this download task.
  final DownloadPriority priority;

  /// Conflict resolution policy if the destination file already exists.
  final DownloadConflictResolution conflictResolution;

  /// Whether the download should only proceed over unmetered (Wi-Fi / Ethernet) networks.
  final bool requiresUnmeteredNetwork;

  /// Whether the task supports pausing and resuming with partial `.part` files.
  final bool allowPause;

  /// Optional expected hexadecimal checksum for post-download file integrity verification.
  final String? expectedChecksum;

  /// Checksum algorithm used when [expectedChecksum] is non-null.
  final ChecksumAlgorithm checksumAlgorithm;

  /// Number of automatic retries on transient network errors before failing.
  final int maxRetries;

  /// System notification settings for this download task.
  final DownloadNotificationConfig notificationConfig;

  /// Arbitrary key-value metadata persisted alongside the task.
  final Map<String, String> metadata;

  /// Creates a copy of this request with selectively overridden fields.
  DownloadRequest copyWith({
    String? url,
    String? saveDirectory,
    String? fileName,
    String? taskId,
    String? group,
    Map<String, String>? headers,
    DownloadHttpMethod? method,
    String? postBody,
    DownloadPriority? priority,
    DownloadConflictResolution? conflictResolution,
    bool? requiresUnmeteredNetwork,
    bool? allowPause,
    String? expectedChecksum,
    ChecksumAlgorithm? checksumAlgorithm,
    int? maxRetries,
    DownloadNotificationConfig? notificationConfig,
    Map<String, String>? metadata,
  }) {
    return DownloadRequest(
      url: url ?? this.url,
      saveDirectory: saveDirectory ?? this.saveDirectory,
      fileName: fileName ?? this.fileName,
      taskId: taskId ?? this.taskId,
      group: group ?? this.group,
      headers: headers ?? this.headers,
      method: method ?? this.method,
      postBody: postBody ?? this.postBody,
      priority: priority ?? this.priority,
      conflictResolution: conflictResolution ?? this.conflictResolution,
      requiresUnmeteredNetwork:
          requiresUnmeteredNetwork ?? this.requiresUnmeteredNetwork,
      allowPause: allowPause ?? this.allowPause,
      expectedChecksum: expectedChecksum ?? this.expectedChecksum,
      checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
      maxRetries: maxRetries ?? this.maxRetries,
      notificationConfig: notificationConfig ?? this.notificationConfig,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Serializes this [DownloadRequest] into a platform channel map.
  Map<String, Object?> toMap() => <String, Object?>{
    'url': url,
    'saveDirectory': saveDirectory,
    'fileName': fileName,
    'taskId': taskId,
    'group': group,
    'headers': headers,
    'method': method.wireValue,
    'postBody': postBody,
    'priority': priority.wireValue,
    'conflictResolution': conflictResolution.wireValue,
    'requiresUnmeteredNetwork': requiresUnmeteredNetwork,
    'allowPause': allowPause,
    'expectedChecksum': expectedChecksum,
    'checksumAlgorithm': checksumAlgorithm.wireValue,
    'maxRetries': maxRetries,
    'notificationConfig': notificationConfig.toMap(),
    'metadata': metadata,
  };
}
