library;

export 'src/models/download_enums.dart';
export 'src/models/download_request.dart';
export 'src/models/download_task.dart';
export 'src/models/downloader_capabilities.dart';
export 'src/models/downloader_config.dart';
export 'xue_hua_navite_background_downloader_method_channel.dart';
export 'xue_hua_navite_background_downloader_platform_interface.dart';

import 'src/models/download_request.dart';
import 'src/models/download_task.dart';
import 'src/models/downloader_capabilities.dart';
import 'src/models/downloader_config.dart';
import 'xue_hua_navite_background_downloader_platform_interface.dart';

/// Native multi-task background downloader for Android, iOS, macOS, Windows, and Linux.
///
/// Use [XueHuaNaviteBackgroundDownloader.instance] to configure global concurrency,
/// enqueue single or batch downloads, pause/resume/cancel/retry tasks, query persisted
/// tasks across app restarts, and listen to real-time progress events via [taskUpdates].
class XueHuaNaviteBackgroundDownloader {
  /// Constructs a [XueHuaNaviteBackgroundDownloader] instance.
  ///
  /// Prefer using [XueHuaNaviteBackgroundDownloader.instance] for singleton access.
  XueHuaNaviteBackgroundDownloader();

  /// Shared singleton instance of [XueHuaNaviteBackgroundDownloader].
  static final XueHuaNaviteBackgroundDownloader instance =
      XueHuaNaviteBackgroundDownloader();

  XueHuaNaviteBackgroundDownloaderPlatform get _platform =>
      XueHuaNaviteBackgroundDownloaderPlatform.instance;

  /// Broadcast stream emitting [DownloadTask] snapshots whenever a task's status
  /// or download progress changes on the native platform.
  Stream<DownloadTask> get taskUpdates => _platform.taskUpdates;

  /// Returns a filtered stream of updates for a specific [taskId].
  Stream<DownloadTask> watchTask(String taskId) =>
      taskUpdates.where((task) => task.taskId == taskId);

  /// Returns a filtered stream of updates for a specific task [group].
  Stream<DownloadTask> watchGroup(String group) =>
      taskUpdates.where((task) => task.group == group);

  /// Configures global downloader parameters such as [DownloaderConfig.maxConcurrentTasks],
  /// timeouts, notification channel settings, and startup recovery behavior.
  Future<void> configure(DownloaderConfig config) {
    return _platform.configure(config);
  }

  /// Queries the current platform's native download capabilities, default directory,
  /// and [DownloaderCapabilities.taskStorePath].
  Future<DownloaderCapabilities> getCapabilities() {
    return _platform.getCapabilities();
  }

  /// Requests system notification permissions on platforms that require runtime user consent
  /// (Android 13+, iOS, and macOS). Returns `true` if notifications are authorized.
  Future<bool> requestNotificationPermission() {
    return _platform.requestNotificationPermission();
  }

  /// Enqueues a single [DownloadRequest] into the native priority queue.
  Future<DownloadTask> enqueue(DownloadRequest request) {
    if (request.url.trim().isEmpty) {
      throw ArgumentError.value(
        request.url,
        'request.url',
        'Download URL must not be empty.',
      );
    }
    return _platform.enqueue(request);
  }

  /// Enqueues multiple [DownloadRequest] items in a single batch call.
  Future<List<DownloadTask>> enqueueAll(List<DownloadRequest> requests) {
    if (requests.isEmpty) {
      return Future<List<DownloadTask>>.value(const <DownloadTask>[]);
    }
    for (final request in requests) {
      if (request.url.trim().isEmpty) {
        throw ArgumentError.value(
          request.url,
          'requests.url',
          'Download URL must not be empty.',
        );
      }
    }
    return _platform.enqueueAll(requests);
  }

  /// Pauses a running or queued download task by [taskId], keeping partial data on disk.
  Future<DownloadTask?> pause(String taskId) {
    return _platform.pause(taskId);
  }

  /// Resumes a paused download task by [taskId] using HTTP `Range` or native resume data.
  Future<DownloadTask?> resume(String taskId) {
    return _platform.resume(taskId);
  }

  /// Cancels a download task by [taskId] and optionally deletes its temporary `.part` file.
  Future<DownloadTask?> cancel(String taskId, {bool deletePartialFile = true}) {
    return _platform.cancel(taskId, deletePartialFile: deletePartialFile);
  }

  /// Retries a failed or canceled download task by [taskId].
  Future<DownloadTask?> retry(String taskId) {
    return _platform.retry(taskId);
  }

  /// Removes a task from the persistent task store (canceling it first if active)
  /// and optionally deletes the downloaded destination file when [deleteFile] is `true`.
  Future<bool> removeTask(String taskId, {bool deleteFile = false}) {
    return _platform.removeTask(taskId, deleteFile: deleteFile);
  }

  /// Pauses all running and queued tasks, optionally scoped to [group].
  Future<List<DownloadTask>> pauseAll({String? group}) {
    return _platform.pauseAll(group: group);
  }

  /// Resumes all paused tasks, optionally scoped to [group].
  Future<List<DownloadTask>> resumeAll({String? group}) {
    return _platform.resumeAll(group: group);
  }

  /// Cancels all active and paused tasks, optionally scoped to [group].
  Future<List<DownloadTask>> cancelAll({
    String? group,
    bool deletePartialFiles = true,
  }) {
    return _platform.cancelAll(
      group: group,
      deletePartialFiles: deletePartialFiles,
    );
  }

  /// Clears all completed tasks from the persistent store, optionally deleting their files.
  Future<int> clearCompleted({String? group, bool deleteFiles = false}) {
    return _platform.clearCompleted(group: group, deleteFiles: deleteFiles);
  }

  /// Returns the latest snapshot of a task by [taskId], or `null` if not found.
  Future<DownloadTask?> getTask(String taskId) {
    return _platform.getTask(taskId);
  }

  /// Returns all persisted and active download tasks, optionally filtered by [group].
  Future<List<DownloadTask>> getAllTasks({String? group}) {
    return _platform.getAllTasks(group: group);
  }
}
