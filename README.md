# xue_hua_navite_background_downloader

English | [简体中文](README_ZH.md)

A native multi-task background downloader plugin for Flutter across **Android, iOS, macOS, Windows, and Linux**. Built with pure native networking stacks on all 5 platforms, it provides priority-based concurrent task scheduling, local disk persistence across app restarts, HTTP `Range` (`206 Partial Content`) pause/resume, MD5/SHA-256 checksum verification, and built-in system progress notifications.

## Features

* **5-Platform Native Multi-Task Engine**:
  * **Android**: `HttpURLConnection` worker pool + `XueHuaDownloadForegroundService` (`dataSync`) + `NotificationManager`.
  * **iOS**: `URLSessionDataTask` streaming + `UIBackgroundTaskIdentifier` continuation + `UNUserNotificationCenter`.
  * **macOS**: `URLSessionDataTask` streaming + `NSProcessInfo` background activity assertion + `UNUserNotificationCenter`.
  * **Windows**: Native `WinHTTP` asynchronous streaming + Windows CNG (`BCrypt`) hashing + `Shell_NotifyIconW` system tray notifications.
  * **Linux**: `libcurl` (`CURLOPT_XFERINFOFUNCTION` + `CURLOPT_RESUME_FROM_LARGE`) + `GLib` (`GChecksum`) + `notify-send` desktop notifications.
