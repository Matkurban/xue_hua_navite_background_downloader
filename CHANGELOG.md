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
