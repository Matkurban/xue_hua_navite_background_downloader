//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <xue_hua_navite_background_downloader/xue_hua_navite_background_downloader_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) xue_hua_navite_background_downloader_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "XueHuaNaviteBackgroundDownloaderPlugin");
  xue_hua_navite_background_downloader_plugin_register_with_registrar(xue_hua_navite_background_downloader_registrar);
}
