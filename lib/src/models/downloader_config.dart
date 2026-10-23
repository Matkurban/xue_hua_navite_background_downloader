/// Global configuration for the native multi-task background downloader.
class DownloaderConfig {
  /// Creates a [DownloaderConfig].
  const DownloaderConfig({
    this.maxConcurrentTasks = 3,
    this.connectTimeoutMs = 15000,
    this.readTimeoutMs = 30000,
    this.progressUpdateIntervalMs = 250,
    this.enableNotifications = true,
    this.notificationChannelId = 'xue_hua_background_downloader',
    this.notificationChannelName = 'Background Downloads',
    this.userAgent = 'XueHuaNativeBackgroundDownloader/1.0.0',
    this.defaultHeaders = const <String, String>{},
    this.autoResumeOnStartup = false,
  });

  /// Maximum number of download tasks allowed to run simultaneously (`1`–`16`).
  final int maxConcurrentTasks;

  /// Connection establishment timeout in milliseconds.
  final int connectTimeoutMs;

  /// Socket read / inactivity timeout in milliseconds.
  final int readTimeoutMs;

  /// Minimum interval in milliseconds between progress event emissions per task.
  final int progressUpdateIntervalMs;

  /// Master switch enabling or disabling native system progress notifications.
  final bool enableNotifications;

  /// Notification channel identifier used on Android 8.0+ (API 26+).
  final String notificationChannelId;

  /// Human-readable notification channel name used on Android 8.0+ (API 26+).
  final String notificationChannelName;

  /// Default HTTP `User-Agent` header when not overridden by a task.
  final String userAgent;

  /// Default HTTP headers merged into every [DownloadRequest].
  final Map<String, String> defaultHeaders;

  /// Whether interrupted `running` tasks persisted on disk should automatically resume on startup.
  ///
  /// When `false` (default), interrupted `running` tasks are restored in the `paused` state
  /// so the application can inspect or resume them explicitly.
  final bool autoResumeOnStartup;

  /// Serializes this configuration to a platform channel map.
  Map<String, Object?> toMap() => <String, Object?>{
    'maxConcurrentTasks': maxConcurrentTasks,
    'connectTimeoutMs': connectTimeoutMs,
    'readTimeoutMs': readTimeoutMs,
    'progressUpdateIntervalMs': progressUpdateIntervalMs,
    'enableNotifications': enableNotifications,
    'notificationChannelId': notificationChannelId,
    'notificationChannelName': notificationChannelName,
    'userAgent': userAgent,
    'defaultHeaders': defaultHeaders,
    'autoResumeOnStartup': autoResumeOnStartup,
  };
}
