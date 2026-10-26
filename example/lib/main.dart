import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

void main() {
  runApp(const DownloaderExampleApp());
}

/// Full-featured demonstration app for `xue_hua_navite_background_downloader`.
class DownloaderExampleApp extends StatelessWidget {
  const DownloaderExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XueHua Native Background Downloader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F62FE),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F62FE),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const DownloaderDashboardPage(),
    );
  }
}

class _PresetSample {
  const _PresetSample({
    required this.label,
    required this.url,
    required this.fileName,
    required this.priority,
  });

  final String label;
  final String url;
  final String fileName;
  final DownloadPriority priority;
}

const List<_PresetSample> _kPresetSamples = <_PresetSample>[
  _PresetSample(
    label: 'HTTPBin 64KB Binary (Small + Instant)',
    url: 'https://httpbin.org/bytes/65536',
    fileName: 'httpbin_64kb.bin',
    priority: DownloadPriority.critical,
  ),
  _PresetSample(
    label: 'OVH 1 MB Test Binary (Range Resume)',
    url: 'https://proof.ovh.net/files/1Mb.dat',
    fileName: 'ovh_test_1mb.dat',
    priority: DownloadPriority.high,
  ),
  _PresetSample(
    label: 'OVH 10 MB Test Binary (Pause/Resume Demo)',
    url: 'https://proof.ovh.net/files/10Mb.dat',
    fileName: 'ovh_test_10mb.dat',
    priority: DownloadPriority.normal,
  ),
  _PresetSample(
    label: 'Sample JSON Spec (GitHub Raw)',
    url: 'https://raw.githubusercontent.com/dart-lang/site-www/main/pubspec.yaml',
    fileName: 'dart_site_pubspec.yaml',
    priority: DownloadPriority.low,
  ),
];

class DownloaderDashboardPage extends StatefulWidget {
  const DownloaderDashboardPage({super.key});

  @override
  State<DownloaderDashboardPage> createState() =>
      _DownloaderDashboardPageState();
}

class _DownloaderDashboardPageState extends State<DownloaderDashboardPage> {
  final XueHuaNaviteBackgroundDownloader _downloader =
      XueHuaNaviteBackgroundDownloader.instance;

  final TextEditingController _urlController = TextEditingController(
    text: 'https://proof.ovh.net/files/10Mb.dat',
  );
  final TextEditingController _fileNameController = TextEditingController(
    text: 'custom_download_10mb.dat',
  );
  final TextEditingController _checksumController = TextEditingController();

  StreamSubscription<DownloadTask>? _taskSubscription;
  DownloaderCapabilities? _capabilities;
  final Map<String, DownloadTask> _tasks = <String, DownloadTask>{};

  int _maxConcurrentTasks = 3;
  bool _enableNotifications = true;
  bool _requiresUnmetered = false;
  DownloadPriority _selectedPriority = DownloadPriority.normal;
  DownloadConflictResolution _selectedConflict =
      DownloadConflictResolution.overwrite;
  ChecksumAlgorithm _selectedChecksumAlgo = ChecksumAlgorithm.sha256;
  String _selectedGroupFilter = 'all';
  String _statusBanner = 'Initializing native background downloader...';

  @override
  void initState() {
    super.initState();
    _taskSubscription = _downloader.taskUpdates.listen(_onTaskUpdate);
    _initializeDownloader();
  }

  Future<void> _initializeDownloader() async {
    try {
      await _downloader.configure(
        DownloaderConfig(
          maxConcurrentTasks: _maxConcurrentTasks,
          connectTimeoutMs: 15000,
          readTimeoutMs: 30000,
          progressUpdateIntervalMs: 200,
          enableNotifications: _enableNotifications,
        ),
      );
      final caps = await _downloader.getCapabilities();
      final existingTasks = await _downloader.getAllTasks();
      if (!mounted) return;
      setState(() {
        _capabilities = caps;
        for (final t in existingTasks) {
          _tasks[t.taskId] = t;
        }
        _statusBanner =
            'Ready on ${caps.platform} (${caps.nativeEngine}) • Restored ${existingTasks.length} persisted task(s)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusBanner = 'Initialization error: $e';
      });
    }
  }

