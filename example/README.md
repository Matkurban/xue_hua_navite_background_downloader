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

The same driver and integration tests run on Linux and Windows. Finders use `ValueKey` strings, and file paths come from `Directory.systemTemp`, `Platform.pathSeparator`, or the plugin's `defaultDownloadDirectory`. Nothing in the Dart tests hardcodes a host path.

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

On Linux without a display, prefix the drive command with `xvfb-run -a`. The drive configures `maxConcurrentTasks`, turns notifications off, enqueues a small download to completion, filters groups, holds a queue with a large OVH file, and exercises pause, resume, batch, and cancel. Cancel checks the canceled state only. A fast link can cancel before any bytes land.
