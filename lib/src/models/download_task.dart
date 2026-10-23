import 'download_enums.dart';
import 'download_request.dart';

/// Structured error details when a [DownloadTask] fails.
class DownloadError {
  /// Creates a [DownloadError].
  const DownloadError({
    required this.code,
    required this.message,
    this.httpStatusCode,
    this.isRecoverable = true,
  });

  /// Machine-readable error code (e.g., `network_error`, `http_error`, `checksum_mismatch`, `file_exists`, `disk_error`).
  final String code;

  /// Human-readable diagnostic error message.
  final String message;

  /// Optional HTTP status code returned by the remote server.
  final int? httpStatusCode;

  /// Whether the failure can typically be recovered via `resume` or `retry`.
  final bool isRecoverable;

  /// Serializes this error to a map.
  Map<String, Object?> toMap() => <String, Object?>{
    'code': code,
    'message': message,
    'httpStatusCode': httpStatusCode,
    'isRecoverable': isRecoverable,
  };

  /// Deserializes a [DownloadError] from a platform channel map.
  factory DownloadError.fromMap(Map<Object?, Object?> map) {
    return DownloadError(
      code: map['code'] as String? ?? 'unknown_error',
      message: map['message'] as String? ?? 'Unknown download error',
      httpStatusCode: (map['httpStatusCode'] as num?)?.toInt(),
      isRecoverable: map['isRecoverable'] as bool? ?? true,
    );
  }

  @override
  String toString() =>
      'DownloadError(code: $code, httpStatusCode: $httpStatusCode, message: $message)';
}

/// Immutable snapshot of a download task managed by the native background downloader.
class DownloadTask {
  /// Creates a [DownloadTask] snapshot.
  const DownloadTask({
    required this.taskId,
    required this.url,
    required this.saveDirectory,
    required this.fileName,
    required this.savePath,
    required this.status,
    this.group = 'default',
    this.priority = DownloadPriority.normal,
    this.conflictResolution = DownloadConflictResolution.overwrite,
    this.downloadedBytes = 0,
    this.totalBytes = -1,
    this.progress = 0.0,
    this.bytesPerSecond = 0.0,
    this.estimatedRemainingMs = -1,
    this.retryCount = 0,
    this.maxRetries = 2,
    this.supportsResume = false,
    this.requiresUnmeteredNetwork = false,
    this.expectedChecksum,
    this.checksumAlgorithm = ChecksumAlgorithm.sha256,
    this.computedChecksum,
    this.mimeType,
    this.eTag,
    this.error,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.completedAtMs,
    this.headers = const <String, String>{},
    this.metadata = const <String, String>{},
    this.notificationConfig = const DownloadNotificationConfig(),
  });

  /// Unique task identifier.
  final String taskId;

  /// Remote source URL.
  final String url;

  /// Resolved directory where the file is being saved.
  final String saveDirectory;

  /// Resolved destination file name.
  final String fileName;

  /// Full destination file path (`saveDirectory/fileName`).
  final String savePath;

  /// Current lifecycle status of the download task.
  final DownloadStatus status;

  /// Logical group name assigned to this task.
  final String group;

  /// Queue scheduling priority.
  final DownloadPriority priority;

  /// File conflict resolution strategy.
  final DownloadConflictResolution conflictResolution;

  /// Number of bytes written to disk so far.
  final int downloadedBytes;

  /// Total expected file size in bytes, or `-1` if unknown (chunked transfer).
  final int totalBytes;

  /// Normalized download progress between `0.0` and `1.0`, or `-1.0` if indeterminate.
  final double progress;

  /// Smoothed current download speed in bytes per second.
  final double bytesPerSecond;

  /// Estimated remaining time in milliseconds, or `-1` if unknown.
  final int estimatedRemainingMs;

  /// Number of automatic retries attempted so far.
  final int retryCount;

  /// Maximum automatic retries configured for this task.
  final int maxRetries;

  /// Whether the server and task state currently support HTTP `Range` / resume data continuation.
  final bool supportsResume;

  /// Whether this task requires an unmetered network connection.
  final bool requiresUnmeteredNetwork;

  /// Expected checksum string if integrity verification was requested.
  final String? expectedChecksum;

  /// Checksum algorithm used for integrity verification.
  final ChecksumAlgorithm checksumAlgorithm;

  /// Actual checksum computed by the native downloader upon completion.
  final String? computedChecksum;

  /// Server-reported MIME type (`Content-Type`), if available.
  final String? mimeType;

  /// Server-reported `ETag` or `Last-Modified` validator for safe resumption.
  final String? eTag;

  /// Error details if [status] is [DownloadStatus.failed].
  final DownloadError? error;

  /// Epoch timestamp in milliseconds when the task was created.
  final int createdAtMs;

  /// Epoch timestamp in milliseconds when the task was last updated.
  final int updatedAtMs;

  /// Epoch timestamp in milliseconds when the task completed, if applicable.
  final int? completedAtMs;

