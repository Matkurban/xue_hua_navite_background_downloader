## 1.0.8

- Android: harden pause/resume so the worker fully stops before pause returns and stale workers cannot block resume.
- Android/example: AGP 9.1.1.
- Tests: stabilize Android integ pause/resume (Cloudflare URLs + getTask diagnostics) and relax flutter_driver pause progress byte equality.

## 1.0.7

* `getCapabilities()` reports `taskStorePath`, the absolute path of the persisted task queue. Apple platforms use Application Support `xue_hua_background_downloader/tasks.json`. Android uses `filesDir/xue_hua_downloader_tasks.json`. Linux and Windows keep `xue_hua_downloader_tasks.tsv` in the default download directory. The field defaults to empty when an older engine omits it.
* Example: the `getAllTasks` integration check reads `taskStorePath` instead of assuming the desktop TSV layout. The checksum case hashes with `package:crypto` so it can run on iOS, where `Process` is unavailable.
* Example: phone-width layouts build the dashboard in one scroll view, and `flutter_driver` scrolls each control into view, dismisses the software keyboard, and waits longer for keys. The iOS simulator uses the same script as macOS, Windows, and Linux. Run it with `example/tool/run_ios_simulator_tests.sh`.

## 1.0.6

* Windows: deliver EventChannel task updates on the platform thread. Progress, completion, and the running transition scheduled when a worker exits were sent from the download thread, so Flutter logged `events` as a non-platform-thread channel and could drop the update. Pause, resume, cancel, and progress still emit the same payloads. Linux continues to marshal with `g_idle_add`.
* Example: `run_desktop_tests.ps1` passes `--device-id=windows` inside an argument array. PowerShell was binding `-d` to `-Debug`, so the script did not target Windows.
* Example: document a short checkout or `C:\bgdl` junction. Long `StudioProjects` paths still overflow MSBuild `.tlog` `MAX_PATH`. Windows native googletest stays `if(FALSE)`.

## 1.0.5

* Linux: apply `skip` and `fail` when the destination already exists, compare checksums without case sensitivity, send per-request headers and `defaultHeaders`, and honor `notificationConfig.enabled` plus `title`. HTTP status failures are reported as `http_error` with the status code. Connect timeout, low-speed abort, and `CURLOPT_NOSIGNAL` are set on the transfer.
* Linux and Windows: a task keeps its concurrency slot until the worker exits, so pause or resume does not start a second writer on the same partial file. A worker that finishes after the task leaves `running` does not mark it completed or failed. Windows progress events after pause are ignored.
* Example: `flutter_driver` drives configure, enqueue, group filters, the queue, pause, resume, batch, and cancel. Keys are the same on Linux and Windows. Integration coverage adds skip/fail, checksum, custom headers, HTTP 404, and `getAllTasks`. Use `example/tool/run_desktop_tests.sh` or `example/tool/run_desktop_tests.ps1`, which runs each integration file in its own process.
* Windows native googletest stays disabled with `if(FALSE)` so the MAX_PATH guard is unchanged.

## 1.0.4

* Windows: fix CMake configure error (`if(FALSE AND)` / unknown arguments) when the native googletest block stays disabled for MAX_PATH. The block remains off; re-enable with `if(${include_${PROJECT_NAME}_tests})` once paths allow.

## 1.0.3

* Shorten the pubspec `description` to 165 characters (within pub.dev's 60-180 range) so the package scores a valid `pubspec.yaml`.

## 1.0.2

* Linux: pin googletest to v1.15.2 so plugin unit-test FetchContent configures under CMake 4.x.
* Example: make download API integration verification test platform-aware (Linux libcurl + Windows WinHTTP).

## 1.0.1

* Windows: fix MSVC build under CMake 4.x / VS 2026 (NOMINMAX/std::min/std::max, 	olower C4244, googletest pin).
* Windows: avoid MAX_PATH failures from the long googletest unit-test target under deep Flutter build trees.
* Example: replace dead GitHub raw preset URL (HTTP 404) with httpbin.org/bytes/65536.
* Example: add Windows download API integration verification test.
## 1.0.0

* Initial stable release of `xue_hua_navite_background_downloader`.
* Native multi-task background download manager across Android, iOS, macOS, Windows, and Linux.
* Local disk task persistence across app restarts with automatic state recovery.
* HTTP `Range` (`206 Partial Content`) and native `resumeData` pause/resume support with `.part` temporary files.
* Built-in system notification progress display across mobile and desktop platforms.
* Priority-based concurrent download scheduling (`low`, `normal`, `high`, `critical`).
* File conflict resolution policies (`overwrite`, `uniqueName`, `skip`, `fail`).
* Optional file integrity verification (`MD5` and `SHA-256`).
* Real-time throttled progress stream with download speed (`bytesPerSecond`) and ETA calculation.
* Bundled AI coding agent skill (`skills/xue_hua_navite_background_downloader-usage/SKILL.md`).