  void _onTaskUpdate(DownloadTask task) {
    if (!mounted) return;
    setState(() {
      _tasks[task.taskId] = task;
    });
  }

  void _setMaxConcurrent(int value) {
    setState(() {
      _maxConcurrentTasks = value.clamp(1, 8);
    });
    _applyConfiguration();
  }

  Future<void> _applyConfiguration() async {
    await _downloader.configure(
      DownloaderConfig(
        maxConcurrentTasks: _maxConcurrentTasks,
        enableNotifications: _enableNotifications,
      ),
    );
    if (!mounted) return;
    setState(() {
      _statusBanner =
          'Updated config: maxConcurrentTasks=$_maxConcurrentTasks, notifications=$_enableNotifications';
    });
  }

  Future<void> _requestNotificationPermission() async {
    final granted = await _downloader.requestNotificationPermission();
    if (!mounted) return;
    setState(() {
      _statusBanner = granted
          ? 'System notification permission granted'
          : 'System notification permission denied or unavailable';
    });
  }

  Future<void> _enqueueCustomTask() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final fileName = _fileNameController.text.trim();
    final checksum = _checksumController.text.trim();

    try {
      final task = await _downloader.enqueue(
        DownloadRequest(
          url: url,
          saveDirectory: _capabilities?.defaultDownloadDirectory ?? '',
          fileName: fileName.isEmpty ? null : fileName,
          group: 'custom',
          priority: _selectedPriority,
          conflictResolution: _selectedConflict,
          requiresUnmeteredNetwork: _requiresUnmetered,
          expectedChecksum: checksum.isEmpty ? null : checksum,
          checksumAlgorithm: _selectedChecksumAlgo,
          notificationConfig: DownloadNotificationConfig(
            enabled: _enableNotifications,
            runningBody: 'Downloading {fileName}: {progress}% ({speed})',
            completedBody: 'Completed: {fileName}',
            failedBody: 'Failed: {fileName}',
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _tasks[task.taskId] = task;
        _statusBanner =
            'Enqueued task: ${task.fileName} (${task.priority.name})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusBanner = 'Failed to enqueue task: $e';
      });
    }
  }

  Future<void> _enqueueBatchDemo() async {
    final saveDir = _capabilities?.defaultDownloadDirectory ?? '';
    final requests = _kPresetSamples
        .map(
          (preset) => DownloadRequest(
            url: preset.url,
            saveDirectory: saveDir,
            fileName: preset.fileName,
            group: 'batch_demo',
            priority: preset.priority,
            conflictResolution: _selectedConflict,
            requiresUnmeteredNetwork: _requiresUnmetered,
            checksumAlgorithm: ChecksumAlgorithm.sha256,
            notificationConfig: DownloadNotificationConfig(
              enabled: _enableNotifications,
            ),
          ),
        )
        .toList();

    final created = await _downloader.enqueueAll(requests);
    if (!mounted) return;
    setState(() {
      for (final t in created) {
        _tasks[t.taskId] = t;
      }
      _statusBanner =
          'Batch enqueued ${created.length} multi-priority tasks into queue';
    });
  }

  Future<void> _refreshPersistedTasks() async {
    final list = await _downloader.getAllTasks();
    if (!mounted) return;
    setState(() {
      _tasks
        ..clear()
        ..addEntries(list.map((t) => MapEntry(t.taskId, t)));
      _statusBanner = 'Reloaded ${list.length} task(s) from native store';
    });
  }

  List<DownloadTask> get _filteredTasks {
    final list = _tasks.values
        .where(
          (t) =>
              _selectedGroupFilter == 'all' || t.group == _selectedGroupFilter,
        )
        .toList();
    list.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return list;
  }

