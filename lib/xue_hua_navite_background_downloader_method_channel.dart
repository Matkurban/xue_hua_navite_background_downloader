import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/models/download_request.dart';
import 'src/models/download_task.dart';
import 'src/models/downloader_capabilities.dart';
import 'src/models/downloader_config.dart';
import 'xue_hua_navite_background_downloader_platform_interface.dart';

/// An implementation of [XueHuaNaviteBackgroundDownloaderPlatform] that uses
/// a [MethodChannel] for commands and an [EventChannel] for real-time task updates.
class MethodChannelXueHuaNaviteBackgroundDownloader
    extends XueHuaNaviteBackgroundDownloaderPlatform {
  /// The method channel used to invoke native downloader operations.
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    'com.kurban.xue_hua_navite_background_downloader/methods',
  );

  /// The event channel used to receive real-time [DownloadTask] updates from native code.
  @visibleForTesting
  final EventChannel eventChannel = const EventChannel(
    'com.kurban.xue_hua_navite_background_downloader/events',
  );

  Stream<DownloadTask>? _taskUpdatesStream;

  @override
  Stream<DownloadTask> get taskUpdates {
    _taskUpdatesStream ??= eventChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      if (event is Map<Object?, Object?>) {
        return DownloadTask.fromMap(event);
      }
      throw FormatException('Unexpected download event payload: $event');
    });
    return _taskUpdatesStream!;
  }

  @override
  Future<void> configure(DownloaderConfig config) async {
    await methodChannel.invokeMethod<void>('configure', config.toMap());
  }

  @override
  Future<DownloaderCapabilities> getCapabilities() async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getCapabilities',
    );
    if (map == null) {
      throw PlatformException(
        code: 'null_capabilities',
        message: 'Native platform returned null capabilities.',
      );
    }
    return DownloaderCapabilities.fromMap(map);
  }

  @override
  Future<bool> requestNotificationPermission() async {
    final granted = await methodChannel.invokeMethod<bool>(
      'requestNotificationPermission',
    );
    return granted ?? false;
  }

  @override
  Future<DownloadTask> enqueue(DownloadRequest request) async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'enqueue',
      request.toMap(),
    );
    if (map == null) {
      throw PlatformException(
        code: 'enqueue_failed',
        message: 'Native platform returned null task on enqueue.',
      );
    }
    return DownloadTask.fromMap(map);
  }

  @override
  Future<List<DownloadTask>> enqueueAll(List<DownloadRequest> requests) async {
    final list = await methodChannel.invokeListMethod<Object?>(
      'enqueueAll',
      <String, Object?>{'requests': requests.map((r) => r.toMap()).toList()},
    );
    return _parseTaskList(list);
  }

  @override
  Future<DownloadTask?> pause(String taskId) async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'pause',
      <String, Object?>{'taskId': taskId},
    );
    return map != null ? DownloadTask.fromMap(map) : null;
  }

  @override
  Future<DownloadTask?> resume(String taskId) async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'resume',
      <String, Object?>{'taskId': taskId},
    );
    return map != null ? DownloadTask.fromMap(map) : null;
  }

  @override
  Future<DownloadTask?> cancel(
    String taskId, {
    bool deletePartialFile = true,
  }) async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'cancel',
      <String, Object?>{
        'taskId': taskId,
        'deletePartialFile': deletePartialFile,
      },
    );
    return map != null ? DownloadTask.fromMap(map) : null;
  }

  @override
  Future<DownloadTask?> retry(String taskId) async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'retry',
      <String, Object?>{'taskId': taskId},
    );
    return map != null ? DownloadTask.fromMap(map) : null;
  }

  @override
  Future<bool> removeTask(String taskId, {bool deleteFile = false}) async {
    final removed = await methodChannel.invokeMethod<bool>(
      'removeTask',
      <String, Object?>{'taskId': taskId, 'deleteFile': deleteFile},
    );
    return removed ?? false;
  }

  @override
  Future<List<DownloadTask>> pauseAll({String? group}) async {
    final list = await methodChannel.invokeListMethod<Object?>(
      'pauseAll',
      <String, Object?>{'group': group},
    );
    return _parseTaskList(list);
  }

  @override
  Future<List<DownloadTask>> resumeAll({String? group}) async {
    final list = await methodChannel.invokeListMethod<Object?>(
      'resumeAll',
      <String, Object?>{'group': group},
    );
    return _parseTaskList(list);
  }

  @override
  Future<List<DownloadTask>> cancelAll({
    String? group,
    bool deletePartialFiles = true,
  }) async {
    final list = await methodChannel.invokeListMethod<Object?>(
      'cancelAll',
      <String, Object?>{
        'group': group,
        'deletePartialFiles': deletePartialFiles,
      },
    );
    return _parseTaskList(list);
  }

  @override
  Future<int> clearCompleted({String? group, bool deleteFiles = false}) async {
    final count = await methodChannel.invokeMethod<int>(
      'clearCompleted',
      <String, Object?>{'group': group, 'deleteFiles': deleteFiles},
    );
    return count ?? 0;
  }

  @override
  Future<DownloadTask?> getTask(String taskId) async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getTask',
      <String, Object?>{'taskId': taskId},
    );
    return map != null ? DownloadTask.fromMap(map) : null;
  }

  @override
  Future<List<DownloadTask>> getAllTasks({String? group}) async {
    final list = await methodChannel.invokeListMethod<Object?>(
      'getAllTasks',
      <String, Object?>{'group': group},
    );
    return _parseTaskList(list);
  }

  List<DownloadTask> _parseTaskList(List<Object?>? rawList) {
    if (rawList == null) return const <DownloadTask>[];
    return rawList
        .whereType<Map<Object?, Object?>>()
        .map(DownloadTask.fromMap)
        .toList();
  }
}
