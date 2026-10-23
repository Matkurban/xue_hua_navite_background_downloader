#include "include/xue_hua_navite_background_downloader/xue_hua_navite_background_downloader_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <glib.h>
#include <gtk/gtk.h>

#if defined(HAVE_LIBCURL)
#include <curl/curl.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "xue_hua_navite_background_downloader_plugin_private.h"

namespace fs = std::filesystem;

namespace {

int64_t NowMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
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
  fs::path initial = dir / file_name;
  if (conflict_resolution != "uniqueName" || !fs::exists(initial)) {
    return initial;
  }
  fs::path stem = initial.stem();
  fs::path ext = initial.extension();
  int counter = 1;
  while (true) {
    std::string candidate_name =
        stem.string() + " (" + std::to_string(counter) + ")" + ext.string();
    fs::path candidate = dir / candidate_name;
    fs::path part = fs::path(candidate.string() + ".part");
    if (!fs::exists(candidate) && !fs::exists(part)) {
      return candidate;
    }
    counter++;
  }
}

std::string ComputeFileChecksumGlib(const fs::path& path,
                                    const std::string& algorithm) {
  GChecksumType type = (algorithm == "md5" || algorithm == "MD5")
                           ? G_CHECKSUM_MD5
                           : G_CHECKSUM_SHA256;
  GChecksum* checksum = g_checksum_new(type);
  if (!checksum) return "";

  std::ifstream ifs(path, std::ios::binary);
  if (!ifs.is_open()) {
    g_checksum_free(checksum);
    return "";
  }
  std::vector<char> buf(32 * 1024);
  while (ifs.good()) {
    ifs.read(buf.data(), static_cast<std::streamsize>(buf.size()));
    std::streamsize n = ifs.gcount();
    if (n > 0) {
      g_checksum_update(checksum,
                        reinterpret_cast<const guchar*>(buf.data()), n);
    }
  }
  std::string result(g_checksum_get_string(checksum));
  g_checksum_free(checksum);
  return result;
}

std::string DefaultDownloadDir() {
  const char* dl = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
  fs::path base = dl ? fs::path(dl) : fs::temp_directory_path();
  fs::path dir = base / "XueHuaDownloads";
  std::error_code ec;
  fs::create_directories(dir, ec);
  return dir.string();
}

std::string GetFlString(FlValue* map, const char* key,
                        const std::string& fallback = "") {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(v);
  }
  return fallback;
}

bool GetFlBool(FlValue* map, const char* key, bool fallback = false) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) {
    return fl_value_get_bool(v);
  }
  return fallback;
}

int64_t GetFlInt(FlValue* map, const char* key, int64_t fallback = 0) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return fl_value_get_int(v);
  }
  return fallback;
}

struct LinuxTaskRecord {
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
  std::string error_code;
  std::string error_message;
  int http_status_code = 0;
  int64_t created_at_ms = 0;
  int64_t updated_at_ms = 0;
  int64_t completed_at_ms = 0;
  std::map<std::string, std::string> headers;
  std::map<std::string, std::string> metadata;
  bool notify_enabled = true;
  std::string notify_title;

