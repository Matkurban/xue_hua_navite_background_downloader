import 'package:flutter_driver/flutter_driver.dart';
import 'package:test/test.dart';

/// Drives the example dashboard over flutter_driver.
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
      expect(
        await driver.getText(find.byValueKey('active-group-filter')),
        'Group: custom',
      );
      await driver.waitFor(
        find.byValueKey('status-$smallFile'),
        timeout: const Duration(seconds: 10),
      );
      await _tap(driver, 'group-filter-batch');
      expect(
        await driver.getText(find.byValueKey('active-group-filter')),
        'Group: batch_demo',
      );
      await driver.waitForAbsent(
        find.byValueKey('status-$smallFile'),
        timeout: const Duration(seconds: 10),
      );
      await _tap(driver, 'group-filter-all');
      expect(
        await driver.getText(find.byValueKey('active-group-filter')),
        'Group: all',
      );
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
      expect(
        await driver.getText(find.byValueKey('stat-running')),
        'Running: 1',
      );

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
      await _waitStatus(driver, queuedFile, _isCanceled);
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}

const _kTapTimeout = Duration(seconds: 15);

Future<void> _tap(FlutterDriver driver, String key) async {
  final finder = find.byValueKey(key);
  if (_isTaskRowKey(key)) {
    await _revealInTaskPane(driver, finder);
  }
  await driver.waitFor(finder, timeout: _kTapTimeout);
  await driver.tap(finder, timeout: _kTapTimeout);
}

bool _isTaskRowKey(String key) {
  if (key.endsWith('-button') ||
      key.endsWith('-field') ||
      key.endsWith('-switch')) {
    return false;
  }
  return key.startsWith('pause-') ||
      key.startsWith('resume-') ||
      key.startsWith('cancel-') ||
      key.startsWith('status-') ||
      key.startsWith('progress-');
}

/// Brings a task-row widget into the task list. Keys are the same on Linux
/// and Windows; the list itself is the scrollable, so this does not depend
/// on a host path or a single-column layout.
Future<void> _revealInTaskPane(
  FlutterDriver driver,
  SerializableFinder item,
) async {
  try {
    await driver.waitFor(item, timeout: const Duration(seconds: 2));
    await driver.scrollIntoView(item, timeout: const Duration(seconds: 5));
    return;
  } catch (_) {
    // The tile is below the fold of the lazy task list.
  }
  await driver.scrollUntilVisible(
    find.byValueKey('task-pane'),
    item,
    dyScroll: -160,
    timeout: const Duration(seconds: 20),
  );
}

Future<void> _setField(FlutterDriver driver, String key, String value) async {
  await _tap(driver, key);
  await driver.enterText(value, timeout: _kTapTimeout);
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
      await _revealInTaskPane(driver, finder);
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
      await _revealInTaskPane(driver, finder);
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
