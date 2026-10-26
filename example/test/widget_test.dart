import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';
import 'package:xue_hua_navite_background_downloader_example/main.dart';

class _FakeDownloaderPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteBackgroundDownloaderPlatform {
  @override
  Stream<DownloadTask> get taskUpdates => const Stream<DownloadTask>.empty();

  @override
  Future<void> configure(DownloaderConfig config) async {}

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
    return DownloadTask(
      taskId: 'test_1',
      url: request.url,
      saveDirectory: '/tmp/downloads',
      fileName: request.fileName ?? 'test.bin',
      savePath: '/tmp/downloads/test.bin',
      status: DownloadStatus.queued,
    );
  }

  @override
  Future<List<DownloadTask>> enqueueAll(List<DownloadRequest> requests) async =>
      const <DownloadTask>[];

  @override
  Future<DownloadTask?> pause(String taskId) async => null;

  @override
  Future<DownloadTask?> resume(String taskId) async => null;

  @override
  Future<DownloadTask?> cancel(
    String taskId, {
    bool deletePartialFile = true,
  }) async => null;

  @override
  Future<DownloadTask?> retry(String taskId) async => null;

  @override
  Future<bool> removeTask(String taskId, {bool deleteFile = false}) async =>
      true;

  @override
  Future<List<DownloadTask>> pauseAll({String? group}) async =>
      const <DownloadTask>[];

  @override
  Future<List<DownloadTask>> resumeAll({String? group}) async =>
      const <DownloadTask>[];

  @override
  Future<List<DownloadTask>> cancelAll({
    String? group,
    bool deletePartialFiles = true,
  }) async => const <DownloadTask>[];

  @override
  Future<int> clearCompleted({String? group, bool deleteFiles = false}) async =>
      0;

  @override
  Future<DownloadTask?> getTask(String taskId) async => null;

  @override
  Future<List<DownloadTask>> getAllTasks({String? group}) async =>
      const <DownloadTask>[];
}

void main() {
  testWidgets('Example app renders dashboard and platform capabilities', (
    WidgetTester tester,
  ) async {
    XueHuaNaviteBackgroundDownloaderPlatform.instance =
        _FakeDownloaderPlatform();

    await tester.pumpWidget(const DownloaderExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('Native Background Downloader'), findsOneWidget);
    expect(find.textContaining('Platform Engine: MACOS'), findsOneWidget);
    expect(find.text('Enqueue 4-Task Priority Batch'), findsOneWidget);
    // Phone width builds the enqueue field even when it is below the fold.
    expect(
      find.byKey(const ValueKey<String>('dashboard-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('download-filename-field')),
      findsOneWidget,
    );
  });

  testWidgets('wide layout keeps enqueue controls in the control pane', (
    WidgetTester tester,
  ) async {
    XueHuaNaviteBackgroundDownloaderPlatform.instance =
        _FakeDownloaderPlatform();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const DownloaderExampleApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('control-pane')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('download-filename-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dashboard-scroll')),
      findsNothing,
    );
  });
}