  FlValue* ToFlValue() const {
    FlValue* m = fl_value_new_map();
    fl_value_set_string_take(m, "taskId", fl_value_new_string(task_id.c_str()));
    fl_value_set_string_take(m, "url", fl_value_new_string(url.c_str()));
    fl_value_set_string_take(m, "saveDirectory",
                             fl_value_new_string(save_directory.c_str()));
    fl_value_set_string_take(m, "fileName",
                             fl_value_new_string(file_name.c_str()));
    fl_value_set_string_take(m, "savePath",
                             fl_value_new_string(save_path.c_str()));
    fl_value_set_string_take(m, "status", fl_value_new_string(status.c_str()));
    fl_value_set_string_take(m, "group", fl_value_new_string(group.c_str()));
    fl_value_set_string_take(m, "priority",
                             fl_value_new_string(priority.c_str()));
    fl_value_set_string_take(m, "conflictResolution",
                             fl_value_new_string(conflict_resolution.c_str()));
    fl_value_set_string_take(m, "downloadedBytes",
                             fl_value_new_int(downloaded_bytes));
    fl_value_set_string_take(m, "totalBytes", fl_value_new_int(total_bytes));
    fl_value_set_string_take(m, "progress", fl_value_new_float(progress));
    fl_value_set_string_take(m, "bytesPerSecond",
                             fl_value_new_float(bytes_per_second));
    fl_value_set_string_take(m, "estimatedRemainingMs",
                             fl_value_new_int(estimated_remaining_ms));
    fl_value_set_string_take(m, "retryCount", fl_value_new_int(retry_count));
    fl_value_set_string_take(m, "maxRetries", fl_value_new_int(max_retries));
    fl_value_set_string_take(m, "supportsResume",
                             fl_value_new_bool(supports_resume));
    fl_value_set_string_take(m, "requiresUnmeteredNetwork",
                             fl_value_new_bool(requires_unmetered_network));
    fl_value_set_string_take(
        m, "expectedChecksum",
        expected_checksum.empty()
            ? fl_value_new_null()
            : fl_value_new_string(expected_checksum.c_str()));
    fl_value_set_string_take(m, "checksumAlgorithm",
                             fl_value_new_string(checksum_algorithm.c_str()));
    fl_value_set_string_take(
        m, "computedChecksum",
        computed_checksum.empty()
            ? fl_value_new_null()
            : fl_value_new_string(computed_checksum.c_str()));

    if (!error_code.empty()) {
      FlValue* err = fl_value_new_map();
      fl_value_set_string_take(err, "code",
                               fl_value_new_string(error_code.c_str()));
      fl_value_set_string_take(err, "message",
                               fl_value_new_string(error_message.c_str()));
      if (http_status_code > 0) {
        fl_value_set_string_take(err, "httpStatusCode",
                                 fl_value_new_int(http_status_code));
      } else {
        fl_value_set_string_take(err, "httpStatusCode", fl_value_new_null());
      }
      fl_value_set_string_take(err, "isRecoverable", fl_value_new_bool(true));
      fl_value_set_string_take(m, "error", err);
    } else {
      fl_value_set_string_take(m, "error", fl_value_new_null());
    }

    fl_value_set_string_take(m, "createdAtMs",
                             fl_value_new_int(created_at_ms));
    fl_value_set_string_take(m, "updatedAtMs",
                             fl_value_new_int(updated_at_ms));
    fl_value_set_string_take(
        m, "completedAtMs",
        completed_at_ms > 0 ? fl_value_new_int(completed_at_ms)
                            : fl_value_new_null());

    FlValue* h_map = fl_value_new_map();
    for (const auto& kv : headers) {
      fl_value_set_string_take(h_map, kv.first.c_str(),
                               fl_value_new_string(kv.second.c_str()));
    }
    fl_value_set_string_take(m, "headers", h_map);

    FlValue* meta_map = fl_value_new_map();
    for (const auto& kv : metadata) {
      fl_value_set_string_take(meta_map, kv.first.c_str(),
                               fl_value_new_string(kv.second.c_str()));
    }
    fl_value_set_string_take(m, "metadata", meta_map);

    FlValue* n_map = fl_value_new_map();
    fl_value_set_string_take(n_map, "enabled",
                             fl_value_new_bool(notify_enabled));
    fl_value_set_string_take(
        n_map, "title",
        notify_title.empty() ? fl_value_new_null()
                             : fl_value_new_string(notify_title.c_str()));
    fl_value_set_string_take(n_map, "showProgress", fl_value_new_bool(true));
    fl_value_set_string_take(m, "notificationConfig", n_map);
    return m;
  }
};

}  // namespace

#define XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST(                           \
      (obj), xue_hua_navite_background_downloader_plugin_get_type(), \
      XueHuaNaviteBackgroundDownloaderPlugin))

struct _XueHuaNaviteBackgroundDownloaderPlugin {
  GObject parent_instance;
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  bool event_listening;
};

G_DEFINE_TYPE(XueHuaNaviteBackgroundDownloaderPlugin,
              xue_hua_navite_background_downloader_plugin,
              g_object_get_type())

namespace {

class LinuxDownloaderEngine {
 public:
  static LinuxDownloaderEngine& Instance() {
    static LinuxDownloaderEngine inst;
    return inst;
  }

  void AttachPlugin(XueHuaNaviteBackgroundDownloaderPlugin* plugin) {
    std::lock_guard<std::mutex> lock(mu_);
    plugin_ = plugin;
    if (!loaded_) {
      loaded_ = true;
      LoadPersistedLocked();
    }
  }

  void DetachPlugin(XueHuaNaviteBackgroundDownloaderPlugin* plugin) {
    std::lock_guard<std::mutex> lock(mu_);
    if (plugin_ == plugin) {
      plugin_ = nullptr;
    }
  }

