import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/models/download_request.dart';
import 'src/models/download_task.dart';
import 'src/models/downloader_capabilities.dart';
import 'src/models/downloader_config.dart';
import 'xue_hua_navite_background_downloader_method_channel.dart';

/// The interface that platform-specific implementations of
/// `xue_hua_navite_background_downloader` must extend.
abstract class XueHuaNaviteBackgroundDownloaderPlatform
    extends PlatformInterface {
  /// Constructs a [XueHuaNaviteBackgroundDownloaderPlatform].
  XueHuaNaviteBackgroundDownloaderPlatform() : super(token: _token);

  static final Object _token = Object();

  static XueHuaNaviteBackgroundDownloaderPlatform _instance =
      MethodChannelXueHuaNaviteBackgroundDownloader();

  /// The default instance of [XueHuaNaviteBackgroundDownloaderPlatform] to use.
  ///
  /// Defaults to [MethodChannelXueHuaNaviteBackgroundDownloader].
  static XueHuaNaviteBackgroundDownloaderPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [XueHuaNaviteBackgroundDownloaderPlatform]
  /// when they register themselves.
  static set instance(XueHuaNaviteBackgroundDownloaderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Broadcast stream of real-time [DownloadTask] state and progress updates.
  Stream<DownloadTask> get taskUpdates {
    throw UnimplementedError('taskUpdates has not been implemented.');
  }

  /// Applies global [DownloaderConfig] settings to the native download manager.
  Future<void> configure(DownloaderConfig config) {
    throw UnimplementedError('configure() has not been implemented.');
  }

  /// Queries the active platform's native downloader capabilities and default directory.
  Future<DownloaderCapabilities> getCapabilities() {
    throw UnimplementedError('getCapabilities() has not been implemented.');
  }

  /// Requests system notification permission if required by the host OS (Android 13+, iOS, macOS).
  Future<bool> requestNotificationPermission() {
    throw UnimplementedError(
      'requestNotificationPermission() has not been implemented.',
    );
  }

  /// Enqueues a single [DownloadRequest] and returns its initial [DownloadTask] snapshot.
  Future<DownloadTask> enqueue(DownloadRequest request) {
    throw UnimplementedError('enqueue() has not been implemented.');
  }

  /// Enqueues multiple [DownloadRequest] items in a single batch and returns their initial [DownloadTask] snapshots.
  Future<List<DownloadTask>> enqueueAll(List<DownloadRequest> requests) {
    throw UnimplementedError('enqueueAll() has not been implemented.');
  }

  /// Pauses an active or queued download task by [taskId], preserving partial bytes on disk.
  Future<DownloadTask?> pause(String taskId) {
    throw UnimplementedError('pause() has not been implemented.');
  }

  /// Resumes a paused download task by [taskId] from its saved byte offset or resume data.
  Future<DownloadTask?> resume(String taskId) {
    throw UnimplementedError('resume() has not been implemented.');
  }

  /// Cancels a download task by [taskId] and optionally removes its partial `.part` file.
  Future<DownloadTask?> cancel(String taskId, {bool deletePartialFile = true}) {
    throw UnimplementedError('cancel() has not been implemented.');
  }

  /// Retries a failed or canceled download task by [taskId].
  Future<DownloadTask?> retry(String taskId) {
    throw UnimplementedError('retry() has not been implemented.');
  }

  /// Removes a task record from the persisted queue (canceling it first if active).
  Future<bool> removeTask(String taskId, {bool deleteFile = false}) {
    throw UnimplementedError('removeTask() has not been implemented.');
  }

  /// Pauses all currently queued or running tasks.
  Future<List<DownloadTask>> pauseAll({String? group}) {
    throw UnimplementedError('pauseAll() has not been implemented.');
  }

  /// Resumes all currently paused tasks.
  Future<List<DownloadTask>> resumeAll({String? group}) {
    throw UnimplementedError('resumeAll() has not been implemented.');
  }

  /// Cancels all active and paused tasks.
  Future<List<DownloadTask>> cancelAll({
    String? group,
    bool deletePartialFiles = true,
  }) {
    throw UnimplementedError('cancelAll() has not been implemented.');
  }

  /// Removes all completed tasks from the persisted task store.
  Future<int> clearCompleted({String? group, bool deleteFiles = false}) {
    throw UnimplementedError('clearCompleted() has not been implemented.');
  }

  /// Retrieves the current snapshot of a specific task by [taskId].
  Future<DownloadTask?> getTask(String taskId) {
    throw UnimplementedError('getTask() has not been implemented.');
  }

  /// Retrieves all persisted and active download tasks, optionally filtered by [group].
  Future<List<DownloadTask>> getAllTasks({String? group}) {
    throw UnimplementedError('getAllTasks() has not been implemented.');
  }
}
