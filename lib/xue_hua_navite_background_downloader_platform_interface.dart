import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'xue_hua_navite_background_downloader_method_channel.dart';

abstract class XueHuaNaviteBackgroundDownloaderPlatform extends PlatformInterface {
  /// Constructs a XueHuaNaviteBackgroundDownloaderPlatform.
  XueHuaNaviteBackgroundDownloaderPlatform() : super(token: _token);

  static final Object _token = Object();

  static XueHuaNaviteBackgroundDownloaderPlatform _instance = MethodChannelXueHuaNaviteBackgroundDownloader();

  /// The default instance of [XueHuaNaviteBackgroundDownloaderPlatform] to use.
  ///
  /// Defaults to [MethodChannelXueHuaNaviteBackgroundDownloader].
  static XueHuaNaviteBackgroundDownloaderPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [XueHuaNaviteBackgroundDownloaderPlatform] when
  /// they register themselves.
  static set instance(XueHuaNaviteBackgroundDownloaderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