  FlMethodResponse* HandleCall(const char* method, FlValue* args) {
    std::lock_guard<std::mutex> lock(mu_);
    if (strcmp(method, "configure") == 0) {
      if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
        max_concurrent_tasks_ = std::clamp<int>(
            static_cast<int>(GetFlInt(args, "maxConcurrentTasks", 3)), 1, 16);
        connect_timeout_ms_ = std::max<int>(
            1000, static_cast<int>(GetFlInt(args, "connectTimeoutMs", 15000)));
        read_timeout_ms_ = std::max<int>(
            1000, static_cast<int>(GetFlInt(args, "readTimeoutMs", 30000)));
        progress_interval_ms_ = std::max<int64_t>(
            50, GetFlInt(args, "progressUpdateIntervalMs", 250));
        enable_notifications_ = GetFlBool(args, "enableNotifications", true);
        user_agent_ = GetFlString(args, "userAgent",
                                  "XueHuaNativeBackgroundDownloader/1.0.0");
        auto_resume_ = GetFlBool(args, "autoResumeOnStartup", false);
      }
      ScheduleQueueLocked();
      g_autoptr(FlValue) null_val = fl_value_new_null();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    }

    if (strcmp(method, "getCapabilities") == 0) {
      return get_capabilities_response();
    }

    if (strcmp(method, "requestNotificationPermission") == 0) {
      g_autoptr(FlValue) res = fl_value_new_bool(TRUE);
      return FL_METHOD_RESPONSE(fl_method_success_response_new(res));
    }

    if (strcmp(method, "enqueue") == 0) {
      LinuxTaskRecord rec = CreateTaskLocked(args);
      ScheduleQueueLocked();
      g_autoptr(FlValue) val = rec.ToFlValue();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "enqueueAll") == 0) {
      g_autoptr(FlValue) list = fl_value_new_list();
      FlValue* reqs =
          args ? fl_value_lookup_string(args, "requests") : nullptr;
      if (reqs && fl_value_get_type(reqs) == FL_VALUE_TYPE_LIST) {
        size_t len = fl_value_get_length(reqs);
        for (size_t i = 0; i < len; ++i) {
          LinuxTaskRecord rec =
              CreateTaskLocked(fl_value_get_list_value(reqs, i));
          fl_value_append_take(list, rec.ToFlValue());
        }
        ScheduleQueueLocked();
      }
      return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }

