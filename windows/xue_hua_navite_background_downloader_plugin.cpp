#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "xue_hua_navite_background_downloader_plugin.h"

#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <shlobj.h>
#include <winhttp.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>

namespace fs = std::filesystem;

namespace xue_hua_navite_background_downloader {

namespace {

constexpr wchar_t kEventWindowClassName[] =
    L"XueHuaNaviteBackgroundDownloaderEventWindow";
// Private to the message-only window this plugin creates on the platform
// thread. WM_APP keeps it out of the WM_USER range used by other windows.
constexpr UINT kEventFlushMessage = WM_APP + 0x4855;

int64_t NowMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, str.data(),
                                        static_cast<int>(str.size()), nullptr, 0);
  if (size_needed <= 0) return std::wstring();
  std::wstring result(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                      &result[0], size_needed);
  return result;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size_needed = WideCharToMultiByte(
      CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()), nullptr, 0,
      nullptr, nullptr);
  if (size_needed <= 0) return std::string();
  std::string result(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
                      &result[0], size_needed, nullptr, nullptr);
  return result;
}

std::string GetStringArg(const flutter::EncodableMap& map,
                         const std::string& key,
                         const std::string& fallback = "") {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return fallback;
}

bool GetBoolArg(const flutter::EncodableMap& map,
                const std::string& key,
                bool fallback = false) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return fallback;
}

int GetIntArg(const flutter::EncodableMap& map,
              const std::string& key,
              int fallback = 0) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end()) {
    if (std::holds_alternative<int32_t>(it->second)) {
      return std::get<int32_t>(it->second);
    }
    if (std::holds_alternative<int64_t>(it->second)) {
      return static_cast<int>(std::get<int64_t>(it->second));
    }
  }
  return fallback;
}

int PriorityLevel(const std::string& p) {
  if (p == "critical") return 3;
  if (p == "high") return 2;
  if (p == "normal") return 1;
  return 0;
}

std::string SanitizeFileName(const std::string& name) {
  std::string out = name;
  for (char& c : out) {
    if (c == '\\' || c == '/' || c == ':' || c == '*' || c == '?' ||
        c == '"' || c == '<' || c == '>' || c == '|') {
      c = '_';
    }
  }
  if (out.empty()) {
    return "download_" + std::to_string(NowMs()) + ".bin";
  }
  return out;
}

std::string InferFileNameFromUrl(const std::string& url) {
  auto qpos = url.find('?');
  std::string clean = (qpos == std::string::npos) ? url : url.substr(0, qpos);
  auto slash = clean.find_last_of('/');
  if (slash != std::string::npos && slash + 1 < clean.size()) {
    return SanitizeFileName(clean.substr(slash + 1));
  }
  return "download_" + std::to_string(NowMs()) + ".bin";
}

fs::path ResolveDestinationPath(const fs::path& dir,
                                const std::string& file_name,
                                const std::string& conflict_resolution) {
  fs::path initial = dir / fs::u8path(file_name);
  if (conflict_resolution != "uniqueName" || !fs::exists(initial)) {
    return initial;
  }
  fs::path stem = initial.stem();
  fs::path ext = initial.extension();
  int counter = 1;
  while (true) {
    std::string candidate_name =
        stem.u8string() + " (" + std::to_string(counter) + ")" + ext.u8string();
    fs::path candidate = dir / fs::u8path(candidate_name);
    fs::path part = fs::u8path(candidate.u8string() + ".part");
    if (!fs::exists(candidate) && !fs::exists(part)) {
      return candidate;
    }
    counter++;
  }
}

std::string GenerateTaskId() {
  static std::atomic<uint64_t> seq{1};
  std::ostringstream oss;
  oss << "win_dl_" << NowMs() << "_" << seq.fetch_add(1);
  return oss.str();
}

std::string ComputeFileChecksum(const fs::path& path,
                                const std::string& algorithm) {
  LPCWSTR alg_id = (algorithm == "md5" || algorithm == "MD5")
                       ? BCRYPT_MD5_ALGORITHM
                       : BCRYPT_SHA256_ALGORITHM;
  BCRYPT_ALG_HANDLE hAlg = nullptr;
  BCRYPT_HASH_HANDLE hHash = nullptr;
  if (BCryptOpenAlgorithmProvider(&hAlg, alg_id, nullptr, 0) != 0) {
    return "";
  }

  DWORD hash_obj_size = 0;
  DWORD data_len = 0;
  BCryptGetProperty(hAlg, BCRYPT_OBJECT_LENGTH,
                    reinterpret_cast<PUCHAR>(&hash_obj_size), sizeof(DWORD),
                    &data_len, 0);
  DWORD hash_len = 0;
  BCryptGetProperty(hAlg, BCRYPT_HASH_LENGTH,
                    reinterpret_cast<PUCHAR>(&hash_len), sizeof(DWORD),
                    &data_len, 0);

  std::vector<UCHAR> hash_obj(hash_obj_size);
  std::vector<UCHAR> hash_val(hash_len);

  if (BCryptCreateHash(hAlg, &hHash, hash_obj.data(), hash_obj_size, nullptr, 0,
                       0) != 0) {
    BCryptCloseAlgorithmProvider(hAlg, 0);
    return "";
  }

  std::ifstream ifs(path, std::ios::binary);
  if (!ifs.is_open()) {
    BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);
    return "";
  }

  std::vector<char> buffer(32 * 1024);
  while (ifs.good()) {
    ifs.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    std::streamsize read_bytes = ifs.gcount();
    if (read_bytes > 0) {
      BCryptHashData(hHash, reinterpret_cast<PUCHAR>(buffer.data()),
                     static_cast<ULONG>(read_bytes), 0);
    }
  }

  BCryptFinishHash(hHash, hash_val.data(), hash_len, 0);
  BCryptDestroyHash(hHash);
  BCryptCloseAlgorithmProvider(hAlg, 0);

  std::ostringstream hex;
  hex << std::hex << std::setfill('0');
  for (UCHAR b : hash_val) {
    hex << std::setw(2) << static_cast<int>(b);
  }
  return hex.str();
}

}  // namespace

// --- Struct Conversions ---

