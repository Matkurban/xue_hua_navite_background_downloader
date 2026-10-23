---
name: xue_hua_navite_background_downloader-usage
description: >-
  Use when the user is working with xue_hua_navite_background_downloader APIs to implement native multi-task background downloading, pause/resume via HTTP Range, persistent task queues across app restarts, checksum verification (MD5/SHA-256), and system progress notifications across Android, iOS, macOS, Windows, and Linux.
---

# xue_hua_navite_background_downloader Usage Guide

Provide idiomatic integration patterns, platform setup rules, and best practices for the `xue_hua_navite_background_downloader` Flutter plugin across Android, iOS, macOS, Windows, and Linux.

## Guidelines

* Always use the singleton `XueHuaNaviteBackgroundDownloader.instance` to configure global concurrency and manage download tasks.
* Call `configure(DownloaderConfig(...))` and `getAllTasks()` during application startup (`initState` or service initialization) to restore persisted tasks from local storage after an app restart.
* Call `requestNotificationPermission()` before enqueuing downloads if `enableNotifications: true` is used on Android 13+ (API 33+), iOS, or macOS.
* Subscribe to `XueHuaNaviteBackgroundDownloader.instance.taskUpdates` (or `watchTask(taskId)` / `watchGroup(group)`) to receive throttled real-time progress, speed (`bytesPerSecond`), and ETA (`estimatedRemaining`) updates, and always cancel the `StreamSubscription` in `dispose()`.
* Pass an empty string `''` for `saveDirectory` in `DownloadRequest` if you want the native engine to automatically resolve the platform's default download directory (inspectable via `getCapabilities()`).
* Use `DownloadConflictResolution.uniqueName` when downloading user-initiated files into shared directories so existing files are not silently overwritten.
* Provide `expectedChecksum` and `checksumAlgorithm` (`ChecksumAlgorithm.sha256` or `ChecksumAlgorithm.md5`) when downloading release binaries, firmware, or asset bundles that require integrity verification.

## Platform Setup Rules

* **Android**: `INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_DATA_SYNC` permissions along with `XueHuaDownloadForegroundService` are automatically merged from the plugin's `AndroidManifest.xml`. Call `requestNotificationPermission()` at runtime on Android 13+.
* **iOS**: Add `UIBackgroundModes` (`fetch`, `processing`) to `ios/Runner/Info.plist` if downloads should continue while the app is backgrounded.
* **macOS**: Ensure `com.apple.security.network.client` and `com.apple.security.files.downloads.read-write` (or `com.apple.security.files.user-selected.read-write`) are set to `true` in both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`.
* **Windows**: Uses native `WinHTTP` and `CNG BCrypt` (`winhttp.lib`, `bcrypt.lib`, `shell32.lib`, `ole32.lib`); no extra external DLLs are required.
* **Linux**: Uses `libcurl` and `GLib` (`GChecksum`). Ensure `libcurl4-openssl-dev` (or `libcurl-devel`) is installed on the build machine.

## Examples

### Initialize, restore persisted tasks, and listen to progress

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

class DownloadController {
  final _downloader = XueHuaNaviteBackgroundDownloader.instance;
  StreamSubscription<DownloadTask>? _subscription;

  Future<void> init() async {
    await _downloader.configure(
      const DownloaderConfig(
        maxConcurrentTasks: 3,
        connectTimeoutMs: 15000,
        readTimeoutMs: 30000,
        progressUpdateIntervalMs: 250,
        enableNotifications: true,
        autoResumeOnStartup: false,
      ),
    );

    await _downloader.requestNotificationPermission();

    // Restore persisted tasks from previous app sessions.
    final persistedTasks = await _downloader.getAllTasks();
    debugPrint('Restored ${persistedTasks.length} persisted tasks');

    _subscription = _downloader.taskUpdates.listen((task) {
      debugPrint(
        '[${task.fileName}] ${task.status.name} '
        '${(task.progress * 100).toStringAsFixed(1)}% '
        '(${task.bytesPerSecond.toStringAsFixed(0)} B/s)',
      );
    });
  }

  Future<DownloadTask> startDownload(String url) {
    return _downloader.enqueue(
      DownloadRequest(
        url: url,
        saveDirectory: '', // Uses platform default download directory
        priority: DownloadPriority.high,
        conflictResolution: DownloadConflictResolution.uniqueName,
        allowPause: true,
        notificationConfig: const DownloadNotificationConfig(
          enabled: true,
          runningBody: 'Downloading {fileName}: {progress}% ({speed})',
          completedBody: 'Finished downloading {fileName}',
        ),
      ),
    );
  }

  Future<void> pauseAndResume(String taskId) async {
    await _downloader.pause(taskId);
    // Later, resume from the exact byte offset (.part file + HTTP Range):
    await _downloader.resume(taskId);
  }

  void dispose() {
    _subscription?.cancel();
  }
}
```

### Batch multi-task queue with priority and SHA-256 verification

```dart
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

Future<void> enqueueReleaseAssets() async {
  final downloader = XueHuaNaviteBackgroundDownloader.instance;

  await downloader.enqueueAll([
    const DownloadRequest(
      url: 'https://proof.ovh.net/files/1Mb.dat',
      saveDirectory: '',
      fileName: 'patch_high_priority.dat',
      group: 'release_v1',
      priority: DownloadPriority.critical,
      conflictResolution: DownloadConflictResolution.overwrite,
    ),
    const DownloadRequest(
      url: 'https://proof.ovh.net/files/10Mb.dat',
      saveDirectory: '',
      fileName: 'bundle_normal.dat',
      group: 'release_v1',
      priority: DownloadPriority.normal,
      conflictResolution: DownloadConflictResolution.uniqueName,
    ),
  ]);

  // Manage an entire group at once:
  await downloader.pauseAll(group: 'release_v1');
  await downloader.resumeAll(group: 'release_v1');
}
```