    if (strcmp(method, "pause") == 0) {
      std::string id = GetFlString(args, "taskId");
      LinuxTaskRecord* rec = PauseLocked(id);
      ScheduleQueueLocked();
      g_autoptr(FlValue) val = rec ? rec->ToFlValue() : fl_value_new_null();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "resume") == 0) {
      std::string id = GetFlString(args, "taskId");
      LinuxTaskRecord* rec = ResumeLocked(id);
      ScheduleQueueLocked();
      g_autoptr(FlValue) val = rec ? rec->ToFlValue() : fl_value_new_null();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "cancel") == 0) {
      std::string id = GetFlString(args, "taskId");
      bool del = GetFlBool(args, "deletePartialFile", true);
      LinuxTaskRecord* rec = CancelLocked(id, del);
      ScheduleQueueLocked();
      g_autoptr(FlValue) val = rec ? rec->ToFlValue() : fl_value_new_null();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "retry") == 0) {
      std::string id = GetFlString(args, "taskId");
      LinuxTaskRecord* rec = RetryLocked(id);
      ScheduleQueueLocked();
      g_autoptr(FlValue) val = rec ? rec->ToFlValue() : fl_value_new_null();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "removeTask") == 0) {
      std::string id = GetFlString(args, "taskId");
      bool del = GetFlBool(args, "deleteFile", false);
      bool ok = RemoveLocked(id, del);
      ScheduleQueueLocked();
      g_autoptr(FlValue) val = fl_value_new_bool(ok);
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "pauseAll") == 0) {
      std::string group = GetFlString(args, "group");
      g_autoptr(FlValue) list = fl_value_new_list();
      for (auto& kv : tasks_) {
        if (!group.empty() && kv.second.group != group) continue;
        if (kv.second.status == "queued" || kv.second.status == "running") {
          if (LinuxTaskRecord* r = PauseLocked(kv.first)) {
            fl_value_append_take(list, r->ToFlValue());
          }
        }
      }
      ScheduleQueueLocked();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }

    if (strcmp(method, "resumeAll") == 0) {
      std::string group = GetFlString(args, "group");
      g_autoptr(FlValue) list = fl_value_new_list();
      for (auto& kv : tasks_) {
        if (!group.empty() && kv.second.group != group) continue;
        if (kv.second.status == "paused") {
          if (LinuxTaskRecord* r = ResumeLocked(kv.first)) {
            fl_value_append_take(list, r->ToFlValue());
          }
        }
      }
      ScheduleQueueLocked();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }

    if (strcmp(method, "cancelAll") == 0) {
      std::string group = GetFlString(args, "group");
      bool del = GetFlBool(args, "deletePartialFiles", true);
      g_autoptr(FlValue) list = fl_value_new_list();
      for (auto& kv : tasks_) {
        if (!group.empty() && kv.second.group != group) continue;
        if (kv.second.status == "queued" || kv.second.status == "running" ||
            kv.second.status == "paused") {
          if (LinuxTaskRecord* r = CancelLocked(kv.first, del)) {
            fl_value_append_take(list, r->ToFlValue());
          }
        }
      }
      ScheduleQueueLocked();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }

    if (strcmp(method, "clearCompleted") == 0) {
      std::string group = GetFlString(args, "group");
      bool del = GetFlBool(args, "deleteFiles", false);
      int count = 0;
      for (auto it = tasks_.begin(); it != tasks_.end();) {
        if ((group.empty() || it->second.group == group) &&
            it->second.status == "completed") {
          if (del) {
            std::error_code ec;
            fs::remove(it->second.save_path, ec);
          }
          it = tasks_.erase(it);
          count++;
        } else {
          ++it;
        }
      }
      if (count > 0) PersistLocked();
      g_autoptr(FlValue) val = fl_value_new_int(count);
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "getTask") == 0) {
      std::string id = GetFlString(args, "taskId");
      auto it = tasks_.find(id);
      g_autoptr(FlValue) val =
          (it != tasks_.end()) ? it->second.ToFlValue() : fl_value_new_null();
      return FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    }

    if (strcmp(method, "getAllTasks") == 0) {
      std::string group = GetFlString(args, "group");
      g_autoptr(FlValue) list = fl_value_new_list();
      for (const auto& kv : tasks_) {
        if (!group.empty() && kv.second.group != group) continue;
        fl_value_append_take(list, kv.second.ToFlValue());
      }
      return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }

    return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  void UpdateProgressFromWorker(const std::string& task_id,
                                int64_t current_bytes,
                                int64_t total_bytes,
                                double speed_bps,
                                int64_t remaining_ms) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = tasks_.find(task_id);
    if (it == tasks_.end() || it->second.status != "running") return;
    it->second.downloaded_bytes = current_bytes;
    it->second.total_bytes = total_bytes;
    it->second.progress =
        total_bytes > 0
            ? std::clamp(static_cast<double>(current_bytes) /
                             static_cast<double>(total_bytes),
                         0.0, 1.0)
            : -1.0;
    it->second.bytes_per_second = speed_bps;
    it->second.estimated_remaining_ms = remaining_ms;
    it->second.updated_at_ms = NowMs();
    EmitEventOnMain(it->second);
  }

 private:
  LinuxTaskRecord CreateTaskLocked(FlValue* args) {
    static std::atomic<uint64_t> seq{1};
    std::string url = GetFlString(args, "url");
    std::string task_id = GetFlString(args, "taskId");
    if (task_id.empty()) {
      task_id =
          "linux_dl_" + std::to_string(NowMs()) + "_" + std::to_string(seq++);
    }

    auto stop_it = active_stops_.find(task_id);
    if (stop_it != active_stops_.end()) {
      stop_it->second->store(true);
      active_stops_.erase(stop_it);
    }

    std::string dir_str = GetFlString(args, "saveDirectory");
    if (dir_str.empty()) dir_str = DefaultDownloadDir();
    fs::path dir_path(dir_str);
    std::error_code ec;
    fs::create_directories(dir_path, ec);

    std::string file_name = GetFlString(args, "fileName");
    file_name = file_name.empty() ? InferFileNameFromUrl(url)
                                  : SanitizeFileName(file_name);
    std::string conflict =
        GetFlString(args, "conflictResolution", "overwrite");
    fs::path final_path = ResolveDestinationPath(dir_path, file_name, conflict);

    LinuxTaskRecord rec;
    rec.task_id = task_id;
    rec.url = url;
    rec.save_directory = dir_path.string();
    rec.file_name = final_path.filename().string();
    rec.save_path = final_path.string();
    rec.status = "queued";
    rec.group = GetFlString(args, "group", "default");
    rec.priority = GetFlString(args, "priority", "normal");
    rec.conflict_resolution = conflict;
    rec.method = GetFlString(args, "method", "GET");
    rec.post_body = GetFlString(args, "postBody", "");
    rec.max_retries = static_cast<int>(GetFlInt(args, "maxRetries", 2));
    rec.allow_pause = GetFlBool(args, "allowPause", true);
    rec.supports_resume = rec.allow_pause;
    rec.requires_unmetered_network =
        GetFlBool(args, "requiresUnmeteredNetwork", false);
    rec.expected_checksum = GetFlString(args, "expectedChecksum", "");
    rec.checksum_algorithm =
        GetFlString(args, "checksumAlgorithm", "sha256");
    rec.created_at_ms = NowMs();
    rec.updated_at_ms = rec.created_at_ms;

    tasks_[task_id] = rec;
    PersistLocked();
    EmitEventOnMain(rec);
    return rec;
  }

  LinuxTaskRecord* PauseLocked(const std::string& id) {
    auto it = tasks_.find(id);
    if (it == tasks_.end()) return nullptr;
    auto& r = it->second;
    if (r.status != "running" && r.status != "queued") return &r;
    auto st = active_stops_.find(id);
    if (st != active_stops_.end()) {
      st->second->store(true);
      active_stops_.erase(st);
    }
    r.status = "paused";
    r.bytes_per_second = 0.0;
    r.estimated_remaining_ms = -1;
    r.updated_at_ms = NowMs();
    PersistLocked();
    EmitEventOnMain(r);
    return &r;
  }

  LinuxTaskRecord* ResumeLocked(const std::string& id) {
    auto it = tasks_.find(id);
    if (it == tasks_.end()) return nullptr;
    auto& r = it->second;
    if (r.status != "paused" && r.status != "failed") return &r;
    fs::path part(r.save_path + ".part");
    std::error_code ec;
    r.downloaded_bytes =
        fs::exists(part, ec) ? static_cast<int64_t>(fs::file_size(part, ec)) : 0;
    r.status = "queued";
    r.error_code.clear();
    r.error_message.clear();
    r.updated_at_ms = NowMs();
    PersistLocked();
    EmitEventOnMain(r);
    return &r;
  }

  LinuxTaskRecord* CancelLocked(const std::string& id, bool del_partial) {
    auto it = tasks_.find(id);
    if (it == tasks_.end()) return nullptr;
    auto& r = it->second;
    auto st = active_stops_.find(id);
    if (st != active_stops_.end()) {
      st->second->store(true);
      active_stops_.erase(st);
    }
    if (del_partial) {
      std::error_code ec;
      fs::remove(r.save_path + ".part", ec);
      r.downloaded_bytes = 0;
      r.progress = 0.0;
    }
    r.status = "canceled";
    r.bytes_per_second = 0.0;
    r.estimated_remaining_ms = -1;
    r.updated_at_ms = NowMs();
    PersistLocked();
    EmitEventOnMain(r);
    return &r;
  }

  LinuxTaskRecord* RetryLocked(const std::string& id) {
    auto it = tasks_.find(id);
    if (it == tasks_.end()) return nullptr;
    auto& r = it->second;
    r.status = "queued";
    r.retry_count = 0;
    r.error_code.clear();
    r.error_message.clear();
    r.updated_at_ms = NowMs();
    PersistLocked();
    EmitEventOnMain(r);
    return &r;
  }

  bool RemoveLocked(const std::string& id, bool del_file) {
    auto st = active_stops_.find(id);
    if (st != active_stops_.end()) {
      st->second->store(true);
      active_stops_.erase(st);
    }
    auto it = tasks_.find(id);
    if (it == tasks_.end()) return false;
    std::error_code ec;
    fs::remove(it->second.save_path + ".part", ec);
    if (del_file) fs::remove(it->second.save_path, ec);
    tasks_.erase(it);
    PersistLocked();
    return true;
  }

  void ScheduleQueueLocked() {
    int avail = max_concurrent_tasks_ - static_cast<int>(active_stops_.size());
    if (avail <= 0) return;
    std::vector<LinuxTaskRecord*> candidates;
    for (auto& kv : tasks_) {
      if (kv.second.status == "queued" &&
          active_stops_.find(kv.first) == active_stops_.end()) {
        candidates.push_back(&kv.second);
      }
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const LinuxTaskRecord* a, const LinuxTaskRecord* b) {
                int pa = PriorityLevel(a->priority);
                int pb = PriorityLevel(b->priority);
                if (pa != pb) return pa > pb;
                return a->created_at_ms < b->created_at_ms;
              });
    int count = std::min<int>(avail, static_cast<int>(candidates.size()));
    for (int i = 0; i < count; ++i) {
      LinuxTaskRecord* r = candidates[i];
      r->status = "running";
      r->updated_at_ms = NowMs();
      EmitEventOnMain(*r);
      auto stop_flag = std::make_shared<std::atomic<bool>>(false);
      active_stops_[r->task_id] = stop_flag;
      std::string tid = r->task_id;
      std::thread([this, tid, stop_flag]() {
        RunWorker(tid, stop_flag);
      }).detach();
    }
  }

  void RunWorker(std::string task_id,
                 std::shared_ptr<std::atomic<bool>> stop_flag) {
    LinuxTaskRecord snap;
    int64_t interval_ms = 250;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = tasks_.find(task_id);
      if (it == tasks_.end()) return;
      snap = it->second;
      interval_ms = progress_interval_ms_;
    }

    fs::path dest_path(snap.save_path);
    fs::path part_path(snap.save_path + ".part");
    std::error_code ec;
    fs::create_directories(dest_path.parent_path(), ec);

    int64_t offset =
        (snap.allow_pause && fs::exists(part_path, ec))
            ? static_cast<int64_t>(fs::file_size(part_path, ec))
            : 0;

    bool ok = false;
    int http_code = 200;
    std::string err_msg;

