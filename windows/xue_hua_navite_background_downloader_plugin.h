#ifndef FLUTTER_PLUGIN_XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace xue_hua_navite_background_downloader {

struct NotificationConfigRecord {
  bool enabled = true;
  std::string title;
  std::string running_body;
  std::string completed_body;
  std::string failed_body;
  bool show_progress = true;

  flutter::EncodableMap ToMap() const;
  static NotificationConfigRecord FromMap(const flutter::EncodableMap* map);
};

struct ErrorRecord {
  bool has_error = false;
  std::string code;
  std::string message;
  int http_status_code = 0;
  bool has_http_status = false;
  bool is_recoverable = true;

  flutter::EncodableMap ToMap() const;
};

struct TaskRecord {
  std::string task_id;
  std::string url;
  std::string save_directory;
  std::string file_name;
  std::string save_path;
  std::string status = "queued";
  std::string group = "default";
  std::string priority = "normal";
  std::string conflict_resolution = "overwrite";
  std::string method = "GET";
  std::string post_body;
  int64_t downloaded_bytes = 0;
  int64_t total_bytes = -1;
  double progress = 0.0;
  double bytes_per_second = 0.0;
  int64_t estimated_remaining_ms = -1;
  int retry_count = 0;
  int max_retries = 2;
  bool supports_resume = true;
  bool allow_pause = true;
  bool requires_unmetered_network = false;
  std::string expected_checksum;
  std::string checksum_algorithm = "sha256";
  std::string computed_checksum;
  std::string mime_type;
  std::string etag;
  ErrorRecord error;
  int64_t created_at_ms = 0;
  int64_t updated_at_ms = 0;
  int64_t completed_at_ms = 0;
  std::map<std::string, std::string> headers;
  std::map<std::string, std::string> metadata;
  NotificationConfigRecord notification_config;

  flutter::EncodableMap ToMap() const;
};

/// Native multi-task background downloader plugin for Windows using WinHTTP and CNG BCrypt.
class XueHuaNaviteBackgroundDownloaderPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  XueHuaNaviteBackgroundDownloaderPlugin();

  virtual ~XueHuaNaviteBackgroundDownloaderPlugin();

  XueHuaNaviteBackgroundDownloaderPlugin(
      const XueHuaNaviteBackgroundDownloaderPlugin&) = delete;
  XueHuaNaviteBackgroundDownloaderPlugin& operator=(
      const XueHuaNaviteBackgroundDownloaderPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  TaskRecord CreateOrResetTaskLocked(const flutter::EncodableMap& args);
  TaskRecord* PauseLocked(const std::string& task_id);
  TaskRecord* ResumeLocked(const std::string& task_id);
  TaskRecord* CancelLocked(const std::string& task_id, bool delete_partial);
  TaskRecord* RetryLocked(const std::string& task_id);
  bool RemoveTaskLocked(const std::string& task_id, bool delete_file);

  void ScheduleQueueLocked();
  void RunDownloadWorker(std::string task_id,
                         std::shared_ptr<std::atomic<bool>> stop_flag);
  void EmitTaskUpdate(const TaskRecord& record);
  void StartEventDispatcher();
  void StopEventDispatcher();
  void FlushTaskUpdates();
  static LRESULT CALLBACK EventDispatcherWndProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam);
  void ShowSystemNotification(const TaskRecord& record);

  void PersistTasksLocked();
  void LoadPersistedTasksLocked();
  std::string GetPersistenceFilePath() const;
  std::string GetDefaultDownloadDirectory() const;

  mutable std::mutex state_mutex_;
  std::mutex sink_mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  // EventChannel sends must run on the Flutter platform thread. Download
  // workers queue encoded updates here and wake this message-only window,
  // which is created on the platform thread. Flutter 3.47 exposes
  // PostPlatformThreadTask on the engine only, not on PluginRegistrarWindows.
  HWND event_hwnd_ = nullptr;
  std::mutex event_queue_mutex_;
  std::vector<flutter::EncodableValue> pending_events_;
  bool event_dispatch_posted_ = false;
  bool dispatcher_alive_ = false;

  int max_concurrent_tasks_ = 3;
  int connect_timeout_ms_ = 15000;
  int read_timeout_ms_ = 30000;
  int64_t progress_update_interval_ms_ = 250;
  bool enable_notifications_ = true;
  std::string user_agent_ = "XueHuaNativeBackgroundDownloader/1.0.0";
  std::map<std::string, std::string> default_headers_;
  bool auto_resume_on_startup_ = false;

  std::map<std::string, TaskRecord> tasks_;
  std::map<std::string, std::shared_ptr<std::atomic<bool>>> active_stop_flags_;
  std::atomic<bool> shutting_down_{false};
};

}  // namespace xue_hua_navite_background_downloader

#endif  // FLUTTER_PLUGIN_XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN_H_
