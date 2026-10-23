import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'xue_hua_navite_background_downloader_platform_interface.dart';

/// An implementation of [XueHuaNaviteBackgroundDownloaderPlatform] that uses method channels.
class MethodChannelXueHuaNaviteBackgroundDownloader extends XueHuaNaviteBackgroundDownloaderPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('xue_hua_navite_background_downloader');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
