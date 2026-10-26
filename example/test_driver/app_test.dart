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
      await _expectBanner(
        driver,
        'Ready on',
        timeout: const Duration(seconds: 45),
      );

      await _tap(driver, 'concurrency-dec');
      await _expectBanner(driver, 'maxConcurrentTasks=2');
      await _tap(driver, 'concurrency-dec');
      await _expectBanner(driver, 'maxConcurrentTasks=1');
      await _tap(driver, 'concurrency-inc');
      await _expectBanner(driver, 'maxConcurrentTasks=2');
      await _tap(driver, 'concurrency-dec');
      await _expectBanner(driver, 'maxConcurrentTasks=1');

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

      await driver.scrollIntoView(find.text('Custom'));
      await driver.tap(find.text('Custom'));
      await driver.waitFor(find.text(smallFile));
      await driver.scrollIntoView(find.text('Batch'));
      await driver.tap(find.text('Batch'));
      await driver.waitForAbsent(find.text(smallFile));
      await driver.scrollIntoView(find.text('All'));
      await driver.tap(find.text('All'));
      await driver.waitFor(find.text(smallFile));

      await _setField(driver, 'download-filename-field', holdFile);
      await _setField(driver, 'download-url-field', holdUrl);
      await _tap(driver, 'enqueue-task-button');
      await _waitStatus(driver, holdFile, _isRunning);
      final pausedAt = await _waitProgress(
        driver,
        holdFile,
        (text) => !text.contains('(0 B'),
      );

      await _setField(driver, 'download-filename-field', queuedFile);
      await _tap(driver, 'enqueue-task-button');
      await _waitStatus(driver, queuedFile, _isQueued);
      expect(await _status(driver, holdFile), contains('RUNNING'));
      expect(
        await driver.getText(find.byValueKey('stat-running')),
        'Running: 1',
      );

      await _tap(driver, 'pause-$holdFile');
      await _waitStatus(driver, holdFile, _isPaused);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await _progress(driver, holdFile), pausedAt);

      await _tap(driver, 'resume-$holdFile');
      await _waitStatus(
        driver,
        holdFile,
        (text) => _isRunning(text) || _isQueued(text),
      );
      await _waitStatus(driver, holdFile, _isRunning);

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

      await _tap(driver, 'cancel-all-button');
      await _waitStatus(driver, holdFile, _isCanceled);
      await _waitStatus(driver, queuedFile, _isCanceled);
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _tap(FlutterDriver driver, String key) async {
  final finder = find.byValueKey(key);
  await driver.scrollIntoView(finder);
  await driver.tap(finder);
}

Future<void> _setField(FlutterDriver driver, String key, String value) async {
  final finder = find.byValueKey(key);
  await driver.scrollIntoView(finder);
  await driver.tap(finder);
  await driver.enterText(value);
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
      await driver.waitFor(finder, timeout: const Duration(seconds: 2));
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
      await driver.waitFor(finder, timeout: const Duration(seconds: 2));
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