#if defined(HAVE_LIBCURL)
    struct ProgressCtx {
      std::string task_id;
      int64_t offset;
      int64_t interval_ms;
      int64_t last_emit_ms;
      int64_t last_bytes;
      double smoothed_speed;
      std::shared_ptr<std::atomic<bool>> stop_flag;
    };

    CURL* curl = curl_easy_init();
    if (curl) {
      std::ofstream ofs(part_path, std::ios::binary |
                                       (offset > 0 ? std::ios::app
                                                   : std::ios::trunc));
      ProgressCtx pctx{task_id, offset, interval_ms, NowMs(),
                       offset,  0.0,    stop_flag};

      curl_easy_setopt(curl, CURLOPT_URL, snap.url.c_str());
      curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
      curl_easy_setopt(curl, CURLOPT_USERAGENT, user_agent_.c_str());
      curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS,
                       static_cast<long>(connect_timeout_ms_));
      if (offset > 0) {
        curl_easy_setopt(curl, CURLOPT_RESUME_FROM_LARGE,
                         static_cast<curl_off_t>(offset));
      }
      auto write_cb = +[](char* ptr, size_t size, size_t nmemb,
                          void* userdata) -> size_t {
        auto* stream = static_cast<std::ofstream*>(userdata);
        size_t total = size * nmemb;
        stream->write(ptr, static_cast<std::streamsize>(total));
        return total;
      };
      auto xfer_cb = +[](void* clientp, curl_off_t dltotal, curl_off_t dlnow,
                         curl_off_t /*ultotal*/,
                         curl_off_t /*ulnow*/) -> int {
        auto* ctx = static_cast<ProgressCtx*>(clientp);
        if (ctx->stop_flag->load()) return 1;
        int64_t now = NowMs();
        int64_t elapsed = now - ctx->last_emit_ms;
        if (elapsed >= ctx->interval_ms) {
          int64_t cur = ctx->offset + static_cast<int64_t>(dlnow);
          int64_t tot =
              dltotal > 0 ? (ctx->offset + static_cast<int64_t>(dltotal)) : -1;
          int64_t delta = cur - ctx->last_bytes;
          double inst =
              elapsed > 0 ? (static_cast<double>(delta) * 1000.0 / elapsed)
                          : 0.0;
          ctx->smoothed_speed =
              ctx->smoothed_speed <= 0.0
                  ? inst
                  : (ctx->smoothed_speed * 0.65 + inst * 0.35);
          int64_t rem =
              (tot > cur && ctx->smoothed_speed > 1.0)
                  ? static_cast<int64_t>((tot - cur) * 1000.0 /
                                         ctx->smoothed_speed)
                  : -1;
          LinuxDownloaderEngine::Instance().UpdateProgressFromWorker(
              ctx->task_id, cur, tot, ctx->smoothed_speed, rem);
          ctx->last_emit_ms = now;
          ctx->last_bytes = cur;
        }
        return 0;
      };
      curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
      curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ofs);
      curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
      curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, xfer_cb);
      curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &pctx);

      CURLcode res = curl_easy_perform(curl);
      long code = 0;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
      http_code = static_cast<int>(code);
      ok = (res == CURLE_OK && http_code >= 200 && http_code < 300);
      if (!ok) err_msg = curl_easy_strerror(res);
      curl_easy_cleanup(curl);
      ofs.close();
    }