* **Persistent Download Queue**: Automatically persists all task states to local disk and restores incomplete downloads on app restart.
* **True Pause & Resume**: Writes streaming data to `.part` partial files and resumes from the exact byte offset via `Range: bytes=<offset>-` and `If-Range` (`ETag`) headers.
* **Priority & Group Scheduling**: Schedule tasks with `critical`, `high`, `normal`, or `low` priority and manage batches by `group`.
* **File Conflict Strategies**: Choose between `overwrite`, `uniqueName` (`file (1).ext`), `skip`, or `fail`.
* **Integrity Verification**: Optional post-download `SHA-256` or `MD5` checksum verification.
* **AI Agent Package Skill**: Bundles a standard Dart package skill under [`skills/xue_hua_navite_background_downloader-usage/SKILL.md`](skills/xue_hua_navite_background_downloader-usage/SKILL.md) following [Ship skills with packages](https://dart.dev/tools/pub/package-skills).

## Platform Support Matrix

| Feature | Android | iOS | macOS | Windows | Linux |
| :--- | :---: | :---: | :---: | :---: | :---: |
| Multi-Task Priority Queue | ✅ | ✅ | ✅ | ✅ | ✅ |
| Disk Task Persistence | ✅ | ✅ | ✅ | ✅ | ✅ |
| HTTP `Range` Pause & Resume | ✅ | ✅ | ✅ | ✅ | ✅ |
| System Progress Notifications | ✅ | ✅ | ✅ | ✅ | ✅ |
| MD5 / SHA-256 Verification | ✅ | ✅ | ✅ | ✅ | ✅ |
| Unmetered Network Constraint | ✅ | ✅ | ✅ | ✅ | ✅ |

## Installation

Add `xue_hua_navite_background_downloader` to your `pubspec.yaml`:

```yaml
dependencies:
  xue_hua_navite_background_downloader: ^1.0.0
```

### Installing the Bundled AI Agent Skill

This package ships with an official AI coding agent skill ([Ship skills with packages](https://dart.dev/tools/pub/package-skills)). Run the following command in your project to install it:

```bash
dart run skills@ get
```

## Platform Configuration & Notes

### 1. Android

The plugin's `AndroidManifest.xml` automatically merges the required permissions (`INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS`, `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`) and registers `XueHuaDownloadForegroundService`.

* On **Android 13+ (API 33+)**, call `XueHuaNaviteBackgroundDownloader.instance.requestNotificationPermission()` at runtime before starting downloads if you want progress notifications to appear in the system notification shade.

### 2. iOS

* To allow downloads and notifications to operate smoothly when moving to the background, add the following to your host app's `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>processing</string>
</array>
```

* If downloading from plain HTTP URLs during development, configure `NSAppTransportSecurity` in `Info.plist`.

### 3. macOS

Enable outbound network access and Downloads folder read/write access in both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.files.downloads.read-write</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### 4. Windows

Uses native Win32 APIs (`winhttp.lib`, `bcrypt.lib`, `shell32.lib`, `ole32.lib`) linked automatically via `windows/CMakeLists.txt`. Full UTF-16 (`std::wstring`) path conversion is built in, so paths containing Chinese or Unicode characters work out of the box.

### 5. Linux

Requires `libcurl` and `gtk+-3.0` development headers when building on Linux:

```bash
sudo apt-get install libcurl4-openssl-dev libnotify-bin
```

## Quick Start

### 1. Initialize and Restore Persisted Tasks

```dart
import 'dart:async';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

final downloader = XueHuaNaviteBackgroundDownloader.instance;

Future<void> setupDownloader() async {
  // 1. Configure global concurrency and notification channel
  await downloader.configure(
    const DownloaderConfig(
      maxConcurrentTasks: 3,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000,
      progressUpdateIntervalMs: 250,
      enableNotifications: true,
      autoResumeOnStartup: false,
    ),
  );

  // 2. Request notification permission (Android 13+, iOS, macOS)
  await downloader.requestNotificationPermission();

  // 3. Query platform capabilities & default download directory
  final capabilities = await downloader.getCapabilities();
  print('Engine: ${capabilities.nativeEngine}');
  print('Default directory: ${capabilities.defaultDownloadDirectory}');

  // 4. Restore persisted tasks from previous app launch
  final persistedTasks = await downloader.getAllTasks();
  print('Restored ${persistedTasks.length} task(s)');
}
```

### 2. Enqueue Single or Batch Downloads

```dart
// Enqueue a single task
final task = await downloader.enqueue(
  const DownloadRequest(
    url: 'https://proof.ovh.net/files/10Mb.dat',
    saveDirectory: '', // Empty string uses the platform default download directory
    fileName: 'ovh_10mb.dat',
    group: 'media',
    priority: DownloadPriority.high,
    conflictResolution: DownloadConflictResolution.uniqueName,
    requiresUnmeteredNetwork: false,
    expectedChecksum: null, // Optional MD5 / SHA-256 hex string
    checksumAlgorithm: ChecksumAlgorithm.sha256,
    notificationConfig: DownloadNotificationConfig(
      enabled: true,
      runningBody: 'Downloading {fileName}: {progress}% ({speed})',
      completedBody: 'Download complete: {fileName}',
    ),
  ),
);

// Enqueue multiple tasks at once
final batchTasks = await downloader.enqueueAll([
  const DownloadRequest(
    url: 'https://proof.ovh.net/files/1Mb.dat',
    saveDirectory: '',
    fileName: 'patch_critical.dat',
    group: 'updates',
    priority: DownloadPriority.critical,
  ),
  const DownloadRequest(
    url: 'https://proof.ovh.net/files/10Mb.dat',
    saveDirectory: '',
    fileName: 'assets_normal.dat',
    group: 'updates',
    priority: DownloadPriority.normal,
  ),
]);
```

### 3. Listen to Real-Time Progress & Control Tasks

```dart
// Listen to all task updates (or use downloader.watchTask(taskId) / downloader.watchGroup(group))
final subscription = downloader.taskUpdates.listen((DownloadTask updated) {
  final pct = (updated.progress * 100).toStringAsFixed(1);
  print('${updated.fileName} [${updated.status.name}] $pct% - ${updated.bytesPerSecond} B/s');
});

// Single-task controls
await downloader.pause(task.taskId);
await downloader.resume(task.taskId);
await downloader.cancel(task.taskId, deletePartialFile: true);
await downloader.retry(task.taskId);
await downloader.removeTask(task.taskId, deleteFile: true);

// Batch controls
await downloader.pauseAll(group: 'updates');
await downloader.resumeAll(group: 'updates');
await downloader.cancelAll(group: 'updates');
await downloader.clearCompleted(deleteFiles: false);
```

## Example Project

See the full-featured example application in [`example/lib/main.dart`](example/lib/main.dart) for an interactive dashboard demonstrating:
* Dynamic concurrency slider (`1`–`8` concurrent tasks)
* 4-task priority batch queue demonstration
* Custom URL, file name, conflict resolution (`overwrite`, `uniqueName`, `skip`, `fail`), and `MD5` / `SHA-256` checksum verification
* Real-time progress bars, speed (`KB/s`, `MB/s`), ETA, and disk persistence across app restarts

## Author & Repository

* **Author**: Matkurban
* **Email**: [3496354336@qq.com](mailto:3496354336@qq.com)
* **Repository**: [https://github.com/Matkurban/xue_hua_navite_background_downloader](https://github.com/Matkurban/xue_hua_navite_background_downloader)
* **License**: [MIT License](LICENSE)
