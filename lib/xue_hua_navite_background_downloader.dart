
import 'xue_hua_navite_background_downloader_platform_interface.dart';

class XueHuaNaviteBackgroundDownloader {
  Future<String?> getPlatformVersion() {
    return XueHuaNaviteBackgroundDownloaderPlatform.instance.getPlatformVersion();
  }
}