  /// Custom HTTP headers associated with this task.
  final Map<String, String> headers;

  /// Arbitrary caller metadata persisted with this task.
  final Map<String, String> metadata;

  /// System notification configuration for this task.
  final DownloadNotificationConfig notificationConfig;

  /// Estimated remaining duration, or `null` if unknown or not running.
  Duration? get estimatedRemaining =>
      estimatedRemainingMs > 0 ? Duration(milliseconds: estimatedRemainingMs) : null;

  /// Created timestamp as a [DateTime].
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(createdAtMs);

  /// Last updated timestamp as a [DateTime].
  DateTime get updatedAt =>
      DateTime.fromMillisecondsSinceEpoch(updatedAtMs);

  /// Completed timestamp as a [DateTime], if completed.
  DateTime? get completedAt => completedAtMs != null && completedAtMs! > 0
      ? DateTime.fromMillisecondsSinceEpoch(completedAtMs!)
      : null;

  /// Deserializes a [DownloadTask] from a platform channel map.
  factory DownloadTask.fromMap(Map<Object?, Object?> map) {
    final rawError = map['error'];
    final rawHeaders = map['headers'];
    final rawMetadata = map['metadata'];
    final rawNotification = map['notificationConfig'];

    final downloaded = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
    final total = (map['totalBytes'] as num?)?.toInt() ?? -1;
    double rawProgress = (map['progress'] as num?)?.toDouble() ?? 0.0;
    if (rawProgress == 0.0 && total > 0 && downloaded > 0) {
      rawProgress = (downloaded / total).clamp(0.0, 1.0);
    }

    return DownloadTask(
      taskId: map['taskId'] as String? ?? '',
      url: map['url'] as String? ?? '',
      saveDirectory: map['saveDirectory'] as String? ?? '',
      fileName: map['fileName'] as String? ?? '',
      savePath: map['savePath'] as String? ?? '',
      status: DownloadStatus.fromWire(map['status'] as String?),
      group: map['group'] as String? ?? 'default',
      priority: DownloadPriority.fromWire(map['priority']),
      conflictResolution: DownloadConflictResolution.fromWire(
        map['conflictResolution'] as String?,
      ),
      downloadedBytes: downloaded,
      totalBytes: total,
      progress: rawProgress,
      bytesPerSecond: (map['bytesPerSecond'] as num?)?.toDouble() ?? 0.0,
      estimatedRemainingMs:
          (map['estimatedRemainingMs'] as num?)?.toInt() ?? -1,
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      maxRetries: (map['maxRetries'] as num?)?.toInt() ?? 2,
      supportsResume: map['supportsResume'] as bool? ?? false,
      requiresUnmeteredNetwork:
          map['requiresUnmeteredNetwork'] as bool? ?? false,
      expectedChecksum: map['expectedChecksum'] as String?,
      checksumAlgorithm: ChecksumAlgorithm.fromWire(
        map['checksumAlgorithm'] as String?,
      ),
      computedChecksum: map['computedChecksum'] as String?,
      mimeType: map['mimeType'] as String?,
      eTag: map['eTag'] as String?,
      error: rawError is Map<Object?, Object?>
          ? DownloadError.fromMap(rawError)
          : null,
      createdAtMs: (map['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ?? 0,
      completedAtMs: (map['completedAtMs'] as num?)?.toInt(),
      headers: rawHeaders is Map<Object?, Object?>
          ? rawHeaders.map(
              (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
            )
          : const <String, String>{},
      metadata: rawMetadata is Map<Object?, Object?>
          ? rawMetadata.map(
              (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
            )
          : const <String, String>{},
      notificationConfig: rawNotification is Map<Object?, Object?>
          ? DownloadNotificationConfig.fromMap(rawNotification)
          : const DownloadNotificationConfig(),
    );
  }

  /// Serializes this [DownloadTask] to a map.
  Map<String, Object?> toMap() => <String, Object?>{
    'taskId': taskId,
    'url': url,
    'saveDirectory': saveDirectory,
    'fileName': fileName,
    'savePath': savePath,
    'status': status.wireValue,
    'group': group,
    'priority': priority.wireValue,
    'conflictResolution': conflictResolution.wireValue,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'progress': progress,
    'bytesPerSecond': bytesPerSecond,
    'estimatedRemainingMs': estimatedRemainingMs,
    'retryCount': retryCount,
    'maxRetries': maxRetries,
    'supportsResume': supportsResume,
    'requiresUnmeteredNetwork': requiresUnmeteredNetwork,
    'expectedChecksum': expectedChecksum,
    'checksumAlgorithm': checksumAlgorithm.wireValue,
    'computedChecksum': computedChecksum,
    'mimeType': mimeType,
    'eTag': eTag,
    'error': error?.toMap(),
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'completedAtMs': completedAtMs,
    'headers': headers,
    'metadata': metadata,
    'notificationConfig': notificationConfig.toMap(),
  };
}
