/// Download lifecycle status for a [DownloadTask].
enum DownloadStatus {
  /// The task is waiting in the queue for an available concurrency slot.
  queued('queued'),

  /// The task is actively downloading data.
  running('running'),

  /// The task has been paused and its partial progress is preserved on disk.
  paused('paused'),

  /// The task has finished downloading (and passed checksum verification if configured).
  completed('completed'),

  /// The task encountered an error during download or verification.
  failed('failed'),

  /// The task was explicitly canceled by the caller.
  canceled('canceled');

  const DownloadStatus(this.wireValue);

  /// Wire string value exchanged over the platform channel.
  final String wireValue;

  /// Parses a [DownloadStatus] from its platform channel string representation.
  static DownloadStatus fromWire(String? value) {
    for (final status in DownloadStatus.values) {
      if (status.wireValue == value) {
        return status;
      }
    }
    return DownloadStatus.queued;
  }

  /// Whether the task is in a terminal state ([completed], [failed], or [canceled]).
  bool get isTerminal =>
      this == DownloadStatus.completed ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.canceled;

  /// Whether the task is currently active ([queued] or [running]).
  bool get isActive =>
      this == DownloadStatus.queued || this == DownloadStatus.running;
}

/// Scheduling priority for a download task in the multi-task queue.
enum DownloadPriority {
  /// Lowest scheduling priority.
  low(0, 'low'),

  /// Default scheduling priority.
  normal(1, 'normal'),

  /// High scheduling priority, dequeued before [normal] and [low].
  high(2, 'high'),

  /// Highest scheduling priority, dequeued first when a worker slot opens.
  critical(3, 'critical');

  const DownloadPriority(this.level, this.wireValue);

  /// Numeric priority level used for queue ordering.
  final int level;

  /// Wire string value exchanged over the platform channel.
  final String wireValue;

  /// Parses a [DownloadPriority] from its wire representation or integer level.
  static DownloadPriority fromWire(Object? value) {
    if (value is int) {
      for (final p in DownloadPriority.values) {
        if (p.level == value) return p;
      }
    }
    if (value is String) {
      for (final p in DownloadPriority.values) {
        if (p.wireValue == value) return p;
      }
    }
    return DownloadPriority.normal;
  }
}

/// Strategy for handling an existing destination file at the target path.
enum DownloadConflictResolution {
  /// Replace the existing destination file when the download completes.
  overwrite('overwrite'),

  /// Append a numeric suffix such as `filename (1).ext` to avoid overwriting.
  uniqueName('uniqueName'),

  /// Skip downloading and immediately mark the task as completed if the target file exists.
  skip('skip'),

  /// Fail the download task if the target file already exists.
  fail('fail');

  const DownloadConflictResolution(this.wireValue);

  /// Wire string value exchanged over the platform channel.
  final String wireValue;

  /// Parses a [DownloadConflictResolution] from its wire string.
  static DownloadConflictResolution fromWire(String? value) {
    for (final mode in DownloadConflictResolution.values) {
      if (mode.wireValue == value) return mode;
    }
    return DownloadConflictResolution.overwrite;
  }
}

/// Supported cryptographic hash algorithms for post-download file integrity verification.
enum ChecksumAlgorithm {
  /// MD5 message-digest algorithm (32-character hex string).
  md5('md5'),

  /// SHA-256 cryptographic hash algorithm (64-character hex string).
  sha256('sha256');

  const ChecksumAlgorithm(this.wireValue);

  /// Wire string value exchanged over the platform channel.
  final String wireValue;

  /// Parses a [ChecksumAlgorithm] from its wire string.
  static ChecksumAlgorithm fromWire(String? value) {
    for (final algo in ChecksumAlgorithm.values) {
      if (algo.wireValue.toLowerCase() == value?.toLowerCase()) {
        return algo;
      }
    }
    return ChecksumAlgorithm.sha256;
  }
}

/// HTTP request method used for a download task.
enum DownloadHttpMethod {
  /// Standard HTTP GET request.
  get('GET'),

  /// HTTP POST request with an optional request body.
  post('POST');

  const DownloadHttpMethod(this.wireValue);

  /// Wire string value exchanged over the platform channel.
  final String wireValue;

  /// Parses a [DownloadHttpMethod] from its wire string.
  static DownloadHttpMethod fromWire(String? value) {
    if (value?.toUpperCase() == 'POST') {
      return DownloadHttpMethod.post;
    }
    return DownloadHttpMethod.get;
  }
}