  @override
  void dispose() {
    _taskSubscription?.cancel();
    _urlController.dispose();
    _fileNameController.dispose();
    _checksumController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _filteredTasks;
    final runningCount = _tasks.values
        .where((t) => t.status == DownloadStatus.running)
        .length;
    final queuedCount = _tasks.values
        .where((t) => t.status == DownloadStatus.queued)
        .length;
    final pausedCount = _tasks.values
        .where((t) => t.status == DownloadStatus.paused)
        .length;
    final completedCount = _tasks.values
        .where((t) => t.status == DownloadStatus.completed)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Native Background Downloader'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Request Notification Permission',
            icon: const Icon(Icons.notifications_active_outlined),
            onPressed: _requestNotificationPermission,
          ),
          IconButton(
            tooltip: 'Reload Persisted Tasks',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshPersistedTasks,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildStatusBanner(
            runningCount: runningCount,
            queuedCount: queuedCount,
            pausedCount: pausedCount,
            completedCount: completedCount,
          ),
          Expanded(child: _buildBody(tasks)),
        ],
      ),
    );
  }

  Widget _buildBody(List<DownloadTask> tasks) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    // Wide layout puts the controls the driver taps above the capabilities
    // card so they stay inside a 1280x720 window on Linux and Windows.
    final controls = <Widget>[
      if (!wide) _buildCapabilitiesCard(),
      if (!wide) const SizedBox(height: 12),
      _buildConcurrencyAndBatchCard(),
      const SizedBox(height: 12),
      _buildNewTaskCard(),
      if (wide) const SizedBox(height: 12),
      if (wide) _buildCapabilitiesCard(),
    ];
    final taskPane = <Widget>[
      _buildTaskListHeader(tasks.length),
      const SizedBox(height: 8),
      if (tasks.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'No download tasks yet. Click "Enqueue 4-Task Priority Batch" or add a custom URL above.',
              ),
            ),
          ),
        )
      else
        ...tasks.map(_buildTaskTile),
    ];

    // Desktop windows are wide enough to keep actions on screen while the
    // task list scrolls on its own. Phone-width tests keep one column.
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 460,
            child: ListView(
              key: const ValueKey<String>('control-pane'),
              padding: const EdgeInsets.all(16),
              children: controls,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey<String>('task-pane'),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: taskPane,
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[...controls, const SizedBox(height: 16), ...taskPane],
    );
  }

  Widget _buildStatusBanner({
    required int runningCount,
    required int queuedCount,
    required int pausedCount,
    required int completedCount,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            _statusBanner,
            key: const ValueKey<String>('status-banner'),
            style: TextStyle(
              color: colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              _StatBadge(label: 'Running', count: runningCount),
              _StatBadge(label: 'Queued', count: queuedCount),
              _StatBadge(label: 'Paused', count: pausedCount),
              _StatBadge(label: 'Done', count: completedCount),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilitiesCard() {
    final caps = _capabilities;
    if (caps == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Loading native platform capabilities...'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.memory_outlined, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Platform Engine: ${caps.platform.toUpperCase()} (${caps.nativeEngine})',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Default Save Path: ${caps.defaultDownloadDirectory}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                _CapabilityChip(
                  label: 'Background',
                  supported: caps.supportsBackgroundExecution,
                ),
                _CapabilityChip(
                  label: 'HTTP Range Pause/Resume',
                  supported: caps.supportsPauseResume,
                ),
                _CapabilityChip(
                  label: 'Disk Persistence',
                  supported: caps.supportsPersistence,
                ),
                _CapabilityChip(
                  label: 'System Notifications',
                  supported: caps.supportsSystemNotifications,
                ),
                _CapabilityChip(
                  label: 'MD5 / SHA-256 Checksum',
                  supported: caps.supportsChecksumVerification,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConcurrencyAndBatchCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Global Queue & Multi-Task Controls',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Max Concurrent Downloads: $_maxConcurrentTasks',
                        key: const ValueKey<String>('max-concurrent-label'),
                      ),
                      Row(
                        children: <Widget>[
                          IconButton(
                            key: const ValueKey<String>('concurrency-dec'),
                            tooltip: 'Decrease max concurrent downloads',
                            onPressed: () =>
                                _setMaxConcurrent(_maxConcurrentTasks - 1),
                            icon: const Icon(Icons.remove),
                          ),
                          Expanded(
                            child: Slider(
                              key: const ValueKey<String>(
                                'max-concurrent-slider',
                              ),
                              value: _maxConcurrentTasks.toDouble(),
                              min: 1,
                              max: 8,
                              divisions: 7,
                              label: '$_maxConcurrentTasks',
                              onChanged: (value) {
                                setState(() {
                                  _maxConcurrentTasks = value.round();
                                });
                              },
                              onChangeEnd: (_) => _applyConfiguration(),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey<String>('concurrency-inc'),
                            tooltip: 'Increase max concurrent downloads',
                            onPressed: () =>
                                _setMaxConcurrent(_maxConcurrentTasks + 1),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey<String>('notifications-switch'),
                  value: _enableNotifications,
                  onChanged: (val) {
                    setState(() {
                      _enableNotifications = val;
                    });
                    _applyConfiguration();
                  },
                ),
                const Text('Notifications'),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  key: const ValueKey<String>('enqueue-batch-button'),
                  onPressed: _enqueueBatchDemo,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Enqueue 4-Task Priority Batch'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('pause-all-button'),
                  onPressed: () async {
                    await _downloader.pauseAll();
                    await _refreshPersistedTasks();
                  },
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text('Pause All'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('resume-all-button'),
                  onPressed: () async {
                    await _downloader.resumeAll();
                    await _refreshPersistedTasks();
                  },
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Resume All'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('cancel-all-button'),
                  onPressed: () async {
                    await _downloader.cancelAll();
                    await _refreshPersistedTasks();
                  },
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel All'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('clear-completed-button'),
                  onPressed: () async {
                    final removed = await _downloader.clearCompleted(
                      deleteFiles: false,
                    );
                    await _refreshPersistedTasks();
                    if (!mounted) return;
                    setState(() {
                      _statusBanner = 'Cleared $removed completed task(s)';
                    });
                  },
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('Clear Completed'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewTaskCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Create Custom Download Task',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey<String>('enqueue-task-button'),
                  onPressed: _enqueueCustomTask,
                  icon: const Icon(Icons.download),
                  label: const Text('Enqueue Task'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey<String>('download-url-field'),
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Download URL',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('download-filename-field'),
                    controller: _fileNameController,
                    decoration: const InputDecoration(
                      labelText: 'File Name (Optional)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _checksumController,
                    decoration: const InputDecoration(
                      labelText: 'Expected Checksum (Optional Hex)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                DropdownButton<DownloadPriority>(
                  value: _selectedPriority,
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedPriority = val);
                  },
                  items: DownloadPriority.values
                      .map(
                        (p) => DropdownMenuItem<DownloadPriority>(
                          value: p,
                          child: Text('Priority: ${p.name}'),
                        ),
                      )
                      .toList(),
                ),
                DropdownButton<DownloadConflictResolution>(
                  value: _selectedConflict,
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedConflict = val);
                  },
                  items: DownloadConflictResolution.values
                      .map(
                        (c) => DropdownMenuItem<DownloadConflictResolution>(
                          value: c,
                          child: Text('Conflict: ${c.name}'),
                        ),
                      )
                      .toList(),
                ),
                DropdownButton<ChecksumAlgorithm>(
                  value: _selectedChecksumAlgo,
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedChecksumAlgo = val);
                    }
                  },
                  items: ChecksumAlgorithm.values
                      .map(
                        (a) => DropdownMenuItem<ChecksumAlgorithm>(
                          value: a,
                          child: Text('Hash: ${a.name.toUpperCase()}'),
                        ),
                      )
                      .toList(),
                ),
                FilterChip(
                  label: const Text('Unmetered Wi-Fi Only'),
                  selected: _requiresUnmetered,
                  onSelected: (v) => setState(() => _requiresUnmetered = v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskListHeader(int count) {
    return Column(
      mainAxisAlignment: .start,
      children: <Widget>[
        Text(
          'Persisted & Active Tasks ($count)',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'Group: $_selectedGroupFilter',
          key: const ValueKey<String>('active-group-filter'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: <Widget>[
            TextButton(
              key: const ValueKey<String>('group-filter-all'),
              onPressed: () {
                setState(() => _selectedGroupFilter = 'all');
              },
              child: Text(
                _selectedGroupFilter == 'all' ? 'All (selected)' : 'All',
              ),
            ),
            TextButton(
              key: const ValueKey<String>('group-filter-batch'),
              onPressed: () {
                setState(() => _selectedGroupFilter = 'batch_demo');
              },
              child: Text(
                _selectedGroupFilter == 'batch_demo'
                    ? 'Batch (selected)'
                    : 'Batch',
              ),
            ),
            TextButton(
              key: const ValueKey<String>('group-filter-custom'),
              onPressed: () {
                setState(() => _selectedGroupFilter = 'custom');
              },
              child: Text(
                _selectedGroupFilter == 'custom'
                    ? 'Custom (selected)'
                    : 'Custom',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTaskTile(DownloadTask task) {
    final pct = task.progress >= 0
        ? (task.progress * 100).clamp(0.0, 100.0)
        : 0.0;
    final existsOnDisk =
        task.status == DownloadStatus.completed &&
        task.savePath.isNotEmpty &&
        File(task.savePath).existsSync();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    task.fileName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
                Chip(
                  label: Text(
                    '${task.status.name.toUpperCase()} • ${task.priority.name}',
                    key: ValueKey<String>('status-${task.fileName}'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              task.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: task.progress >= 0 ? task.progress.clamp(0.0, 1.0) : null,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: <Widget>[
                Text(
                  'Progress: ${pct.toStringAsFixed(1)}% (${_formatBytes(task.downloadedBytes)} / ${task.totalBytes > 0 ? _formatBytes(task.totalBytes) : "?"})',
                  key: ValueKey<String>('progress-${task.fileName}'),
                ),
                if (task.status == DownloadStatus.running)
                  Text('Speed: ${_formatBytes(task.bytesPerSecond.round())}/s'),
                if (task.estimatedRemaining != null &&
                    task.status == DownloadStatus.running)
                  Text('ETA: ${task.estimatedRemaining!.inSeconds}s'),
                if (existsOnDisk)
                  const Text(
                    'Verified on disk',
                    style: TextStyle(color: Colors.green),
                  ),
              ],
            ),
            if (task.error != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                'Error [${task.error!.code}]: ${task.error!.message}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                if (task.status == DownloadStatus.running ||
                    task.status == DownloadStatus.queued)
                  TextButton.icon(
                    key: ValueKey<String>('pause-${task.fileName}'),
                    onPressed: () => _downloader.pause(task.taskId),
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('Pause'),
                  ),
                if (task.status == DownloadStatus.paused)
                  TextButton.icon(
                    key: ValueKey<String>('resume-${task.fileName}'),
                    onPressed: () => _downloader.resume(task.taskId),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Resume'),
                  ),
                if (task.status == DownloadStatus.failed ||
                    task.status == DownloadStatus.canceled)
                  TextButton.icon(
                    onPressed: () => _downloader.retry(task.taskId),
                    icon: const Icon(Icons.replay, size: 18),
                    label: const Text('Retry'),
                  ),
                if (task.status.isActive ||
                    task.status == DownloadStatus.paused)
                  TextButton.icon(
                    key: ValueKey<String>('cancel-${task.fileName}'),
                    onPressed: () => _downloader.cancel(task.taskId),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Cancel'),
                  ),
                TextButton.icon(
                  onPressed: () async {
                    await _downloader.removeTask(task.taskId, deleteFile: true);
                    if (!mounted) return;
                    setState(() {
                      _tasks.remove(task.taskId);
                    });
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024.0;
    if (kb < 1024.0) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024.0;
    return '${mb.toStringAsFixed(2)} MB';
  }
}

class _StatBadge extends StatelessWidget {
  const _StatBadge({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: $count',
        key: ValueKey<String>('stat-${label.toLowerCase()}'),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.supported});

  final String label;
  final bool supported;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        supported ? Icons.check_circle : Icons.cancel,
        size: 16,
        color: supported ? Colors.green : Colors.grey,
      ),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
    );
  }
}