flutter::EncodableMap NotificationConfigRecord::ToMap() const {
  flutter::EncodableMap m;
  m[flutter::EncodableValue("enabled")] = flutter::EncodableValue(enabled);
  m[flutter::EncodableValue("title")] =
      title.empty() ? flutter::EncodableValue() : flutter::EncodableValue(title);
  m[flutter::EncodableValue("runningBody")] =
      running_body.empty() ? flutter::EncodableValue()
                           : flutter::EncodableValue(running_body);
  m[flutter::EncodableValue("completedBody")] =
      completed_body.empty() ? flutter::EncodableValue()
                             : flutter::EncodableValue(completed_body);
  m[flutter::EncodableValue("failedBody")] =
      failed_body.empty() ? flutter::EncodableValue()
                          : flutter::EncodableValue(failed_body);
  m[flutter::EncodableValue("showProgress")] =
      flutter::EncodableValue(show_progress);
  return m;
}

NotificationConfigRecord NotificationConfigRecord::FromMap(
    const flutter::EncodableMap* map) {
  NotificationConfigRecord cfg;
  if (!map) return cfg;
  cfg.enabled = GetBoolArg(*map, "enabled", true);
  cfg.title = GetStringArg(*map, "title", "");
  cfg.running_body = GetStringArg(*map, "runningBody", "");
  cfg.completed_body = GetStringArg(*map, "completedBody", "");
  cfg.failed_body = GetStringArg(*map, "failedBody", "");
  cfg.show_progress = GetBoolArg(*map, "showProgress", true);
  return cfg;
}

flutter::EncodableMap ErrorRecord::ToMap() const {
  flutter::EncodableMap m;
  m[flutter::EncodableValue("code")] = flutter::EncodableValue(code);
  m[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
  if (has_http_status) {
    m[flutter::EncodableValue("httpStatusCode")] =
        flutter::EncodableValue(http_status_code);
  } else {
    m[flutter::EncodableValue("httpStatusCode")] = flutter::EncodableValue();
  }
  m[flutter::EncodableValue("isRecoverable")] =
      flutter::EncodableValue(is_recoverable);
  return m;
}

flutter::EncodableMap TaskRecord::ToMap() const {
  flutter::EncodableMap m;
  m[flutter::EncodableValue("taskId")] = flutter::EncodableValue(task_id);
  m[flutter::EncodableValue("url")] = flutter::EncodableValue(url);
  m[flutter::EncodableValue("saveDirectory")] =
      flutter::EncodableValue(save_directory);
  m[flutter::EncodableValue("fileName")] = flutter::EncodableValue(file_name);
  m[flutter::EncodableValue("savePath")] = flutter::EncodableValue(save_path);
  m[flutter::EncodableValue("status")] = flutter::EncodableValue(status);
  m[flutter::EncodableValue("group")] = flutter::EncodableValue(group);
  m[flutter::EncodableValue("priority")] = flutter::EncodableValue(priority);
  m[flutter::EncodableValue("conflictResolution")] =
      flutter::EncodableValue(conflict_resolution);
  m[flutter::EncodableValue("downloadedBytes")] =
      flutter::EncodableValue(downloaded_bytes);
  m[flutter::EncodableValue("totalBytes")] =
      flutter::EncodableValue(total_bytes);
  m[flutter::EncodableValue("progress")] = flutter::EncodableValue(progress);
  m[flutter::EncodableValue("bytesPerSecond")] =
      flutter::EncodableValue(bytes_per_second);
  m[flutter::EncodableValue("estimatedRemainingMs")] =
      flutter::EncodableValue(estimated_remaining_ms);
  m[flutter::EncodableValue("retryCount")] =
      flutter::EncodableValue(retry_count);
  m[flutter::EncodableValue("maxRetries")] =
      flutter::EncodableValue(max_retries);
  m[flutter::EncodableValue("supportsResume")] =
      flutter::EncodableValue(supports_resume);
  m[flutter::EncodableValue("requiresUnmeteredNetwork")] =
      flutter::EncodableValue(requires_unmetered_network);
  m[flutter::EncodableValue("expectedChecksum")] =
      expected_checksum.empty() ? flutter::EncodableValue()
                                : flutter::EncodableValue(expected_checksum);
  m[flutter::EncodableValue("checksumAlgorithm")] =
      flutter::EncodableValue(checksum_algorithm);
  m[flutter::EncodableValue("computedChecksum")] =
      computed_checksum.empty() ? flutter::EncodableValue()
                                : flutter::EncodableValue(computed_checksum);
  m[flutter::EncodableValue("mimeType")] =
      mime_type.empty() ? flutter::EncodableValue()
                        : flutter::EncodableValue(mime_type);
  m[flutter::EncodableValue("eTag")] =
      etag.empty() ? flutter::EncodableValue() : flutter::EncodableValue(etag);
  m[flutter::EncodableValue("error")] =
      error.has_error ? flutter::EncodableValue(error.ToMap())
                      : flutter::EncodableValue();
  m[flutter::EncodableValue("createdAtMs")] =
      flutter::EncodableValue(created_at_ms);
  m[flutter::EncodableValue("updatedAtMs")] =
      flutter::EncodableValue(updated_at_ms);
  m[flutter::EncodableValue("completedAtMs")] =
      completed_at_ms > 0 ? flutter::EncodableValue(completed_at_ms)
                          : flutter::EncodableValue();

  flutter::EncodableMap h_map;
  for (const auto& kv : headers) {
    h_map[flutter::EncodableValue(kv.first)] =
        flutter::EncodableValue(kv.second);
  }
  m[flutter::EncodableValue("headers")] = flutter::EncodableValue(h_map);

  flutter::EncodableMap meta_map;
  for (const auto& kv : metadata) {
    meta_map[flutter::EncodableValue(kv.first)] =
        flutter::EncodableValue(kv.second);
  }
  m[flutter::EncodableValue("metadata")] = flutter::EncodableValue(meta_map);
  m[flutter::EncodableValue("notificationConfig")] =
      flutter::EncodableValue(notification_config.ToMap());
  return m;
}

// --- Plugin Implementation ---

void XueHuaNaviteBackgroundDownloaderPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(),
          "com.kurban.xue_hua_navite_background_downloader/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(),
          "com.kurban.xue_hua_navite_background_downloader/events",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<XueHuaNaviteBackgroundDownloaderPlugin>();
  auto* plugin_ptr = plugin.get();

  method_channel->SetMethodCallHandler(
      [plugin_ptr](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  auto handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_ptr](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(plugin_ptr->sink_mutex_);
        plugin_ptr->event_sink_ = std::move(events);
        return nullptr;
      },
      [plugin_ptr](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(plugin_ptr->sink_mutex_);
        plugin_ptr->event_sink_.reset();
        return nullptr;
      });
  event_channel->SetStreamHandler(std::move(handler));

  plugin_ptr->StartEventDispatcher();
  registrar->AddPlugin(std::move(plugin));
}