#else
    std::ostringstream cmd;
    cmd << "curl -sS -L --connect-timeout " << (connect_timeout_ms_ / 1000);
    if (offset > 0) cmd << " -C " << offset;
    cmd << " -o \"" << part_path.string() << "\" \"" << snap.url << "\"";
    int rc = std::system(cmd.str().c_str());
    ok = (rc == 0);
    if (!ok) err_msg = "curl transfer failed";
#endif

    if (stop_flag->load()) {
      std::lock_guard<std::mutex> lock(mu_);
      active_stops_.erase(task_id);
      ScheduleQueueLocked();
      return;
    }

    std::lock_guard<std::mutex> lock(mu_);
    auto it = tasks_.find(task_id);
    if (it != tasks_.end()) {
      if (ok) {
        if (!snap.expected_checksum.empty()) {
          std::string computed =
              ComputeFileChecksumGlib(part_path, snap.checksum_algorithm);
          it->second.computed_checksum = computed;
          if (computed != snap.expected_checksum) {
            fs::remove(part_path, ec);
            it->second.status = "failed";
            it->second.error_code = "checksum_mismatch";
            it->second.error_message = "Checksum mismatch";
            it->second.updated_at_ms = NowMs();
            PersistLocked();
            EmitEventOnMain(it->second);
            SendDesktopNotificationLocked(it->second);
            active_stops_.erase(task_id);
            ScheduleQueueLocked();
            return;
          }
        }
        fs::remove(dest_path, ec);
        fs::rename(part_path, dest_path, ec);
        int64_t final_sz =
            fs::exists(dest_path, ec)
                ? static_cast<int64_t>(fs::file_size(dest_path, ec))
                : 0;
        it->second.downloaded_bytes = final_sz;
        it->second.total_bytes = final_sz;
        it->second.progress = 1.0;
        it->second.bytes_per_second = 0.0;
        it->second.estimated_remaining_ms = 0;
        it->second.status = "completed";
        it->second.updated_at_ms = NowMs();
        it->second.completed_at_ms = it->second.updated_at_ms;
      } else {
        it->second.status = "failed";
        it->second.error_code = "network_error";
        it->second.error_message = err_msg;
        it->second.http_status_code = http_code;
        it->second.updated_at_ms = NowMs();
      }
      PersistLocked();
      EmitEventOnMain(it->second);
      SendDesktopNotificationLocked(it->second);
    }
    active_stops_.erase(task_id);
    ScheduleQueueLocked();
  }

  void SendDesktopNotificationLocked(const LinuxTaskRecord& rec) {
    if (!enable_notifications_ || !rec.notify_enabled) return;
    std::string title =
        rec.notify_title.empty() ? rec.file_name : rec.notify_title;
    std::string body = (rec.status == "completed")
                           ? ("Download complete: " + rec.file_name)
                           : ("Download failed: " + rec.file_name);
    gchar* notify_bin = g_find_program_in_path("notify-send");
    if (notify_bin) {
      gchar* argv[] = {notify_bin, const_cast<char*>(title.c_str()),
                       const_cast<char*>(body.c_str()), nullptr};
      g_spawn_async(nullptr, argv, nullptr, G_SPAWN_SEARCH_PATH, nullptr,
                    nullptr, nullptr, nullptr);
      g_free(notify_bin);
    }
  }

  void EmitEventOnMain(const LinuxTaskRecord& rec) {
    FlValue* val = rec.ToFlValue();
    g_idle_add(
        +[](gpointer data) -> gboolean {
          FlValue* v = static_cast<FlValue*>(data);
          LinuxDownloaderEngine::Instance().SendEventValue(v);
          fl_value_unref(v);
          return G_SOURCE_REMOVE;
        },
        val);
  }

  void SendEventValue(FlValue* v) {
    std::lock_guard<std::mutex> lock(mu_);
    if (plugin_ && plugin_->event_channel && plugin_->event_listening) {
      fl_event_channel_send(plugin_->event_channel, v, nullptr, nullptr);
    }
  }

  void PersistLocked() {
    fs::path p = fs::path(DefaultDownloadDir()) / "xue_hua_downloader_tasks.tsv";
    std::ofstream ofs(p, std::ios::trunc);
    if (!ofs.is_open()) return;
    for (const auto& kv : tasks_) {
      const auto& r = kv.second;
      ofs << r.task_id << "\t" << r.url << "\t" << r.save_directory << "\t"
          << r.file_name << "\t" << r.save_path << "\t" << r.status << "\t"
          << r.group << "\t" << r.priority << "\t" << r.downloaded_bytes << "\t"
          << r.total_bytes << "\t" << r.created_at_ms << "\t" << r.updated_at_ms
          << "\n";
    }
  }

  void LoadPersistedLocked() {
    fs::path p = fs::path(DefaultDownloadDir()) / "xue_hua_downloader_tasks.tsv";
    std::ifstream ifs(p);
    if (!ifs.is_open()) return;
    std::string line;
    while (std::getline(ifs, line)) {
      if (line.empty()) continue;
      std::stringstream ss(line);
      std::vector<std::string> cols;
      std::string col;
      while (std::getline(ss, col, '\t')) cols.push_back(col);
      if (cols.size() < 12) continue;
      LinuxTaskRecord r;
      r.task_id = cols[0];
      r.url = cols[1];
      r.save_directory = cols[2];
      r.file_name = cols[3];
      r.save_path = cols[4];
      r.status = cols[5];
      if (r.status == "running" || r.status == "queued") {
        r.status = auto_resume_ ? "queued" : "paused";
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

  std::mutex mu_;
  XueHuaNaviteBackgroundDownloaderPlugin* plugin_ = nullptr;
  bool loaded_ = false;
  int max_concurrent_tasks_ = 3;
  int connect_timeout_ms_ = 15000;
  int read_timeout_ms_ = 30000;
  int64_t progress_interval_ms_ = 250;
  bool enable_notifications_ = true;
  std::string user_agent_ = "XueHuaNativeBackgroundDownloader/1.0.0";
  bool auto_resume_ = false;
  std::map<std::string, LinuxTaskRecord> tasks_;
  std::map<std::string, std::shared_ptr<std::atomic<bool>>> active_stops_;
};

}  // namespace

FlMethodResponse* get_capabilities_response() {
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "platform", fl_value_new_string("linux"));
  fl_value_set_string_take(map, "nativeEngine",
                           fl_value_new_string("libcurl + GLib"));
  fl_value_set_string_take(map, "supportsBackgroundExecution",
                           fl_value_new_bool(TRUE));
  fl_value_set_string_take(map, "supportsPauseResume",
                           fl_value_new_bool(TRUE));
  fl_value_set_string_take(map, "supportsSystemNotifications",
                           fl_value_new_bool(TRUE));
  fl_value_set_string_take(map, "supportsPersistence",
                           fl_value_new_bool(TRUE));
  fl_value_set_string_take(map, "supportsChecksumVerification",
                           fl_value_new_bool(TRUE));
  fl_value_set_string_take(map, "supportsNetworkConstraints",
                           fl_value_new_bool(TRUE));
  std::string def_dir = DefaultDownloadDir();
  fl_value_set_string_take(map, "defaultDownloadDirectory",
                           fl_value_new_string(def_dir.c_str()));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

static void xue_hua_navite_background_downloader_plugin_handle_method_call(
    XueHuaNaviteBackgroundDownloaderPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response =
      LinuxDownloaderEngine::Instance().HandleCall(method, args);
  fl_method_call_respond(method_call, response, nullptr);
}

static void xue_hua_navite_background_downloader_plugin_dispose(
    GObject* object) {
  XueHuaNaviteBackgroundDownloaderPlugin* self =
      XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN(object);
  LinuxDownloaderEngine::Instance().DetachPlugin(self);
  g_clear_object(&self->method_channel);
  g_clear_object(&self->event_channel);
  G_OBJECT_CLASS(xue_hua_navite_background_downloader_plugin_parent_class)
      ->dispose(object);
}

static void xue_hua_navite_background_downloader_plugin_class_init(
    XueHuaNaviteBackgroundDownloaderPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose =
      xue_hua_navite_background_downloader_plugin_dispose;
}

static void xue_hua_navite_background_downloader_plugin_init(
    XueHuaNaviteBackgroundDownloaderPlugin* self) {
  self->event_listening = false;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  XueHuaNaviteBackgroundDownloaderPlugin* plugin =
      XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN(user_data);
  xue_hua_navite_background_downloader_plugin_handle_method_call(plugin,
                                                                 method_call);
}

static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data) {
  XueHuaNaviteBackgroundDownloaderPlugin* plugin =
      XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN(user_data);
  plugin->event_listening = true;
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data) {
  XueHuaNaviteBackgroundDownloaderPlugin* plugin =
      XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN(user_data);
  plugin->event_listening = false;
  return nullptr;
}

void xue_hua_navite_background_downloader_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  XueHuaNaviteBackgroundDownloaderPlugin* plugin =
      XUE_HUA_NAVITE_BACKGROUND_DOWNLOADER_PLUGIN(g_object_new(
          xue_hua_navite_background_downloader_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->method_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.kurban.xue_hua_navite_background_downloader/methods",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->method_channel, method_call_cb, g_object_ref(plugin),
      g_object_unref);

  plugin->event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.kurban.xue_hua_navite_background_downloader/events",
      FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel, event_listen_cb,
                                       event_cancel_cb, g_object_ref(plugin),
                                       g_object_unref);

  LinuxDownloaderEngine::Instance().AttachPlugin(plugin);
  g_object_unref(plugin);
}
