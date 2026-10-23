/// Describes the native capabilities of the active host platform's downloader engine.
class DownloaderCapabilities {
  /// Creates a [DownloaderCapabilities] snapshot.
  const DownloaderCapabilities({
    required this.platform,
    required this.nativeEngine,
    required this.supportsBackgroundExecution,
    required this.supportsPauseResume,
    required this.supportsSystemNotifications,
    required this.supportsPersistence,
    required this.supportsChecksumVerification,
    required this.supportsNetworkConstraints,
    required this.defaultDownloadDirectory,
  });

  /// Platform identifier (`android`, `ios`, `macos`, `windows`, or `linux`).
  final String platform;

  /// Description of the underlying native HTTP/download engine (e.g., `URLSession`, `HttpURLConnection + ForegroundService`, `WinHTTP`, `libcurl + GLib`).
  final String nativeEngine;

  /// Whether the platform supports continuing downloads in the background when the app is minimized or suspended.
  final bool supportsBackgroundExecution;

  /// Whether the platform supports pausing and resuming downloads via HTTP `Range` or native resume data.
  final bool supportsPauseResume;

  /// Whether the platform supports displaying native system notifications for download progress and completion.
  final bool supportsSystemNotifications;

  /// Whether tasks are persisted to local storage across application restarts.
  final bool supportsPersistence;

  /// Whether native MD5 and SHA-256 checksum verification is supported.
  final bool supportsChecksumVerification;

  /// Whether unmetered network (Wi-Fi / Ethernet) checks are supported.
  final bool supportsNetworkConstraints;

  /// Default directory path used by the native platform when `saveDirectory` is empty.
  final String defaultDownloadDirectory;

  /// Deserializes [DownloaderCapabilities] from a platform channel map.
  factory DownloaderCapabilities.fromMap(Map<Object?, Object?> map) {
    return DownloaderCapabilities(
      platform: map['platform'] as String? ?? 'unknown',
      nativeEngine: map['nativeEngine'] as String? ?? 'unknown',
      supportsBackgroundExecution:
          map['supportsBackgroundExecution'] as bool? ?? true,
      supportsPauseResume: map['supportsPauseResume'] as bool? ?? true,
      supportsSystemNotifications:
          map['supportsSystemNotifications'] as bool? ?? true,
      supportsPersistence: map['supportsPersistence'] as bool? ?? true,
      supportsChecksumVerification:
          map['supportsChecksumVerification'] as bool? ?? true,
      supportsNetworkConstraints:
          map['supportsNetworkConstraints'] as bool? ?? true,
      defaultDownloadDirectory:
          map['defaultDownloadDirectory'] as String? ?? '',
    );
  }

  /// Serializes [DownloaderCapabilities] to a map.
  Map<String, Object?> toMap() => <String, Object?>{
    'platform': platform,
    'nativeEngine': nativeEngine,
    'supportsBackgroundExecution': supportsBackgroundExecution,
    'supportsPauseResume': supportsPauseResume,
    'supportsSystemNotifications': supportsSystemNotifications,
    'supportsPersistence': supportsPersistence,
    'supportsChecksumVerification': supportsChecksumVerification,
    'supportsNetworkConstraints': supportsNetworkConstraints,
    'defaultDownloadDirectory': defaultDownloadDirectory,
  };
}