XueHuaNaviteBackgroundDownloaderPlugin::XueHuaNaviteBackgroundDownloaderPlugin() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  LoadPersistedTasksLocked();
}

XueHuaNaviteBackgroundDownloaderPlugin::~XueHuaNaviteBackgroundDownloaderPlugin() {
  shutting_down_.store(true);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (auto& kv : active_stop_flags_) {
      kv.second->store(true);
    }
  }
  StopEventDispatcher();
}

void XueHuaNaviteBackgroundDownloaderPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const auto* args =
      std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "configure") {
    if (args) {
      std::lock_guard<std::mutex> lock(state_mutex_);
      max_concurrent_tasks_ =
          std::clamp(GetIntArg(*args, "maxConcurrentTasks", 3), 1, 16);
      connect_timeout_ms_ =
          (std::max)(1000, GetIntArg(*args, "connectTimeoutMs", 15000));
      read_timeout_ms_ =
          (std::max)(1000, GetIntArg(*args, "readTimeoutMs", 30000));
      progress_update_interval_ms_ = (std::max<int64_t>)(
          50, GetIntArg(*args, "progressUpdateIntervalMs", 250));
      enable_notifications_ = GetBoolArg(*args, "enableNotifications", true);
      user_agent_ = GetStringArg(
          *args, "userAgent", "XueHuaNativeBackgroundDownloader/1.0.0");
      auto_resume_on_startup_ = GetBoolArg(*args, "autoResumeOnStartup", false);

      auto hit = args->find(flutter::EncodableValue("defaultHeaders"));
      if (hit != args->end() &&
          std::holds_alternative<flutter::EncodableMap>(hit->second)) {
        default_headers_.clear();
        for (const auto& kv : std::get<flutter::EncodableMap>(hit->second)) {
          if (std::holds_alternative<std::string>(kv.first) &&
              std::holds_alternative<std::string>(kv.second)) {
            default_headers_[std::get<std::string>(kv.first)] =
                std::get<std::string>(kv.second);
          }
        }
      }
      ScheduleQueueLocked();
    }
    result->Success();
    return;
  }

  if (method == "getCapabilities") {
    flutter::EncodableMap caps;
    caps[flutter::EncodableValue("platform")] =
        flutter::EncodableValue("windows");
    caps[flutter::EncodableValue("nativeEngine")] =
        flutter::EncodableValue("WinHTTP + CNG BCrypt");
    caps[flutter::EncodableValue("supportsBackgroundExecution")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsPauseResume")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsSystemNotifications")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsPersistence")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsChecksumVerification")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("supportsNetworkConstraints")] =
        flutter::EncodableValue(true);
    caps[flutter::EncodableValue("defaultDownloadDirectory")] =
        flutter::EncodableValue(GetDefaultDownloadDirectory());
    result->Success(flutter::EncodableValue(caps));
    return;
  }

  if (method == "requestNotificationPermission") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "enqueue") {
    if (!args) {
      result->Error("invalid_arguments", "Expected request map");
      return;
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    TaskRecord rec = CreateOrResetTaskLocked(*args);
    ScheduleQueueLocked();
    result->Success(flutter::EncodableValue(rec.ToMap()));
    return;
  }

  if (method == "enqueueAll") {
    flutter::EncodableList created;
    if (args) {
      auto it = args->find(flutter::EncodableValue("requests"));
      if (it != args->end() &&
          std::holds_alternative<flutter::EncodableList>(it->second)) {
        std::lock_guard<std::mutex> lock(state_mutex_);
        for (const auto& item :
             std::get<flutter::EncodableList>(it->second)) {
          if (std::holds_alternative<flutter::EncodableMap>(item)) {
            TaskRecord rec = CreateOrResetTaskLocked(
                std::get<flutter::EncodableMap>(item));
            created.push_back(flutter::EncodableValue(rec.ToMap()));
          }
        }
        ScheduleQueueLocked();
      }
    }
    result->Success(flutter::EncodableValue(created));
    return;
  }

  if (method == "pause") {
    std::string task_id = args ? GetStringArg(*args, "taskId") : "";
    std::lock_guard<std::mutex> lock(state_mutex_);
    TaskRecord* rec = PauseLocked(task_id);
    ScheduleQueueLocked();
    if (rec) {
      result->Success(flutter::EncodableValue(rec->ToMap()));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "resume") {
    std::string task_id = args ? GetStringArg(*args, "taskId") : "";
    std::lock_guard<std::mutex> lock(state_mutex_);
    TaskRecord* rec = ResumeLocked(task_id);
    ScheduleQueueLocked();
    if (rec) {
      result->Success(flutter::EncodableValue(rec->ToMap()));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "cancel") {
    std::string task_id = args ? GetStringArg(*args, "taskId") : "";
    bool del = args ? GetBoolArg(*args, "deletePartialFile", true) : true;
    std::lock_guard<std::mutex> lock(state_mutex_);
    TaskRecord* rec = CancelLocked(task_id, del);
    ScheduleQueueLocked();
    if (rec) {
      result->Success(flutter::EncodableValue(rec->ToMap()));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "retry") {
    std::string task_id = args ? GetStringArg(*args, "taskId") : "";
    std::lock_guard<std::mutex> lock(state_mutex_);
    TaskRecord* rec = RetryLocked(task_id);
    ScheduleQueueLocked();
    if (rec) {
      result->Success(flutter::EncodableValue(rec->ToMap()));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "removeTask") {
    std::string task_id = args ? GetStringArg(*args, "taskId") : "";
    bool del = args ? GetBoolArg(*args, "deleteFile", false) : false;
    std::lock_guard<std::mutex> lock(state_mutex_);
    bool ok = RemoveTaskLocked(task_id, del);
    ScheduleQueueLocked();
    result->Success(flutter::EncodableValue(ok));
    return;
  }

  if (method == "pauseAll") {
    std::string group = args ? GetStringArg(*args, "group") : "";
    flutter::EncodableList list;
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (auto& kv : tasks_) {
      if (!group.empty() && kv.second.group != group) continue;
      if (kv.second.status == "queued" || kv.second.status == "running") {
        if (TaskRecord* p = PauseLocked(kv.first)) {
          list.push_back(flutter::EncodableValue(p->ToMap()));
        }
      }
    }
    ScheduleQueueLocked();
    result->Success(flutter::EncodableValue(list));
    return;
  }

  if (method == "resumeAll") {
    std::string group = args ? GetStringArg(*args, "group") : "";
    flutter::EncodableList list;
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (auto& kv : tasks_) {
      if (!group.empty() && kv.second.group != group) continue;
      if (kv.second.status == "paused") {
        if (TaskRecord* r = ResumeLocked(kv.first)) {
          list.push_back(flutter::EncodableValue(r->ToMap()));
        }
      }
    }
    ScheduleQueueLocked();
    result->Success(flutter::EncodableValue(list));
    return;
  }

  if (method == "cancelAll") {
    std::string group = args ? GetStringArg(*args, "group") : "";
    bool del = args ? GetBoolArg(*args, "deletePartialFiles", true) : true;
    flutter::EncodableList list;
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (auto& kv : tasks_) {
      if (!group.empty() && kv.second.group != group) continue;
      if (kv.second.status == "queued" || kv.second.status == "running" ||
          kv.second.status == "paused") {
        if (TaskRecord* c = CancelLocked(kv.first, del)) {
          list.push_back(flutter::EncodableValue(c->ToMap()));
        }
      }
    }
    ScheduleQueueLocked();
    result->Success(flutter::EncodableValue(list));
    return;
  }

  if (method == "clearCompleted") {
    std::string group = args ? GetStringArg(*args, "group") : "";
    bool del = args ? GetBoolArg(*args, "deleteFiles", false) : false;
    int removed_count = 0;
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (auto it = tasks_.begin(); it != tasks_.end();) {
      if ((group.empty() || it->second.group == group) &&
          it->second.status == "completed") {
        if (del) {
          std::error_code ec;
          fs::remove(fs::u8path(it->second.save_path), ec);
        }
        it = tasks_.erase(it);
        removed_count++;
      } else {
        ++it;
      }
    }
    if (removed_count > 0) PersistTasksLocked();
    result->Success(flutter::EncodableValue(removed_count));
    return;
  }

  if (method == "getTask") {
    std::string task_id = args ? GetStringArg(*args, "taskId") : "";
    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = tasks_.find(task_id);
    if (it != tasks_.end()) {
      result->Success(flutter::EncodableValue(it->second.ToMap()));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "getAllTasks") {
    std::string group = args ? GetStringArg(*args, "group") : "";
    flutter::EncodableList list;
    std::lock_guard<std::mutex> lock(state_mutex_);
    for (const auto& kv : tasks_) {
      if (!group.empty() && kv.second.group != group) continue;
      list.push_back(flutter::EncodableValue(kv.second.ToMap()));
    }
    result->Success(flutter::EncodableValue(list));
    return;
  }

  result->NotImplemented();
}

TaskRecord XueHuaNaviteBackgroundDownloaderPlugin::CreateOrResetTaskLocked(
    const flutter::EncodableMap& args) {
  std::string url = GetStringArg(args, "url");
  std::string task_id = GetStringArg(args, "taskId");
  if (task_id.empty()) task_id = GenerateTaskId();

  auto active_it = active_stop_flags_.find(task_id);
  if (active_it != active_stop_flags_.end()) {
    active_it->second->store(true);
    active_stop_flags_.erase(active_it);
  }

  std::string raw_dir = GetStringArg(args, "saveDirectory");
  if (raw_dir.empty()) raw_dir = GetDefaultDownloadDirectory();
  fs::path dir_path = fs::u8path(raw_dir);
  std::error_code ec;
  fs::create_directories(dir_path, ec);

  std::string file_name = GetStringArg(args, "fileName");
  if (file_name.empty()) {
    file_name = InferFileNameFromUrl(url);
  } else {
    file_name = SanitizeFileName(file_name);
  }

  std::string conflict = GetStringArg(args, "conflictResolution", "overwrite");
  fs::path final_path = ResolveDestinationPath(dir_path, file_name, conflict);

  TaskRecord rec;
  rec.task_id = task_id;
  rec.url = url;
  rec.save_directory = dir_path.u8string();
  rec.file_name = final_path.filename().u8string();
  rec.save_path = final_path.u8string();
  rec.status = "queued";
  rec.group = GetStringArg(args, "group", "default");
  rec.priority = GetStringArg(args, "priority", "normal");
  rec.conflict_resolution = conflict;
  rec.method = GetStringArg(args, "method", "GET");
  rec.post_body = GetStringArg(args, "postBody", "");
  rec.max_retries = (std::max)(0, GetIntArg(args, "maxRetries", 2));
  rec.allow_pause = GetBoolArg(args, "allowPause", true);
  rec.supports_resume = rec.allow_pause;
  rec.requires_unmetered_network =
      GetBoolArg(args, "requiresUnmeteredNetwork", false);
  rec.expected_checksum = GetStringArg(args, "expectedChecksum", "");
  rec.checksum_algorithm = GetStringArg(args, "checksumAlgorithm", "sha256");
  rec.created_at_ms = NowMs();
  rec.updated_at_ms = rec.created_at_ms;

  rec.headers = default_headers_;
  auto hit = args.find(flutter::EncodableValue("headers"));
  if (hit != args.end() &&
      std::holds_alternative<flutter::EncodableMap>(hit->second)) {
    for (const auto& kv : std::get<flutter::EncodableMap>(hit->second)) {
      if (std::holds_alternative<std::string>(kv.first) &&
          std::holds_alternative<std::string>(kv.second)) {
        rec.headers[std::get<std::string>(kv.first)] =
            std::get<std::string>(kv.second);
      }
    }
  }

  auto mit = args.find(flutter::EncodableValue("metadata"));
  if (mit != args.end() &&
      std::holds_alternative<flutter::EncodableMap>(mit->second)) {
    for (const auto& kv : std::get<flutter::EncodableMap>(mit->second)) {
      if (std::holds_alternative<std::string>(kv.first) &&
          std::holds_alternative<std::string>(kv.second)) {
        rec.metadata[std::get<std::string>(kv.first)] =
            std::get<std::string>(kv.second);
      }
    }
  }

  auto nit = args.find(flutter::EncodableValue("notificationConfig"));
  if (nit != args.end() &&
      std::holds_alternative<flutter::EncodableMap>(nit->second)) {
    rec.notification_config = NotificationConfigRecord::FromMap(
        &std::get<flutter::EncodableMap>(nit->second));
  }

  tasks_[task_id] = rec;
  PersistTasksLocked();
  EmitTaskUpdate(rec);
  return rec;
}

TaskRecord* XueHuaNaviteBackgroundDownloaderPlugin::PauseLocked(
    const std::string& task_id) {
  auto it = tasks_.find(task_id);
  if (it == tasks_.end()) return nullptr;
  TaskRecord& rec = it->second;
  if (rec.status != "running" && rec.status != "queued") return &rec;

  auto stop_it = active_stop_flags_.find(task_id);
  if (stop_it != active_stop_flags_.end()) {
    // The worker erases the flag when it exits. Dropping it here lets
    // ScheduleQueueLocked start another transfer while this one is still
    // draining, so maxConcurrentTasks is exceeded and resume can open a
    // second writer on the same .part file.
    stop_it->second->store(true);
  }

  rec.status = "paused";
  rec.bytes_per_second = 0.0;
  rec.estimated_remaining_ms = -1;
  rec.updated_at_ms = NowMs();
  PersistTasksLocked();
  EmitTaskUpdate(rec);
  return &rec;
}

TaskRecord* XueHuaNaviteBackgroundDownloaderPlugin::ResumeLocked(
    const std::string& task_id) {
  auto it = tasks_.find(task_id);
  if (it == tasks_.end()) return nullptr;
  TaskRecord& rec = it->second;
  if (rec.status != "paused" && rec.status != "failed") return &rec;

  fs::path part_path = fs::u8path(rec.save_path + ".part");
  std::error_code ec;
  if (fs::exists(part_path, ec)) {
    rec.downloaded_bytes = static_cast<int64_t>(fs::file_size(part_path, ec));
  } else {
    rec.downloaded_bytes = 0;
    rec.etag.clear();
  }
  rec.status = "queued";
  rec.error = ErrorRecord{};
  rec.updated_at_ms = NowMs();
  PersistTasksLocked();
  EmitTaskUpdate(rec);
  return &rec;
}

TaskRecord* XueHuaNaviteBackgroundDownloaderPlugin::CancelLocked(
    const std::string& task_id, bool delete_partial) {
  auto it = tasks_.find(task_id);
  if (it == tasks_.end()) return nullptr;
  TaskRecord& rec = it->second;
  if (rec.status == "completed" || rec.status == "canceled") return &rec;

  auto stop_it = active_stop_flags_.find(task_id);
  if (stop_it != active_stop_flags_.end()) {
    stop_it->second->store(true);
  }

  if (delete_partial) {
    std::error_code ec;
    fs::remove(fs::u8path(rec.save_path + ".part"), ec);
    rec.downloaded_bytes = 0;
    rec.progress = 0.0;
  }

  rec.status = "canceled";
  rec.bytes_per_second = 0.0;
  rec.estimated_remaining_ms = -1;
  rec.updated_at_ms = NowMs();
  PersistTasksLocked();
  EmitTaskUpdate(rec);
  return &rec;
}

TaskRecord* XueHuaNaviteBackgroundDownloaderPlugin::RetryLocked(
    const std::string& task_id) {
  auto it = tasks_.find(task_id);
  if (it == tasks_.end()) return nullptr;
  TaskRecord& rec = it->second;

  auto stop_it = active_stop_flags_.find(task_id);
  if (stop_it != active_stop_flags_.end()) {
    stop_it->second->store(true);
  }

  fs::path part_path = fs::u8path(rec.save_path + ".part");
  std::error_code ec;
  if (rec.allow_pause && fs::exists(part_path, ec)) {
    rec.downloaded_bytes = static_cast<int64_t>(fs::file_size(part_path, ec));
  } else {
    fs::remove(part_path, ec);
    rec.downloaded_bytes = 0;
    rec.progress = 0.0;
    rec.etag.clear();
  }

  rec.status = "queued";
  rec.retry_count = 0;
  rec.error = ErrorRecord{};
  rec.bytes_per_second = 0.0;
  rec.estimated_remaining_ms = -1;
  rec.updated_at_ms = NowMs();
  PersistTasksLocked();
  EmitTaskUpdate(rec);
  return &rec;
}

bool XueHuaNaviteBackgroundDownloaderPlugin::RemoveTaskLocked(
    const std::string& task_id, bool delete_file) {
  auto stop_it = active_stop_flags_.find(task_id);
  if (stop_it != active_stop_flags_.end()) {
    stop_it->second->store(true);
  }
  auto it = tasks_.find(task_id);
  if (it == tasks_.end()) return false;
  std::error_code ec;
  fs::remove(fs::u8path(it->second.save_path + ".part"), ec);
  if (delete_file) {
    fs::remove(fs::u8path(it->second.save_path), ec);
  }
  tasks_.erase(it);
  PersistTasksLocked();
  return true;
}

void XueHuaNaviteBackgroundDownloaderPlugin::ScheduleQueueLocked() {
  int running_count = static_cast<int>(active_stop_flags_.size());
  int available = max_concurrent_tasks_ - running_count;
  if (available <= 0) return;

  std::vector<TaskRecord*> candidates;
  for (auto& kv : tasks_) {
    if (kv.second.status == "queued" &&
        active_stop_flags_.find(kv.first) == active_stop_flags_.end()) {
      candidates.push_back(&kv.second);
    }
  }

  std::sort(candidates.begin(), candidates.end(),
            [](const TaskRecord* a, const TaskRecord* b) {
              int pa = PriorityLevel(a->priority);
              int pb = PriorityLevel(b->priority);
              if (pa != pb) return pa > pb;
              return a->created_at_ms < b->created_at_ms;
            });

  int count = (std::min)(available, static_cast<int>(candidates.size()));
  for (int i = 0; i < count; ++i) {
    TaskRecord* rec = candidates[i];
    rec->status = "running";
    rec->updated_at_ms = NowMs();
    EmitTaskUpdate(*rec);

    auto stop_flag = std::make_shared<std::atomic<bool>>(false);
    active_stop_flags_[rec->task_id] = stop_flag;
    std::string tid = rec->task_id;
    std::thread([this, tid, stop_flag]() {
      RunDownloadWorker(tid, stop_flag);
    }).detach();
  }
}

void XueHuaNaviteBackgroundDownloaderPlugin::RunDownloadWorker(
    std::string task_id, std::shared_ptr<std::atomic<bool>> stop_flag) {
  TaskRecord snapshot;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = tasks_.find(task_id);
    if (it == tasks_.end()) return;
    snapshot = it->second;
  }

  fs::path dest_path = fs::u8path(snapshot.save_path);
  fs::path part_path = fs::u8path(snapshot.save_path + ".part");
  std::error_code ec;
  fs::create_directories(dest_path.parent_path(), ec);

  if (fs::exists(dest_path, ec)) {
    if (snapshot.conflict_resolution == "skip") {
      int64_t sz = static_cast<int64_t>(fs::file_size(dest_path, ec));
      std::lock_guard<std::mutex> lock(state_mutex_);
      auto it = tasks_.find(task_id);
      if (it != tasks_.end()) {
        it->second.downloaded_bytes = sz;
        it->second.total_bytes = sz;
        it->second.progress = 1.0;
        it->second.status = "completed";
        it->second.updated_at_ms = NowMs();
        it->second.completed_at_ms = it->second.updated_at_ms;
        PersistTasksLocked();
        EmitTaskUpdate(it->second);
        ShowSystemNotification(it->second);
      }
      active_stop_flags_.erase(task_id);
      ScheduleQueueLocked();
      return;
    } else if (snapshot.conflict_resolution == "fail") {
      std::lock_guard<std::mutex> lock(state_mutex_);
      auto it = tasks_.find(task_id);
      if (it != tasks_.end()) {
        it->second.status = "failed";
        it->second.error = ErrorRecord{true, "file_exists",
                                       "Destination file already exists", 0,
                                       false, false};
        it->second.updated_at_ms = NowMs();
        PersistTasksLocked();
        EmitTaskUpdate(it->second);
        ShowSystemNotification(it->second);
      }
      active_stop_flags_.erase(task_id);
      ScheduleQueueLocked();
      return;
    }
  }

  std::wstring wide_url = Utf8ToWide(snapshot.url);
  URL_COMPONENTS url_comp{};
  url_comp.dwStructSize = sizeof(url_comp);
  wchar_t host_buf[256] = {0};
  wchar_t path_buf[2048] = {0};
  url_comp.lpszHostName = host_buf;
  url_comp.dwHostNameLength = _countof(host_buf);
  url_comp.lpszUrlPath = path_buf;
  url_comp.dwUrlPathLength = _countof(path_buf);

  if (!WinHttpCrackUrl(wide_url.c_str(), static_cast<DWORD>(wide_url.size()), 0,
                       &url_comp)) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = tasks_.find(task_id);
    if (it != tasks_.end()) {
      it->second.status = "failed";
      it->second.error = ErrorRecord{true, "invalid_url",
                                     "Invalid URL format", 0, false, false};
      it->second.updated_at_ms = NowMs();
      PersistTasksLocked();
      EmitTaskUpdate(it->second);
    }
    active_stop_flags_.erase(task_id);
    ScheduleQueueLocked();
    return;
  }

  int64_t existing_offset = 0;
  if (snapshot.allow_pause && fs::exists(part_path, ec)) {
    existing_offset = static_cast<int64_t>(fs::file_size(part_path, ec));
  }

  HINTERNET hSession = WinHttpOpen(
      Utf8ToWide(user_agent_).c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (hSession) {
    WinHttpSetTimeouts(hSession, connect_timeout_ms_, connect_timeout_ms_,
                       read_timeout_ms_, read_timeout_ms_);
  }

  HINTERNET hConnect =
      hSession ? WinHttpConnect(hSession, host_buf, url_comp.nPort, 0)
               : nullptr;
  DWORD flags =
      (url_comp.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
  std::wstring verb = Utf8ToWide(snapshot.method);
  HINTERNET hRequest =
      hConnect ? WinHttpOpenRequest(hConnect, verb.c_str(), path_buf, nullptr,
                                    WINHTTP_NO_REFERER,
                                    WINHTTP_DEFAULT_ACCEPT_TYPES, flags)
               : nullptr;

  bool success = false;
  int status_code = 0;
  std::string err_code = "network_error";
  std::string err_msg = "WinHTTP transfer failed";

  if (hRequest) {
    for (const auto& kv : snapshot.headers) {
      std::wstring header_line = Utf8ToWide(kv.first + ": " + kv.second);
      WinHttpAddRequestHeaders(hRequest, header_line.c_str(),
                               static_cast<DWORD>(-1L),
                               WINHTTP_ADDREQ_FLAG_ADD |
                                   WINHTTP_ADDREQ_FLAG_REPLACE);
    }
    if (existing_offset > 0) {
      std::wstring range_hdr =
          L"Range: bytes=" + std::to_wstring(existing_offset) + L"-";
      WinHttpAddRequestHeaders(hRequest, range_hdr.c_str(),
                               static_cast<DWORD>(-1L),
                               WINHTTP_ADDREQ_FLAG_ADD |
                                   WINHTTP_ADDREQ_FLAG_REPLACE);
    }

    BOOL sent = WinHttpSendRequest(
        hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
        snapshot.post_body.empty()
            ? WINHTTP_NO_REQUEST_DATA
            : const_cast<char*>(snapshot.post_body.data()),
        static_cast<DWORD>(snapshot.post_body.size()),
        static_cast<DWORD>(snapshot.post_body.size()), 0);

    if (sent && WinHttpReceiveResponse(hRequest, nullptr)) {
      DWORD status = 0;
      DWORD sz = sizeof(status);
      WinHttpQueryHeaders(
          hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
          WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz, WINHTTP_NO_HEADER_INDEX);
      status_code = static_cast<int>(status);

      if (status_code >= 200 && status_code < 300) {
        bool is_partial = (status_code == 206 && existing_offset > 0);
        wchar_t cl_buf[64] = {0};
        DWORD cl_len = sizeof(cl_buf);
        int64_t content_len = -1;
        if (WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_CONTENT_LENGTH,
                                WINHTTP_HEADER_NAME_BY_INDEX, cl_buf, &cl_len,
                                WINHTTP_NO_HEADER_INDEX)) {
          content_len = _wtoi64(cl_buf);
        }
        int64_t total_bytes =
            (content_len > 0)
                ? (is_partial ? existing_offset + content_len : content_len)
                : -1;

        std::ofstream ofs(
            part_path,
            std::ios::binary | (is_partial ? std::ios::app : std::ios::trunc));
        int64_t current_bytes = is_partial ? existing_offset : 0;
        int64_t last_emit_ms = NowMs();
        int64_t last_emit_bytes = current_bytes;
        double smoothed_speed = 0.0;

        DWORD avail = 0;
        std::vector<char> buffer(32 * 1024);
        bool io_ok = ofs.is_open();

        while (io_ok && !stop_flag->load() && !shutting_down_.load()) {
          avail = 0;
          if (!WinHttpQueryDataAvailable(hRequest, &avail) || avail == 0) {
            break;
          }
          DWORD to_read =
              (std::min<DWORD>)(avail, static_cast<DWORD>(buffer.size()));
          DWORD bytes_read = 0;
          if (!WinHttpReadData(hRequest, buffer.data(), to_read, &bytes_read) ||
              bytes_read == 0) {
            break;
          }
          ofs.write(buffer.data(), bytes_read);
          current_bytes += bytes_read;

          int64_t now = NowMs();
          int64_t elapsed = now - last_emit_ms;
          if (elapsed >= progress_update_interval_ms_) {
            int64_t delta = current_bytes - last_emit_bytes;
            double inst_speed =
                elapsed > 0 ? (static_cast<double>(delta) * 1000.0 / elapsed)
                            : 0.0;
            smoothed_speed =
                smoothed_speed <= 0.0
                    ? inst_speed
                    : (smoothed_speed * 0.65 + inst_speed * 0.35);

            std::lock_guard<std::mutex> lock(state_mutex_);
            auto it = tasks_.find(task_id);
            if (it != tasks_.end() && it->second.status == "running") {
              it->second.downloaded_bytes = current_bytes;
              it->second.total_bytes = total_bytes;
              it->second.progress =
                  total_bytes > 0
                      ? std::clamp(static_cast<double>(current_bytes) /
                                       static_cast<double>(total_bytes),
                                   0.0, 1.0)
                      : -1.0;
              it->second.bytes_per_second = smoothed_speed;
              it->second.estimated_remaining_ms =
                  (total_bytes > current_bytes && smoothed_speed > 1.0)
                      ? static_cast<int64_t>(
                            (total_bytes - current_bytes) * 1000.0 /
                            smoothed_speed)
                      : -1;
              it->second.updated_at_ms = now;
              EmitTaskUpdate(it->second);
            }
            last_emit_ms = now;
            last_emit_bytes = current_bytes;
          }
        }
        ofs.close();

        if (!stop_flag->load() && io_ok) {
          success = true;
        }
      } else {
        err_code = "http_error";
        err_msg = "HTTP status " + std::to_string(status_code);
      }
    }
  }

  if (hRequest) WinHttpCloseHandle(hRequest);
  if (hConnect) WinHttpCloseHandle(hConnect);
  if (hSession) WinHttpCloseHandle(hSession);

  if (stop_flag->load() || shutting_down_.load()) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    active_stop_flags_.erase(task_id);
    ScheduleQueueLocked();
    return;
  }

  if (success) {
    std::string computed_hash;
    if (!snapshot.expected_checksum.empty()) {
      computed_hash =
          ComputeFileChecksum(part_path, snapshot.checksum_algorithm);
      std::string exp_lower = snapshot.expected_checksum;
      std::transform(exp_lower.begin(), exp_lower.end(), exp_lower.begin(),
                         [](unsigned char ch) {
                           return static_cast<char>(std::tolower(ch));
                         });
      if (computed_hash != exp_lower) {
        fs::remove(part_path, ec);
        std::lock_guard<std::mutex> lock(state_mutex_);
        auto it = tasks_.find(task_id);
        if (it != tasks_.end() && it->second.status == "running") {
          it->second.status = "failed";
          it->second.computed_checksum = computed_hash;
          it->second.error = ErrorRecord{
              true, "checksum_mismatch",
              "Checksum mismatch: got " + computed_hash, 0, false, false};
          it->second.updated_at_ms = NowMs();
          PersistTasksLocked();
          EmitTaskUpdate(it->second);
          ShowSystemNotification(it->second);
        }
        active_stop_flags_.erase(task_id);
        ScheduleQueueLocked();
        return;
      }
    }

    fs::remove(dest_path, ec);
    fs::rename(part_path, dest_path, ec);
    int64_t final_size =
        fs::exists(dest_path, ec)
            ? static_cast<int64_t>(fs::file_size(dest_path, ec))
            : 0;

    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = tasks_.find(task_id);
    if (it != tasks_.end() && it->second.status == "running") {
      it->second.downloaded_bytes = final_size;
      if (it->second.total_bytes <= 0) it->second.total_bytes = final_size;
      it->second.progress = 1.0;
      it->second.bytes_per_second = 0.0;
      it->second.estimated_remaining_ms = 0;
      it->second.computed_checksum = computed_hash;
      it->second.status = "completed";
      it->second.error = ErrorRecord{};
      it->second.updated_at_ms = NowMs();
      it->second.completed_at_ms = it->second.updated_at_ms;
      PersistTasksLocked();
      EmitTaskUpdate(it->second);
      ShowSystemNotification(it->second);
    }
  } else {
    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = tasks_.find(task_id);
    if (it != tasks_.end() && it->second.status == "running") {
      it->second.status = "failed";
      it->second.bytes_per_second = 0.0;
      it->second.estimated_remaining_ms = -1;
      it->second.error =
          ErrorRecord{true, err_code, err_msg, status_code, status_code > 0,
                      true};
      it->second.updated_at_ms = NowMs();
      PersistTasksLocked();
      EmitTaskUpdate(it->second);
      ShowSystemNotification(it->second);
    }
  }

  std::lock_guard<std::mutex> lock(state_mutex_);
  active_stop_flags_.erase(task_id);
  ScheduleQueueLocked();
}

void XueHuaNaviteBackgroundDownloaderPlugin::StartEventDispatcher() {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc =
      &XueHuaNaviteBackgroundDownloaderPlugin::EventDispatcherWndProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kEventWindowClassName;
  ::RegisterClassW(&window_class);

  HWND hwnd = ::CreateWindowExW(
      0, kEventWindowClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
      window_class.hInstance, this);
  if (hwnd == nullptr) {
    ::OutputDebugStringW(
        L"XueHua downloader: event dispatcher window was not created\n");
    return;
  }
  ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  std::lock_guard<std::mutex> lock(event_queue_mutex_);
  event_hwnd_ = hwnd;
  dispatcher_alive_ = true;
}

void XueHuaNaviteBackgroundDownloaderPlugin::StopEventDispatcher() {
  HWND hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(event_queue_mutex_);
    dispatcher_alive_ = false;
    hwnd = event_hwnd_;
    event_hwnd_ = nullptr;
    pending_events_.clear();
    event_dispatch_posted_ = false;
  }
  if (hwnd != nullptr) {
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
    MSG leftover;
    while (::PeekMessageW(&leftover, hwnd, kEventFlushMessage,
                          kEventFlushMessage, PM_REMOVE)) {
    }
    ::DestroyWindow(hwnd);
  }
}

void XueHuaNaviteBackgroundDownloaderPlugin::FlushTaskUpdates() {
  std::vector<flutter::EncodableValue> batch;
  {
    std::lock_guard<std::mutex> lock(event_queue_mutex_);
    batch.swap(pending_events_);
    event_dispatch_posted_ = false;
  }
  std::lock_guard<std::mutex> sink_lock(sink_mutex_);
  if (!event_sink_) {
    return;
  }
  for (const auto& event : batch) {
    event_sink_->Success(event);
  }
}

LRESULT CALLBACK
XueHuaNaviteBackgroundDownloaderPlugin::EventDispatcherWndProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return ::DefWindowProcW(hwnd, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<XueHuaNaviteBackgroundDownloaderPlugin*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == kEventFlushMessage && self != nullptr) {
    self->FlushTaskUpdates();
    return 0;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

void XueHuaNaviteBackgroundDownloaderPlugin::EmitTaskUpdate(
    const TaskRecord& record) {
  flutter::EncodableValue event(record.ToMap());
  HWND target = nullptr;
  bool schedule = false;
  bool flush_now = false;
  bool queued = false;
  {
    std::lock_guard<std::mutex> lock(event_queue_mutex_);
    if (dispatcher_alive_ && event_hwnd_ != nullptr) {
      const bool on_platform_thread =
          ::GetWindowThreadProcessId(event_hwnd_, nullptr) ==
          ::GetCurrentThreadId();
      pending_events_.push_back(std::move(event));
      queued = true;
      if (on_platform_thread) {
        flush_now = true;
      } else if (!event_dispatch_posted_) {
        event_dispatch_posted_ = true;
        schedule = true;
        target = event_hwnd_;
      }
    }
  }

  if (!queued) {
    if (shutting_down_.load()) {
      return;
    }
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (event_sink_) {
      event_sink_->Success(std::move(event));
    }
    return;
  }
  if (flush_now) {
    FlushTaskUpdates();
    return;
  }
  if (schedule && target != nullptr &&
      !::PostMessageW(target, kEventFlushMessage, 0, 0)) {
    std::lock_guard<std::mutex> lock(event_queue_mutex_);
    event_dispatch_posted_ = false;
  }
}

void XueHuaNaviteBackgroundDownloaderPlugin::ShowSystemNotification(
    const TaskRecord& record) {
  if (!enable_notifications_ || !record.notification_config.enabled) return;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.uID = 98401;
  nid.uFlags = NIF_INFO | NIF_ICON | NIF_TIP;
  nid.hIcon = LoadIcon(nullptr, IDI_INFORMATION);
  nid.dwInfoFlags =
      (record.status == "failed") ? NIIF_ERROR : NIIF_INFO;
  std::wstring title = Utf8ToWide(
      record.notification_config.title.empty() ? record.file_name
                                               : record.notification_config.title);
  std::wstring body = Utf8ToWide(
      record.status == "completed"
          ? ("Download complete: " + record.file_name)
          : ("Download failed: " + record.file_name));
  wcsncpy_s(nid.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(nid.szInfo, body.c_str(), _TRUNCATE);
  wcsncpy_s(nid.szTip, L"XueHua Background Downloader", _TRUNCATE);
  Shell_NotifyIconW(NIM_ADD, &nid);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
  Shell_NotifyIconW(NIM_DELETE, &nid);
}

void XueHuaNaviteBackgroundDownloaderPlugin::PersistTasksLocked() {
  std::string path = GetPersistenceFilePath();
  std::ofstream ofs(fs::u8path(path), std::ios::trunc);
  if (!ofs.is_open()) return;
  for (const auto& kv : tasks_) {
    const TaskRecord& r = kv.second;
    ofs << r.task_id << "\t" << r.url << "\t" << r.save_directory << "\t"
        << r.file_name << "\t" << r.save_path << "\t" << r.status << "\t"
        << r.group << "\t" << r.priority << "\t" << r.downloaded_bytes << "\t"
        << r.total_bytes << "\t" << r.created_at_ms << "\t" << r.updated_at_ms
        << "\n";
  }
}

void XueHuaNaviteBackgroundDownloaderPlugin::LoadPersistedTasksLocked() {
  std::string path = GetPersistenceFilePath();
  std::ifstream ifs(fs::u8path(path));
  if (!ifs.is_open()) return;
  std::string line;
  while (std::getline(ifs, line)) {
    if (line.empty()) continue;
    std::stringstream ss(line);
    std::vector<std::string> cols;
    std::string col;
    while (std::getline(ss, col, '\t')) {
      cols.push_back(col);
    }
    if (cols.size() < 12) continue;
    TaskRecord r;
    r.task_id = cols[0];
    r.url = cols[1];
    r.save_directory = cols[2];
    r.file_name = cols[3];
    r.save_path = cols[4];
    r.status = cols[5];
    if (r.status == "running" || r.status == "queued") {
      r.status = auto_resume_on_startup_ ? "queued" : "paused";
    }
    r.group = cols[6];
    r.priority = cols[7];
    r.downloaded_bytes = std::stoll(cols[8]);
    r.total_bytes = std::stoll(cols[9]);
    r.progress = (r.total_bytes > 0)
                     ? std::clamp(static_cast<double>(r.downloaded_bytes) /
                                      static_cast<double>(r.total_bytes),
                                  0.0, 1.0)
                     : 0.0;
    r.created_at_ms = std::stoll(cols[10]);
    r.updated_at_ms = std::stoll(cols[11]);
    tasks_[r.task_id] = r;
  }
}

std::string XueHuaNaviteBackgroundDownloaderPlugin::GetPersistenceFilePath()
    const {
  fs::path dir = fs::u8path(GetDefaultDownloadDirectory());
  return (dir / "xue_hua_downloader_tasks.tsv").u8string();
}

std::string
XueHuaNaviteBackgroundDownloaderPlugin::GetDefaultDownloadDirectory() const {
  PWSTR raw_path = nullptr;
  std::string result;
  if (SUCCEEDED(
          SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &raw_path)) &&
      raw_path) {
    result = WideToUtf8(raw_path);
    CoTaskMemFree(raw_path);
  } else {
    result = fs::temp_directory_path().u8string();
  }
  fs::path dir = fs::u8path(result) / "XueHuaDownloads";
  std::error_code ec;
  fs::create_directories(dir, ec);
  return dir.u8string();
}

}  // namespace xue_hua_navite_background_downloader
