# xue_hua_navite_background_downloader_example

Demonstrates how to use the xue_hua_navite_background_downloader plugin.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Desktop tests

The same driver and integration tests run on Linux, Windows, macOS, and the iOS simulator. Finders use `ValueKey` strings. File paths come from `Directory.systemTemp`, `Platform.pathSeparator`, or `getCapabilities()` (`defaultDownloadDirectory` and `taskStorePath`). The task store is not the same file on every host: Apple uses Application Support `xue_hua_background_downloader/tasks.json`, Android uses `filesDir/xue_hua_downloader_tasks.json`, and Linux and Windows use `xue_hua_downloader_tasks.tsv` in the default download directory.

`flutter test integration_test/` starts the desktop app once per `*_test.dart` inside one tool process. The second file often fails with `Unable to start the app`. Run each file in its own process. `example/tool/run_desktop_tests.sh` does that on Linux (under Xvfb), macOS, and Windows Git Bash. On Windows PowerShell use `example/tool/run_desktop_tests.ps1`. `example/tool/run_linux_tests.sh` is a wrapper around the shell script.

Linux needs `libcurl`, `notify-send`, and `xvfb`. Windows uses the WinHTTP engine already built with the plugin. Set `FLUTTER_BIN` when `flutter` is not on `PATH`. The runners clear `Downloads/XueHuaDownloads` and the temp `XueHuaDownloads` folder before the driver, because the plugin falls back to the temp directory when the OS has no Downloads folder. Set `XUEHUA_DOWNLOAD_DIR` to clean a different folder instead.

```bash
example/tool/run_desktop_tests.sh
```

```powershell
pwsh example/tool/run_desktop_tests.ps1
```

UI coverage uses `flutter_driver` (`example/test_driver/app.dart` enables the extension; `example/test_driver/app_test.dart` is the host script). From `example/`:

```bash
flutter drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d linux
```

```powershell
flutter drive `
  --driver=test_driver/app_test.dart `
  --target=test_driver/app.dart `
  -d windows
```

On Linux without a display, prefix the drive command with `xvfb-run -a`. The drive configures `maxConcurrentTasks`, turns notifications off, enqueues a small download to completion, filters groups, holds a queue with a large OVH file, and exercises pause, resume, batch, and cancel. Cancel checks the canceled state only. A fast link can cancel before any bytes land. Phone-width layouts (the iOS simulator) keep every keyed control in one scroll view. The driver scrolls each target into view and dismisses the software keyboard after text entry. No iOS step is skipped.

### macOS

`example/tool/run_desktop_tests.sh` selects the `macos` device on Darwin. From `example/`:

```bash
flutter test -d macos integration_test/download_api_verification_test.dart
flutter drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d macos
```

### iOS simulator

Boot a simulator, then run both suites with `example/tool/run_ios_simulator_tests.sh`. Pass a UDID as the first argument, or set `IOS_DEVICE`, when more than one simulator is available. The script runs the integration file, then the same `flutter_driver` script used on the desktop. From `example/`:

```bash
xcrun simctl boot "iPhone 16"
open -a Simulator
flutter test -d <simulator-udid> integration_test/download_api_verification_test.dart
flutter drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d <simulator-udid>
```

### Windows path length

MSBuild writes `.tlog` files under the example build tree. A checkout under a long path such as `C:\Users\...\StudioProjects\...` can exceed `MAX_PATH` and fail the Windows build. Clone into a short directory, or map the repo with a junction and build from there:

```powershell
New-Item -ItemType Junction -Path C:\bgdl -Target C:\path\to\xue_hua_navite_background_downloader
cd C:\bgdl\example
```

The Windows native googletest target stays disabled with `if(FALSE)` in `windows/CMakeLists.txt` for the same limit. Leave that guard as `if(FALSE)`. `if(FALSE AND ...)` is invalid CMake when the tests variable is unset.
