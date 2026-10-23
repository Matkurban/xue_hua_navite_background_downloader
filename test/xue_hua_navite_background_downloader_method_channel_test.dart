import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelXueHuaNaviteBackgroundDownloader platform =
      MethodChannelXueHuaNaviteBackgroundDownloader();
  const MethodChannel channel = MethodChannel(
    'com.kurban.xue_hua_navite_background_downloader/methods',
  );

  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          log.add(methodCall);
          switch (methodCall.method) {
            case 'configure':
              return null;
            case 'getCapabilities':
              return <String, Object?>{
                'platform': 'macos',
                'nativeEngine': 'URLSession + NSProcessInfo Activity',
                'supportsBackgroundExecution': true,
                'supportsPauseResume': true,
                'supportsSystemNotifications': true,
                'supportsPersistence': true,
                'supportsChecksumVerification': true,
                'supportsNetworkConstraints': true,
                'defaultDownloadDirectory': '/tmp/downloads',
              };
            case 'requestNotificationPermission':
              return true;
            case 'enqueue':
              final args = methodCall.arguments as Map<Object?, Object?>;
              return <String, Object?>{
                'taskId': args['taskId'] ?? 'task_1',
                'url': args['url'],
                'saveDirectory': '/tmp/downloads',
                'fileName': args['fileName'] ?? 'file.bin',
                'savePath': '/tmp/downloads/${args['fileName'] ?? 'file.bin'}',
                'status': 'queued',
                'group': args['group'] ?? 'default',
                'priority': args['priority'] ?? 'normal',
                'conflictResolution': args['conflictResolution'] ?? 'overwrite',
                'downloadedBytes': 0,
                'totalBytes': 1024,
                'progress': 0.0,
                'bytesPerSecond': 0.0,
                'estimatedRemainingMs': -1,
                'supportsResume': true,
                'createdAtMs': 1700000000000,
                'updatedAtMs': 1700000000000,
              };
            case 'pause':
              return <String, Object?>{
                'taskId': 'task_1',
                'url': 'https://example.com/file.bin',
                'saveDirectory': '/tmp/downloads',
                'fileName': 'file.bin',
                'savePath': '/tmp/downloads/file.bin',
                'status': 'paused',
                'downloadedBytes': 512,
                'totalBytes': 1024,
                'progress': 0.5,
              };
            case 'resume':
              return <String, Object?>{
                'taskId': 'task_1',
                'url': 'https://example.com/file.bin',
                'saveDirectory': '/tmp/downloads',
                'fileName': 'file.bin',
                'savePath': '/tmp/downloads/file.bin',
                'status': 'queued',
                'downloadedBytes': 512,
                'totalBytes': 1024,
                'progress': 0.5,
              };
            case 'clearCompleted':
              return 2;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getCapabilities parses native capabilities', () async {
    final caps = await platform.getCapabilities();
    expect(caps.platform, 'macos');
    expect(caps.supportsPauseResume, isTrue);
    expect(caps.supportsPersistence, isTrue);
    expect(caps.defaultDownloadDirectory, '/tmp/downloads');
  });

  test('enqueue, pause, resume, and clearCompleted invoke method channel', () async {
    final task = await platform.enqueue(
      const DownloadRequest(
        url: 'https://example.com/file.bin',
        saveDirectory: '/tmp/downloads',
        fileName: 'file.bin',
        taskId: 'task_1',
        priority: DownloadPriority.high,
      ),
    );
    expect(task.taskId, 'task_1');
    expect(task.status, DownloadStatus.queued);
    expect(task.priority, DownloadPriority.high);

    final paused = await platform.pause('task_1');
    expect(paused?.status, DownloadStatus.paused);
    expect(paused?.downloadedBytes, 512);

    final resumed = await platform.resume('task_1');
    expect(resumed?.status, DownloadStatus.queued);

    final cleared = await platform.clearCompleted(deleteFiles: true);
    expect(cleared, 2);
    expect(log.map((c) => c.method), <String>[
      'enqueue',
      'pause',
      'resume',
      'clearCompleted',
    ]);
  });
}
