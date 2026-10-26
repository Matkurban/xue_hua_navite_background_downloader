import 'package:flutter_driver/flutter_driver.dart';
import 'package:test/test.dart';

/// Drives the example dashboard over flutter_driver.
///
/// The same script is strict on macOS, Windows, Linux, and the iOS simulator.
/// Phone width builds every control in `dashboard-scroll` (see the example
/// app). Each tap scrolls its target into view, text entry dismisses the
/// software keyboard, and finders wait up to 30s. No iOS step is skipped.
///
/// A 1 GiB OVH payload stays in `running` long enough to observe the queue,
/// pause, and resume without depending on a transfer that finishes in one frame.
/// Cancel assertions do not require downloaded bytes: on a fast link a task can
/// be canceled before the first progress event.
void main() {
  const smallFile = 'driver_small.bin';
  const holdFile = 'driver_hold.dat';
  const queuedFile = 'driver_queued.dat';
  const smallUrl = 'https://httpbin.org/bytes/65536';
  const holdUrl = 'https://proof.ovh.net/files/1Gb.dat';

  late FlutterDriver driver;

  setUpAll(() async {
    driver = await FlutterDriver.connect(timeout: const Duration(minutes: 2));
  });

  tearDownAll(() async {
    try {
      await driver.runUnsynchronized(() async {
        await _tap(driver, 'cancel-all-button');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
    } catch (_) {
      // The app may already be gone if the test failed during connect.
    }
    await driver.close();
  });

  test('dashboard configures, downloads, and controls the queue', () async {
    await driver.runUnsynchronized(() async {
      // ignore: avoid_print
      print('STEP ready');
      await _expectBanner(
        driver,
        'Ready on',
        timeout: const Duration(seconds: 45),
      );
      await _tap(driver, 'notifications-switch');
      await _expectBanner(driver, 'notifications=false');

      await _tap(driver, 'concurrency-dec');
      await _expectBanner(driver, 'maxConcurrentTasks=2');
      await _tap(driver, 'concurrency-dec');
      await _expectBanner(driver, 'maxConcurrentTasks=1');
      await _tap(driver, 'concurrency-inc');
      await _expectBanner(driver, 'maxConcurrentTasks=2');
      await _tap(driver, 'concurrency-dec');
      await _expectBanner(driver, 'maxConcurrentTasks=1');

      // ignore: avoid_print
      print('STEP enqueue small');
      await _setField(driver, 'download-filename-field', smallFile);
      await _setField(driver, 'download-url-field', smallUrl);
      await _tap(driver, 'enqueue-task-button');
      await _waitStatus(driver, smallFile, _isCompleted);
      final smallProgress = await _waitProgress(
        driver,
        smallFile,
        (text) => text.contains('100.0%') || text.contains('64.0 KB'),
      );
      expect(smallProgress, contains('Progress:'));
      await driver.waitFor(
        find.text('Verified on disk'),
        timeout: const Duration(seconds: 20),
      );

      // ignore: avoid_print
      print('STEP group filter');
      // The filename field keeps the same string, so match the task chip.
      await _tap(driver, 'group-filter-custom');
      await _expectKeyText(driver, 'active-group-filter', 'Group: custom');
      await driver.waitFor(
        find.byValueKey('status-$smallFile'),
        timeout: const Duration(seconds: 10),
      );
      await _tap(driver, 'group-filter-batch');
      await _expectKeyText(driver, 'active-group-filter', 'Group: batch_demo');
      await driver.waitForAbsent(
        find.byValueKey('status-$smallFile'),
        timeout: const Duration(seconds: 10),
      );
      await _tap(driver, 'group-filter-all');
      await _expectKeyText(driver, 'active-group-filter', 'Group: all');
      await driver.waitFor(
        find.byValueKey('status-$smallFile'),
        timeout: const Duration(seconds: 10),
      );

      // ignore: avoid_print
      print('STEP hold download');
      await _setField(driver, 'download-filename-field', holdFile);
      await _setField(driver, 'download-url-field', holdUrl);
      await _tap(driver, 'enqueue-task-button');
      await _waitStatus(driver, holdFile, _isRunning);
      await _waitProgress(driver, holdFile, (text) => !text.contains('(0 B'));

      // ignore: avoid_print
      print('STEP queued download');
      await _setField(driver, 'download-filename-field', queuedFile);
      await _tap(driver, 'enqueue-task-button');
      await _waitStatus(driver, queuedFile, _isQueued);
      expect(await _status(driver, holdFile), contains('RUNNING'));
      await _expectKeyText(driver, 'stat-running', 'Running: 1');

      // ignore: avoid_print
      print('STEP pause resume');
      await _tap(driver, 'pause-$holdFile');
      await _waitStatus(driver, holdFile, _isPaused);
      final pausedAt = await _progress(driver, holdFile);
      expect(pausedAt.contains('(0 B'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await _progress(driver, holdFile), pausedAt);

      await _tap(driver, 'resume-$holdFile');
      await _waitStatus(
        driver,
        holdFile,
        (text) => _isRunning(text) || _isQueued(text),
      );
      // The paused worker keeps the only slot until it exits. If it exits
      // during the pause window, the other file starts and hold stays queued.
      // That is the scheduler, not a dropped event. Free the slot so resume
      // is visible without waiting out the 1 GiB transfer.
      if (_isQueued(await _status(driver, holdFile))) {
        await _tap(driver, 'pause-$queuedFile');
        await _waitStatus(driver, queuedFile, _isPaused);
      }
      await _waitStatus(driver, holdFile, _isRunning);

      // ignore: avoid_print
      print('STEP batch');
      await _tap(driver, 'enqueue-batch-button');
      await driver.waitFor(
        find.text('ovh_test_10mb.dat'),
        timeout: const Duration(seconds: 20),
      );
      await _waitStatus(driver, 'httpbin_64kb.bin', _isQueued);

      await _tap(driver, 'pause-all-button');
      await _waitStatus(driver, holdFile, _isPaused);
      await _waitStatus(driver, 'httpbin_64kb.bin', _isPaused);

      await _tap(driver, 'resume-all-button');
      await _waitStatus(
        driver,
        'httpbin_64kb.bin',
        (text) => _isRunning(text) || _isCompleted(text) || _isQueued(text),
      );
      await _waitStatus(
        driver,
        'httpbin_64kb.bin',
        (text) => _isRunning(text) || _isCompleted(text),
        timeout: const Duration(seconds: 40),
      );

      // ignore: avoid_print
      print('STEP cancel all');
      await _tap(driver, 'cancel-all-button');
      await _waitStatus(driver, holdFile, _isCanceled);
      // Pausing the hold task frees its slot once the worker exits, so this
      // file may run and finish on a fast link before Cancel All. Either
      // terminal state is valid; do not require downloaded bytes.
      await _waitStatus(
        driver,
        queuedFile,
        (text) => _isCanceled(text) || _isCompleted(text),
      );
    });
  }, timeout: const Timeout(Duration(minutes: 8)));
}

const _kTapTimeout = Duration(seconds: 30);

Future<void> _tap(FlutterDriver driver, String key) async {
  final finder = find.byValueKey(key);
  await _reveal(driver, finder);
  await driver.waitFor(finder, timeout: _kTapTimeout);
  await driver.tap(finder, timeout: _kTapTimeout);
  await _settle();
}

/// Scrolls [item] into the control pane, task pane, or phone dashboard.
///
/// A failure here is ignored: desktop controls are often already on screen,
/// and the following `waitFor` reports a missing key. iOS needs the scroll
/// because the enqueue fields sit below the fold.
Future<void> _reveal(FlutterDriver driver, SerializableFinder item) async {
  try {
    await driver.scrollIntoView(
      item,
      alignment: 0.15,
      timeout: const Duration(seconds: 8),
    );
  } catch (_) {
    // Already visible, or this key has no scrollable ancestor.
  }
}

Future<void> _settle() {
  return Future<void>.delayed(const Duration(milliseconds: 150));
}

Future<void> _setField(FlutterDriver driver, String key, String value) async {
  await _tap(driver, key);
  // The software keyboard on iOS attaches the input connection after focus.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  try {
    await driver.enterText(value, timeout: _kTapTimeout);
  } catch (_) {
    await _tap(driver, key);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await driver.enterText(value, timeout: _kTapTimeout);
  }
  await _dismissKeyboard(driver);
}

/// Taps the status banner, which sits outside the text fields, so iOS hides
/// the keyboard before the next control is tapped. Desktop banners have no
/// action.
Future<void> _dismissKeyboard(FlutterDriver driver) async {
  try {
    await driver.tap(
      find.byValueKey('status-banner'),
      timeout: const Duration(seconds: 5),
    );
  } catch (_) {
    // The banner is only a focus sink. A miss must not fail the step.
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

Future<void> _expectKeyText(
  FlutterDriver driver,
  String key,
  String exact, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final finder = find.byValueKey(key);
  final end = DateTime.now().add(timeout);
  var last = '';
  Object? lastError;
  while (DateTime.now().isBefore(end)) {
    try {
      last = await driver.getText(finder);
      if (last == exact) {
        return;
      }
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Text for $key stayed "$last" ($lastError); expected "$exact"');
}

Future<void> _expectBanner(
  FlutterDriver driver,
  String fragment, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final finder = find.byValueKey('status-banner');
  final end = DateTime.now().add(timeout);
  var last = '';
  while (DateTime.now().isBefore(end)) {
    last = await driver.getText(finder);
    if (last.contains(fragment)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  fail('Banner "$last" did not contain "$fragment"');
}

Future<String> _status(FlutterDriver driver, String fileName) {
  return driver.getText(find.byValueKey('status-$fileName'));
}

Future<String> _progress(FlutterDriver driver, String fileName) {
  return driver.getText(find.byValueKey('progress-$fileName'));
}

Future<String> _waitStatus(
  FlutterDriver driver,
  String fileName,
  bool Function(String text) predicate, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final finder = find.byValueKey('status-$fileName');
  final end = DateTime.now().add(timeout);
  Object? lastError;
  var last = '';
  while (DateTime.now().isBefore(end)) {
    try {
      await _reveal(driver, finder);
      last = await driver.getText(finder);
      if (predicate(last)) {
        return last;
      }
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Status for $fileName stayed "$last" ($lastError)');
}

Future<String> _waitProgress(
  FlutterDriver driver,
  String fileName,
  bool Function(String text) predicate, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final finder = find.byValueKey('progress-$fileName');
  final end = DateTime.now().add(timeout);
  var last = '';
  while (DateTime.now().isBefore(end)) {
    try {
      await _reveal(driver, finder);
      last = await driver.getText(finder);
      if (predicate(last)) {
        return last;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Progress for $fileName stayed "$last"');
}

bool _isRunning(String text) => text.startsWith('RUNNING');

bool _isQueued(String text) => text.startsWith('QUEUED');

bool _isPaused(String text) => text.startsWith('PAUSED');

bool _isCompleted(String text) => text.startsWith('COMPLETED');

bool _isCanceled(String text) => text.startsWith('CANCELED');
