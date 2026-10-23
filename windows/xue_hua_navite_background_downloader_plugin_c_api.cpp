#include "include/xue_hua_navite_background_downloader/xue_hua_navite_background_downloader_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "xue_hua_navite_background_downloader_plugin.h"

void XueHuaNaviteBackgroundDownloaderPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  xue_hua_navite_background_downloader::XueHuaNaviteBackgroundDownloaderPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
