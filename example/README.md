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

## Linux tests

From the repository root, with `libcurl` and `xvfb` installed:

```bash
example/tool/run_linux_tests.sh
```

The script builds the example for Linux, runs the plugin and widget tests, then runs each `integration_test/*_test.dart` in its own process. A single `flutter test integration_test/` invocation reuses the desktop device and often fails on the second file with `Unable to start the app`. One file is safe either way; extra files should go through the script.

UI coverage uses `flutter_driver` (`example/test_driver/app.dart` enables the extension; `example/test_driver/app_test.dart` is the host script):

```bash
cd example
xvfb-run -a flutter drive \
  --driver=test_driver/app_test.dart \
  --target=test_driver/app.dart \
  -d linux
```

That drive configures `maxConcurrentTasks`, enqueues a small download to completion, filters groups, holds a queue with a large OVH file, and exercises pause, resume, batch, and cancel. Cancel checks the canceled state only — a fast link can cancel before any bytes land.
