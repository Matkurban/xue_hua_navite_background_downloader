import 'package:flutter_test/flutter_test.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader_platform_interface.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockXueHuaNaviteBackgroundDownloaderPlatform
    with MockPlatformInterfaceMixin
    implements XueHuaNaviteBackgroundDownloaderPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final XueHuaNaviteBackgroundDownloaderPlatform initialPlatform = XueHuaNaviteBackgroundDownloaderPlatform.instance;

  test('$MethodChannelXueHuaNaviteBackgroundDownloader is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelXueHuaNaviteBackgroundDownloader>());
  });

  test('getPlatformVersion', () async {
    XueHuaNaviteBackgroundDownloader xueHuaNaviteBackgroundDownloaderPlugin = XueHuaNaviteBackgroundDownloader();
    MockXueHuaNaviteBackgroundDownloaderPlatform fakePlatform = MockXueHuaNaviteBackgroundDownloaderPlatform();
    XueHuaNaviteBackgroundDownloaderPlatform.instance = fakePlatform;

    expect(await xueHuaNaviteBackgroundDownloaderPlugin.getPlatformVersion(), '42');
  });
}
