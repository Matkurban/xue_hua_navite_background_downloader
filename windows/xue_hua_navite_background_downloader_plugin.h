#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace xue_hua_navite_background_downloader {

class XueHuaNaviteBackgroundDownloaderPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  XueHuaNaviteBackgroundDownloaderPlugin();

  virtual ~XueHuaNaviteBackgroundDownloaderPlugin();

  // Disallow copy and assign.
  XueHuaNaviteBackgroundDownloaderPlugin(const XueHuaNaviteBackgroundDownloaderPlugin&) = delete;
  XueHuaNaviteBackgroundDownloaderPlugin& operator=(const XueHuaNaviteBackgroundDownloaderPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace xue_hua_navite_background_downloader

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN_H_
