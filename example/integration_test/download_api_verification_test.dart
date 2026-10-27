import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

// Single integration_test entrypoint. On desktop, `flutter test`
// launching a second `*_test.dart` in the same process often fails with
// "Unable to start the app" because the VM service log reader does not
// survive the restart. Keep additional cases in this file, or run each
// file in its own process via `tool/run_desktop_tests.sh` (Linux, macOS,
// Git Bash) or `tool/run_desktop_tests.ps1` (Windows PowerShell).

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final downloader = XueHuaNaviteBackgroundDownloader.instance;

  setUpAll(() async {
    await downloader.configure(
      const DownloaderConfig(
        maxConcurrentTasks: 2,
        connectTimeoutMs: 15000,
        readTimeoutMs: 30000,
        progressUpdateIntervalMs: 200,
        enableNotifications: false,
        autoResumeOnStartup: false,
      ),
    );
  });

  testWidgets('capabilities expose native engine', (tester) async {
    final caps = await downloader.getCapabilities();
    final platform = caps.platform.toLowerCase();
    final engine = caps.nativeEngine.toLowerCase();
    expect(caps.supportsPauseResume, isTrue);
    expect(caps.supportsPersistence, isTrue);
    expect(caps.defaultDownloadDirectory.isNotEmpty, isTrue);
    _expectTaskStorePath(caps.taskStorePath);
    if (Platform.isWindows) {
      expect(platform, contains('windows'));
      expect(engine, contains('winhttp'));
    } else if (Platform.isLinux) {
      expect(platform, contains('linux'));
      expect(engine, contains('curl'));
    } else {
      expect(platform.isNotEmpty, isTrue);
      expect(engine.isNotEmpty, isTrue);
    }
    // ignore: avoid_print
    print(
      'CAPABILITIES: platform=${caps.platform} engine=${caps.nativeEngine} dir=${caps.defaultDownloadDirectory} store=${caps.taskStorePath}',
    );
  });

  testWidgets('getCapabilities returns valid platform capabilities', (
    tester,
  ) async {
    final caps = await downloader.getCapabilities();
    expect(caps.platform.isNotEmpty, true);
    expect(caps.supportsPauseResume, true);
    expect(caps.supportsPersistence, true);
  });

  testWidgets('enqueue completes small download with progress', (tester) async {
    final updates = <DownloadTask>[];
    final sub = downloader.taskUpdates.listen(updates.add);

    final task = await downloader.enqueue(
      const DownloadRequest(
        url: 'https://httpbin.org/bytes/65536',
        saveDirectory: '',
        fileName: 'xh_verify_64kb.bin',
        group: 'verify',
        priority: DownloadPriority.high,
        conflictResolution: DownloadConflictResolution.overwrite,
        notificationConfig: DownloadNotificationConfig(enabled: false),
      ),
    );
    expect(task.taskId.isNotEmpty, isTrue);
    // ignore: avoid_print
    print('ENQUEUED: ${task.taskId} status=${task.status.name}');

    DownloadTask? completed;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final latest = await downloader.getTask(task.taskId);
      if (latest != null &&
          (latest.status == DownloadStatus.completed ||
              latest.status == DownloadStatus.failed ||
              latest.status == DownloadStatus.canceled)) {
        completed = latest;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await sub.cancel();

    expect(completed, isNotNull, reason: 'download did not finish in time');
    // ignore: avoid_print
    print(
      'COMPLETE: status=${completed!.status.name} progress=${completed.progress} path=${completed.savePath} bytes=${completed.downloadedBytes} err=${completed.error?.message}',
    );
    expect(completed.status, DownloadStatus.completed);
    expect(completed.progress, greaterThanOrEqualTo(0.99));
    expect(completed.downloadedBytes, greaterThan(0));
    expect(completed.savePath.isNotEmpty, isTrue);
    expect(File(completed.savePath).existsSync(), isTrue);
    expect(updates.any((t) => t.taskId == task.taskId), isTrue);
    await downloader.removeTask(task.taskId, deleteFile: true);
  });

  testWidgets('cancel running download', (tester) async {
    final task = await downloader.enqueue(
      const DownloadRequest(
        url: 'https://speed.cloudflare.com/__down?bytes=20971520',
        saveDirectory: '',
        fileName: 'xh_verify_cancel_20mb.bin',
        group: 'verify_cancel',
        priority: DownloadPriority.normal,
        conflictResolution: DownloadConflictResolution.overwrite,
        notificationConfig: DownloadNotificationConfig(enabled: false),
      ),
    );
    // ignore: avoid_print
    print('CANCEL_ENQUEUED: ${task.taskId}');

    final waitUntil = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(waitUntil)) {
      final latest = await downloader.getTask(task.taskId);
      if (latest != null &&
          (latest.status == DownloadStatus.running ||
              latest.downloadedBytes > 0 ||
              latest.status == DownloadStatus.completed)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final canceled = await downloader.cancel(
      task.taskId,
      deletePartialFile: true,
    );
    // ignore: avoid_print
    print(
      'CANCELED: status=${canceled?.status.name} bytes=${canceled?.downloadedBytes}',
    );
    expect(canceled, isNotNull);
    expect(
      canceled!.status == DownloadStatus.canceled ||
          canceled.status == DownloadStatus.completed,
      isTrue,
    );

    await downloader.removeTask(task.taskId, deleteFile: true);
  });

  testWidgets('pause and resume when supported', (tester) async {
    final task = await downloader.enqueue(
      const DownloadRequest(
        url: 'https://speed.cloudflare.com/__down?bytes=5242880',
        saveDirectory: '',
        fileName: 'xh_verify_pause_5mb.bin',
        group: 'verify_pause',
        priority: DownloadPriority.normal,
        conflictResolution: DownloadConflictResolution.overwrite,
        notificationConfig: DownloadNotificationConfig(enabled: false),
      ),
    );
    // ignore: avoid_print
    print('PAUSE_ENQUEUED: ${task.taskId}');

    final waitUntil = DateTime.now().add(const Duration(seconds: 30));
    DownloadTask? running;
    while (DateTime.now().isBefore(waitUntil)) {
      final latest = await downloader.getTask(task.taskId);
      if (latest != null && latest.downloadedBytes > 64 * 1024) {
        running = latest;
        break;
      }
      if (latest != null && latest.status == DownloadStatus.completed) {
        // ignore: avoid_print
        print('PAUSE_SKIP: completed too fast bytes=${latest.downloadedBytes}');
        await downloader.removeTask(task.taskId, deleteFile: true);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(
      running,
      isNotNull,
      reason: 'never reached running state with bytes',
    );

    final paused = await downloader.pause(task.taskId);
    // ignore: avoid_print
    print(
      'PAUSED: status=${paused?.status.name} bytes=${paused?.downloadedBytes}',
    );
    expect(paused, isNotNull);
    expect(paused!.status, DownloadStatus.paused);
    expect(paused.downloadedBytes, greaterThan(0));

    final bytesAtPause = paused.downloadedBytes;
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final resumed = await downloader.resume(task.taskId);
    // ignore: avoid_print
    print('RESUMED: status=${resumed?.status.name}');
    expect(resumed, isNotNull);

    DownloadTask? finished;
    DownloadTask? lastSeen;
    var nullPolls = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (DateTime.now().isBefore(deadline)) {
      final latest = await downloader.getTask(task.taskId);
      lastSeen = latest;
      if (latest == null) {
        nullPolls++;
        // ignore: avoid_print
        print('GETTASK_NULL id=${task.taskId} nullPolls=$nullPolls');
      } else if (latest.status == DownloadStatus.completed ||
          latest.status == DownloadStatus.failed ||
          latest.status == DownloadStatus.canceled) {
        finished = latest;
        break;
      } else if (nullPolls == 0 &&
          latest.downloadedBytes > 0 &&
          latest.downloadedBytes % (512 * 1024) < 8192) {
        // ignore: avoid_print
        print(
          'RESUME_PROGRESS: status=${latest.status.name} bytes=${latest.downloadedBytes}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // ignore: avoid_print
    print(
      'RESUME_DONE: finished=${finished?.status.name} finishedBytes=${finished?.downloadedBytes} '
      'lastSeen=${lastSeen?.status.name} lastBytes=${lastSeen?.downloadedBytes} '
      'nullPolls=$nullPolls pauseBytes=$bytesAtPause',
    );
    expect(lastSeen, isNotNull, reason: 'getTask became null after resume');
    expect(finished, isNotNull, reason: 'download never reached a terminal state after resume');
    expect(finished!.status, DownloadStatus.completed);
    expect(finished.downloadedBytes, greaterThanOrEqualTo(bytesAtPause));
    expect(finished.downloadedBytes, 5242880);
    await downloader.removeTask(task.taskId, deleteFile: true);
  });

  testWidgets('skip and fail conflict policies use the destination file', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('xh_conflict_');
    try {
      final existing = File(_join(dir.path, 'already.bin'));
      await existing.writeAsBytes(List<int>.filled(32, 7));

      final skipped = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/bytes/65536',
          saveDirectory: dir.path,
          fileName: 'already.bin',
          group: 'verify_skip',
          conflictResolution: DownloadConflictResolution.skip,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final skipDone = await _waitTerminal(downloader, skipped.taskId);
      expect(skipDone.status, DownloadStatus.completed);
      expect(skipDone.downloadedBytes, 32);
      expect(await existing.length(), 32);

      final blocked = File(_join(dir.path, 'blocked.bin'));
      await blocked.writeAsBytes(const <int>[1, 2, 3, 4]);
      final failed = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/bytes/65536',
          saveDirectory: dir.path,
          fileName: 'blocked.bin',
          group: 'verify_fail',
          conflictResolution: DownloadConflictResolution.fail,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final failDone = await _waitTerminal(downloader, failed.taskId);
      expect(failDone.status, DownloadStatus.failed);
      expect(failDone.error?.code, 'file_exists');
      expect(await blocked.length(), 4);

      await downloader.removeTask(skipped.taskId, deleteFile: false);
      await downloader.removeTask(failed.taskId, deleteFile: false);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('checksum compare is case-insensitive and rejects a mismatch', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('xh_checksum_');
    try {
      final source = File(_join(dir.path, 'robots_src.txt'));
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('https://httpbin.org/robots.txt'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) {
          acc.addAll(chunk);
          return acc;
        });
        await source.writeAsBytes(bytes);
      } finally {
        client.close(force: true);
      }
      final digest = (await _sha256Hex(source.path)).toUpperCase();
      expect(digest, hasLength(64));

      final matched = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/robots.txt',
          saveDirectory: dir.path,
          fileName: 'robots.txt',
          group: 'verify_checksum',
          expectedChecksum: digest,
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final matchDone = await _waitTerminal(downloader, matched.taskId);
      expect(
        matchDone.status,
        DownloadStatus.completed,
        reason: matchDone.error?.message,
      );
      expect(matchDone.computedChecksum?.toLowerCase(), digest.toLowerCase());

      final mismatch = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/robots.txt',
          saveDirectory: dir.path,
          fileName: 'robots_bad.txt',
          group: 'verify_checksum',
          expectedChecksum: 'ab' * 32,
          checksumAlgorithm: ChecksumAlgorithm.sha256,
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final mismatchDone = await _waitTerminal(downloader, mismatch.taskId);
      expect(mismatchDone.status, DownloadStatus.failed);
      expect(mismatchDone.error?.code, 'checksum_mismatch');
      expect(mismatchDone.error?.isRecoverable, isFalse);

      await downloader.removeTask(matched.taskId, deleteFile: true);
      await downloader.removeTask(mismatch.taskId, deleteFile: true);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('custom header is sent and HTTP 404 is http_error', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('xh_http_');
    try {
      final headerTask = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/headers',
          saveDirectory: dir.path,
          fileName: 'headers.json',
          group: 'verify_headers',
          headers: const <String, String>{'X-Xuehua-Test': 'desktop-ok'},
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final headerDone = await _waitTerminal(downloader, headerTask.taskId);
      expect(headerDone.status, DownloadStatus.completed);
      final body = await File(headerDone.savePath).readAsString();
      expect(body.toLowerCase(), contains('x-xuehua-test'));
      expect(body, contains('desktop-ok'));

      final missing = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/status/404',
          saveDirectory: dir.path,
          fileName: 'missing.bin',
          group: 'verify_http',
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final missingDone = await _waitTerminal(downloader, missing.taskId);
      expect(missingDone.status, DownloadStatus.failed);
      expect(missingDone.error?.code, 'http_error');
      expect(missingDone.error?.httpStatusCode, 404);

      await downloader.removeTask(headerTask.taskId, deleteFile: true);
      await downloader.removeTask(missing.taskId, deleteFile: true);
    } finally {
      await dir.delete(recursive: true);
    }
  });


  testWidgets('requestNotificationPermission returns a boolean', (tester) async {
    final granted = await downloader.requestNotificationPermission();
    expect(granted, isA<bool>());
    // ignore: avoid_print
    print('NOTIFICATION_PERMISSION: granted=$granted');
  });

  testWidgets('enqueueAll batches and watchGroup receives updates', (tester) async {
    final dir = await Directory.systemTemp.createTemp('xh_batch_');
    final groupUpdates = <DownloadTask>[];
    final sub = downloader.watchGroup('verify_enqueue_all').listen(groupUpdates.add);
    try {
      final tasks = await downloader.enqueueAll([
        DownloadRequest(
          url: 'https://httpbin.org/bytes/256',
          saveDirectory: dir.path,
          fileName: 'batch_a.bin',
          group: 'verify_enqueue_all',
          priority: DownloadPriority.high,
          conflictResolution: DownloadConflictResolution.overwrite,
          metadata: const <String, String>{'slot': 'a'},
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
        DownloadRequest(
          url: 'https://httpbin.org/bytes/512',
          saveDirectory: dir.path,
          fileName: 'batch_b.bin',
          group: 'verify_enqueue_all',
          priority: DownloadPriority.normal,
          conflictResolution: DownloadConflictResolution.overwrite,
          metadata: const <String, String>{'slot': 'b'},
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      ]);
      expect(tasks, hasLength(2));
      expect(tasks.map((t) => t.taskId).toSet(), hasLength(2));

      final empty = await downloader.enqueueAll(const <DownloadRequest>[]);
      expect(empty, isEmpty);

      final doneA = await _waitTerminal(downloader, tasks[0].taskId);
      final doneB = await _waitTerminal(downloader, tasks[1].taskId);
      expect(doneA.status, DownloadStatus.completed);
      expect(doneB.status, DownloadStatus.completed);
      expect(groupUpdates.any((t) => t.taskId == tasks[0].taskId), isTrue);
      expect(groupUpdates.any((t) => t.taskId == tasks[1].taskId), isTrue);

      await downloader.removeTask(tasks[0].taskId, deleteFile: true);
      await downloader.removeTask(tasks[1].taskId, deleteFile: true);
    } finally {
      await sub.cancel();
      await dir.delete(recursive: true);
    }
  });

  testWidgets('watchTask emits progress for a single download', (tester) async {
    final dir = await Directory.systemTemp.createTemp('xh_watch_');
    const taskId = 'xh-verify-watch-task';
    final watched = <DownloadTask>[];
    final sub = downloader.watchTask(taskId).listen(watched.add);
    try {
      final task = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/bytes/8192',
          saveDirectory: dir.path,
          fileName: 'watch.bin',
          taskId: taskId,
          group: 'verify_watch',
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      expect(task.taskId, taskId);
      final done = await _waitTerminal(downloader, taskId);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(done.status, DownloadStatus.completed);
      expect(watched.any((t) => t.taskId == taskId), isTrue);
      await downloader.removeTask(taskId, deleteFile: true);
    } finally {
      await sub.cancel();
      await dir.delete(recursive: true);
    }
  });

  testWidgets('pauseAll resumeAll and cancelAll respect group scope', (
    tester,
  ) async {
    final hold = await downloader.enqueue(
      const DownloadRequest(
        url: 'https://speed.cloudflare.com/__down?bytes=8388608',
        saveDirectory: '',
        fileName: 'xh_verify_pause_all_8mb.bin',
        group: 'verify_pause_all',
        priority: DownloadPriority.normal,
        conflictResolution: DownloadConflictResolution.overwrite,
        notificationConfig: DownloadNotificationConfig(enabled: false),
      ),
    );
    // ignore: avoid_print
    print('PAUSE_ALL_ENQUEUED: ${hold.taskId}');

    final waitUntil = DateTime.now().add(const Duration(seconds: 30));
    DownloadTask? running;
    while (DateTime.now().isBefore(waitUntil)) {
      final latest = await downloader.getTask(hold.taskId);
      if (latest != null && latest.downloadedBytes > 64 * 1024) {
        running = latest;
        break;
      }
      if (latest != null && latest.status == DownloadStatus.completed) {
        // ignore: avoid_print
        print('PAUSE_ALL_SKIP: completed too fast');
        await downloader.removeTask(hold.taskId, deleteFile: true);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(running, isNotNull, reason: 'never reached running with bytes');

    final paused = await downloader.pauseAll(group: 'verify_pause_all');
    expect(paused.any((t) => t.taskId == hold.taskId), isTrue);
    final afterPause = await downloader.getTask(hold.taskId);
    expect(afterPause?.status, DownloadStatus.paused);

    final outsider = await downloader.pauseAll(group: 'verify_pause_all_absent');
    expect(outsider.any((t) => t.taskId == hold.taskId), isFalse);

    final resumed = await downloader.resumeAll(group: 'verify_pause_all');
    expect(resumed.any((t) => t.taskId == hold.taskId), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    final canceled = await downloader.cancelAll(
      group: 'verify_pause_all',
      deletePartialFiles: true,
    );
    expect(canceled.any((t) => t.taskId == hold.taskId), isTrue);
    final afterCancel = await downloader.getTask(hold.taskId);
    expect(
      afterCancel == null ||
          afterCancel.status == DownloadStatus.canceled ||
          afterCancel.status == DownloadStatus.completed,
      isTrue,
    );
    await downloader.removeTask(hold.taskId, deleteFile: true);
  });

  testWidgets('retry requeues a canceled download to completion', (tester) async {
    final dir = await Directory.systemTemp.createTemp('xh_retry_');
    try {
      final task = await downloader.enqueue(
        DownloadRequest(
          url: 'https://speed.cloudflare.com/__down?bytes=1048576',
          saveDirectory: dir.path,
          fileName: 'xh_verify_retry_1mb.bin',
          group: 'verify_retry',
          conflictResolution: DownloadConflictResolution.overwrite,
          maxRetries: 0,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      // ignore: avoid_print
      print('RETRY_ENQUEUED: ${task.taskId}');

      final waitUntil = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(waitUntil)) {
        final latest = await downloader.getTask(task.taskId);
        if (latest != null &&
            (latest.status == DownloadStatus.running ||
                latest.downloadedBytes > 0 ||
                latest.status == DownloadStatus.completed)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      final canceled = await downloader.cancel(
        task.taskId,
        deletePartialFile: true,
      );
      expect(canceled, isNotNull);
      if (canceled!.status == DownloadStatus.completed) {
        // ignore: avoid_print
        print('RETRY_SKIP: finished before cancel');
        await downloader.removeTask(task.taskId, deleteFile: true);
        return;
      }
      expect(canceled.status, DownloadStatus.canceled);

      final retried = await downloader.retry(task.taskId);
      expect(retried, isNotNull);
      expect(
        retried!.status == DownloadStatus.queued ||
            retried.status == DownloadStatus.running ||
            retried.status == DownloadStatus.completed,
        isTrue,
      );
      final done = await _waitTerminal(
        downloader,
        task.taskId,
        timeout: const Duration(seconds: 90),
      );
      expect(done.status, DownloadStatus.completed, reason: done.error?.message);
      await downloader.removeTask(task.taskId, deleteFile: true);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('clearCompleted removes finished tasks from the store', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('xh_clear_');
    try {
      final task = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/bytes/128',
          saveDirectory: dir.path,
          fileName: 'clear_me.bin',
          group: 'verify_clear',
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final done = await _waitTerminal(downloader, task.taskId);
      expect(done.status, DownloadStatus.completed);

      final removed = await downloader.clearCompleted(
        group: 'verify_clear',
        deleteFiles: true,
      );
      expect(removed, greaterThanOrEqualTo(1));
      final leftover = await downloader.getAllTasks(group: 'verify_clear');
      expect(leftover.map((t) => t.taskId), isNot(contains(task.taskId)));
      expect(await downloader.getTask(task.taskId), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('uniqueName conflict creates a distinct destination file', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('xh_unique_');
    try {
      final existing = File(_join(dir.path, 'shared.bin'));
      await existing.writeAsBytes(List<int>.filled(16, 9));

      final task = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/bytes/64',
          saveDirectory: dir.path,
          fileName: 'shared.bin',
          group: 'verify_unique',
          conflictResolution: DownloadConflictResolution.uniqueName,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final done = await _waitTerminal(downloader, task.taskId);
      expect(done.status, DownloadStatus.completed, reason: done.error?.message);
      expect(done.savePath, isNot(existing.path));
      expect(File(done.savePath).existsSync(), isTrue);
      expect(await existing.length(), 16);
      await downloader.removeTask(task.taskId, deleteFile: true);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('POST method sends body and completes', (tester) async {
    final dir = await Directory.systemTemp.createTemp('xh_post_');
    try {
      final task = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/post',
          saveDirectory: dir.path,
          fileName: 'post.json',
          group: 'verify_post',
          method: DownloadHttpMethod.post,
          postBody: '{"plugin":"xue_hua","case":"integration"}',
          headers: const <String, String>{
            'Content-Type': 'application/json',
          },
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final done = await _waitTerminal(downloader, task.taskId);
      expect(done.status, DownloadStatus.completed, reason: done.error?.message);
      final body = await File(done.savePath).readAsString();
      expect(body, contains('xue_hua'));
      expect(body, contains('integration'));
      await downloader.removeTask(task.taskId, deleteFile: true);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('getAllTasks filters by group and the store file is readable', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('xh_group_');
    try {
      final task = await downloader.enqueue(
        DownloadRequest(
          url: 'https://httpbin.org/bytes/128',
          saveDirectory: dir.path,
          fileName: 'group.bin',
          group: 'verify_group_only',
          conflictResolution: DownloadConflictResolution.overwrite,
          notificationConfig: const DownloadNotificationConfig(enabled: false),
        ),
      );
      final done = await _waitTerminal(downloader, task.taskId);
      expect(done.status, DownloadStatus.completed);

      final grouped = await downloader.getAllTasks(group: 'verify_group_only');
      expect(grouped.map((item) => item.taskId), contains(task.taskId));
      final other = await downloader.getAllTasks(group: 'verify_group_absent');
      expect(other.map((item) => item.taskId), isNot(contains(task.taskId)));

      final caps = await downloader.getCapabilities();
      _expectTaskStorePath(caps.taskStorePath);
      final store = File(caps.taskStorePath);
      final storeDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (!store.existsSync() && DateTime.now().isBefore(storeDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        store.existsSync(),
        isTrue,
        reason: 'task store missing at ${caps.taskStorePath}',
      );
      expect(await store.readAsString(), contains(task.taskId));

      await downloader.removeTask(task.taskId, deleteFile: true);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

/// Apple keeps the queue in Application Support JSON. Android uses its
/// files directory. Linux and Windows keep a TSV next to downloads.
void _expectTaskStorePath(String path) {
  expect(path, isNotEmpty);
  if (Platform.isIOS || Platform.isMacOS) {
    final separator = Platform.pathSeparator;
    expect(
      path,
      contains(
        '${separator}xue_hua_background_downloader${separator}tasks.json',
      ),
    );
  } else if (Platform.isAndroid) {
    expect(path, endsWith('xue_hua_downloader_tasks.json'));
  } else if (Platform.isLinux || Platform.isWindows) {
    expect(path, endsWith('xue_hua_downloader_tasks.tsv'));
  }
}

String _join(String directory, String name) {
  final separator = Platform.pathSeparator;
  if (directory.endsWith(separator)) {
    return '$directory$name';
  }
  return '$directory$separator$name';
}

Future<DownloadTask> _waitTerminal(
  XueHuaNaviteBackgroundDownloader downloader,
  String taskId, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  DownloadTask? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await downloader.getTask(taskId);
    if (latest != null &&
        (latest.status == DownloadStatus.completed ||
            latest.status == DownloadStatus.failed ||
            latest.status == DownloadStatus.canceled)) {
      return latest;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  fail(
    'task $taskId did not finish; last=${latest?.status.name} err=${latest?.error?.message}',
  );
}

/// Pure Dart SHA-256. iOS forbids `Process.start`, so the checksum case
/// cannot shell out to `sha256sum` / `shasum` / `certutil`.
Future<String> _sha256Hex(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
