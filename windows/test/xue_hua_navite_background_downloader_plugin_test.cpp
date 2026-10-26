#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "xue_hua_navite_background_downloader_plugin.h"

namespace xue_hua_navite_background_downloader {
namespace test {

TEST(XueHuaNaviteBackgroundDownloaderPlugin, GetCapabilities) {
  XueHuaNaviteBackgroundDownloaderPlugin plugin;
  flutter::EncodableMap result_map;
  plugin.HandleMethodCall(
      flutter::MethodCall("getCapabilities",
                          std::make_unique<flutter::EncodableValue>()),
      std::make_unique<flutter::MethodResultFunctions<>>(
          [&result_map](const flutter::EncodableValue* value) {
            result_map = std::get<flutter::EncodableMap>(*value);
          },
          nullptr, nullptr));

  auto it = result_map.find(flutter::EncodableValue("platform"));
  ASSERT_NE(it, result_map.end());
  EXPECT_EQ(std::get<std::string>(it->second), "windows");

  auto store = result_map.find(flutter::EncodableValue("taskStorePath"));
  ASSERT_NE(store, result_map.end());
  const auto& store_path = std::get<std::string>(store->second);
  EXPECT_NE(store_path.find("xue_hua_downloader_tasks.tsv"), std::string::npos);
}

}  // namespace test
}  // namespace xue_hua_navite_background_downloader
