import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

// Single integration_test entrypoint. On Linux desktop, `flutter test`
// launching a second `*_test.dart` in the same process often fails with
// "Unable to start the app" because the VM service log reader does not
// survive the restart. Keep additional cases in this file, or run each
// file in its own process via `tool/run_linux_tests.sh`.

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
      'CAPABILITIES: platform=${caps.platform} engine=${caps.nativeEngine} dir=${caps.defaultDownloadDirectory}',
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
        url: 'https://proof.ovh.net/files/10Mb.dat',
        saveDirectory: '',
        fileName: 'xh_verify_cancel_10mb.dat',
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
        url: 'https://proof.ovh.net/files/10Mb.dat',
        saveDirectory: '',
        fileName: 'xh_verify_pause_10mb.dat',
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
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final latest = await downloader.getTask(task.taskId);
      if (latest != null &&
          (latest.status == DownloadStatus.completed ||
              latest.status == DownloadStatus.failed ||
              latest.status == DownloadStatus.canceled)) {
        finished = latest;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // ignore: avoid_print
    print(
      'RESUME_DONE: status=${finished?.status.name} bytes=${finished?.downloadedBytes} pauseBytes=$bytesAtPause',
    );
    expect(finished, isNotNull);
    expect(finished!.status, DownloadStatus.completed);
    expect(finished.downloadedBytes, greaterThanOrEqualTo(bytesAtPause));
    expect(finished.downloadedBytes, 10485760);
    await downloader.removeTask(task.taskId, deleteFile: true);
  });
}
