import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

class FakeXueHuaBackgroundDownloaderPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteBackgroundDownloaderPlatform {
  final StreamController<DownloadTask> controller =
      StreamController<DownloadTask>.broadcast();
  final Map<String, DownloadTask> store = <String, DownloadTask>{};
  DownloaderConfig? lastConfig;

  @override
  Stream<DownloadTask> get taskUpdates => controller.stream;

  @override
  Future<void> configure(DownloaderConfig config) async {
    lastConfig = config;
  }

  @override
  Future<DownloaderCapabilities> getCapabilities() async {
    return const DownloaderCapabilities(
      platform: 'macos',
      nativeEngine: 'URLSession',
      supportsBackgroundExecution: true,
      supportsPauseResume: true,
      supportsSystemNotifications: true,
      supportsPersistence: true,
      supportsChecksumVerification: true,
      supportsNetworkConstraints: true,
      defaultDownloadDirectory: '/tmp/downloads',
    );
  }

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<DownloadTask> enqueue(DownloadRequest request) async {
    final id = request.taskId ?? 'id_${store.length + 1}';
    final fileName = request.fileName ?? 'sample.bin';
    final task = DownloadTask(
      taskId: id,
      url: request.url,
      saveDirectory: request.saveDirectory,
      fileName: fileName,
      savePath: '${request.saveDirectory}/$fileName',
      status: DownloadStatus.queued,
      group: request.group,
      priority: request.priority,
      conflictResolution: request.conflictResolution,
    );
    store[id] = task;
    controller.add(task);
    return task;
  }

  @override
  Future<List<DownloadTask>> enqueueAll(List<DownloadRequest> requests) async {
    final out = <DownloadTask>[];
    for (final req in requests) {
      out.add(await enqueue(req));
    }
    return out;
  }

  @override
  Future<DownloadTask?> pause(String taskId) async {
    final existing = store[taskId];
    if (existing == null) return null;
    final updated = DownloadTask.fromMap(<Object?, Object?>{
      ...existing.toMap(),
      'status': 'paused',
    });
    store[taskId] = updated;
    controller.add(updated);
    return updated;
  }

  @override
  Future<DownloadTask?> resume(String taskId) async {
    final existing = store[taskId];
    if (existing == null) return null;
    final updated = DownloadTask.fromMap(<Object?, Object?>{
      ...existing.toMap(),
      'status': 'running',
    });
    store[taskId] = updated;
    controller.add(updated);
    return updated;
  }

  @override
  Future<DownloadTask?> cancel(
    String taskId, {
    bool deletePartialFile = true,
  }) async {
    final existing = store[taskId];
    if (existing == null) return null;
    final updated = DownloadTask.fromMap(<Object?, Object?>{
      ...existing.toMap(),
      'status': 'canceled',
    });
    store[taskId] = updated;
    controller.add(updated);
    return updated;
  }

  @override
  Future<DownloadTask?> retry(String taskId) async => resume(taskId);

  @override
  Future<bool> removeTask(String taskId, {bool deleteFile = false}) async {
    return store.remove(taskId) != null;
  }

  @override
  Future<List<DownloadTask>> pauseAll({String? group}) async {
    final out = <DownloadTask>[];
    for (final id in store.keys.toList()) {
      final p = await pause(id);
      if (p != null) out.add(p);
    }
    return out;
  }

  @override
  Future<List<DownloadTask>> resumeAll({String? group}) async {
    final out = <DownloadTask>[];
    for (final id in store.keys.toList()) {
      final r = await resume(id);
      if (r != null) out.add(r);
    }
    return out;
  }

  @override
  Future<List<DownloadTask>> cancelAll({
    String? group,
    bool deletePartialFiles = true,
  }) async {
    final out = <DownloadTask>[];
    for (final id in store.keys.toList()) {
      final c = await cancel(id, deletePartialFile: deletePartialFiles);
      if (c != null) out.add(c);
    }
    return out;
  }

  @override
  Future<int> clearCompleted({String? group, bool deleteFiles = false}) async {
    final ids = store.values
        .where((t) => t.status == DownloadStatus.completed)
        .map((t) => t.taskId)
        .toList();
    for (final id in ids) {
      store.remove(id);
    }
    return ids.length;
  }

  @override
  Future<DownloadTask?> getTask(String taskId) async => store[taskId];

  @override
  Future<List<DownloadTask>> getAllTasks({String? group}) async =>
      store.values.toList();
}

void main() {
  final XueHuaNaviteBackgroundDownloaderPlatform initialPlatform =
      XueHuaNaviteBackgroundDownloaderPlatform.instance;

  test('$MethodChannelXueHuaNaviteBackgroundDownloader is the default instance', () {
    expect(
      initialPlatform,
      isInstanceOf<MethodChannelXueHuaNaviteBackgroundDownloader>(),
    );
  });

  test('Full lifecycle via XueHuaNaviteBackgroundDownloader controller', () async {
    final fakePlatform = FakeXueHuaBackgroundDownloaderPlatform();
    XueHuaNaviteBackgroundDownloaderPlatform.instance = fakePlatform;
    final downloader = XueHuaNaviteBackgroundDownloader.instance;

    await downloader.configure(const DownloaderConfig(maxConcurrentTasks: 4));
    expect(fakePlatform.lastConfig?.maxConcurrentTasks, 4);

    final caps = await downloader.getCapabilities();
    expect(caps.supportsPauseResume, isTrue);

    expect(
      () => downloader.enqueue(
        const DownloadRequest(url: '   ', saveDirectory: '/tmp'),
      ),
      throwsArgumentError,
    );

    final created = await downloader.enqueue(
      const DownloadRequest(
        url: 'https://example.com/archive.zip',
        saveDirectory: '/tmp/downloads',
        fileName: 'archive.zip',
        taskId: 'dl_1',
        priority: DownloadPriority.critical,
      ),
    );
    expect(created.taskId, 'dl_1');
    expect(created.status, DownloadStatus.queued);

    final paused = await downloader.pause('dl_1');
    expect(paused?.status, DownloadStatus.paused);

    final resumed = await downloader.resume('dl_1');
    expect(resumed?.status, DownloadStatus.running);

    final canceled = await downloader.cancel('dl_1');
    expect(canceled?.status, DownloadStatus.canceled);

    final removed = await downloader.removeTask('dl_1', deleteFile: true);
    expect(removed, isTrue);
  });
}
