# xue_hua_navite_background_downloader

[English](README.md) | 简体中文

一款支持 **Android、iOS、macOS、Windows、Linux** 五大原生平台的 Flutter 多任务后台下载器插件。各平台均采用原生系统网络栈实现，支持优先级并发队列调度、本地磁盘跨重启任务持久化、基于 HTTP `Range`（`206 Partial Content`）与 `.part` 临时文件的断点续传、MD5/SHA-256 完整性校验以及系统级通知栏进度展示。

## 核心特性

* **五端纯原生多任务引擎**：
  * **Android**：基于 `HttpURLConnection` 并发工作池 + `XueHuaDownloadForegroundService`（`dataSync` 前台保活服务）+ `NotificationManager` 实时进度通知。
  * **iOS**：基于 `URLSessionDataTask` 流式文件句柄写入 + `UIBackgroundTaskIdentifier` 后台任务续期 + `UNUserNotificationCenter` 系统通知。
  * **macOS**：基于 `URLSessionDataTask` 流式写入 + `NSProcessInfo` 后台活动断言防止系统休眠中断 + `UNUserNotificationCenter` 系统通知。
  * **Windows**：基于原生 `WinHTTP` 异步流 + Windows CNG（`BCrypt`）原生哈希计算 + `Shell_NotifyIconW` 系统托盘通知。
  * **Linux**：基于 `libcurl`（`CURLOPT_XFERINFOFUNCTION` 实时进度回调 + `CURLOPT_RESUME_FROM_LARGE` 断点续传）+ `GLib`（`GChecksum`）+ `notify-send` 桌面通知。
* **本地持久化队列**：所有下载任务状态实时持久化到本地磁盘，应用关闭或重启后调用 `getAllTasks()` 即可恢复未完成任务并继续断点续传。
* **真断点续传**：下载过程实时写入 `.part` 临时文件，暂停后恢复时自动携带 `Range: bytes=<offset>-` 与 `If-Range`（`ETag`）请求头从精确字节偏移处继续下载。
* **多优先级与分组管理**：支持 `critical`、`high`、`normal`、`low` 四级队列优先级，支持按 `group` 批量暂停、恢复、取消或清理。
* **同名文件冲突策略**：内置 `overwrite`（覆盖）、`uniqueName`（自动追加 ` (1)` 序号）、`skip`（跳过已完成）和 `fail`（报错）四种策略。
* **文件完整性校验**：支持下载完成后由原生层自动计算并比对 `SHA-256` 或 `MD5` 校验值。
* **内置 AI 编程助手 Skill**：遵循 Dart 官方 [Ship skills with packages](https://dart.dev/tools/pub/package-skills) 规范，内置 [`skills/xue_hua_navite_background_downloader-usage/SKILL.md`](skills/xue_hua_navite_background_downloader-usage/SKILL.md)。

## 平台支持矩阵

| 功能特性 | Android | iOS | macOS | Windows | Linux |
| :--- | :---: | :---: | :---: | :---: | :---: |
| 多任务优先级并发队列 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 本地磁盘跨重启持久化 | ✅ | ✅ | ✅ | ✅ | ✅ |
| HTTP `Range` 暂停与断点续传 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 系统级通知栏进度/完成提醒 | ✅ | ✅ | ✅ | ✅ | ✅ |
| MD5 / SHA-256 文件校验 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 非计费网络（Wi-Fi/以太网）限制 | ✅ | ✅ | ✅ | ✅ | ✅ |

## 安装集成

在项目的 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  xue_hua_navite_background_downloader: ^1.0.0
```

### 安装随包分发的 AI Agent Skill

本插件按照 [Dart Package Skills 规范](https://dart.dev/tools/pub/package-skills) 提供了标准 AI 技能文件。在宿主项目根目录运行以下命令即可一键安装：

```bash
dart run skills@ get
```

## 各平台配置与注意事项

### 1. Android 注意事项

插件的 `AndroidManifest.xml` 已自动声明并合并 `INTERNET`、`ACCESS_NETWORK_STATE`、`POST_NOTIFICATIONS`、`WAKE_LOCK`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC` 权限以及 `XueHuaDownloadForegroundService` 服务，宿主工程无需手动重复注册。

* **Android 13+ (API 33+) 通知权限**：如需在系统通知栏展示下载进度条，请在启动下载前调用 `XueHuaNaviteBackgroundDownloader.instance.requestNotificationPermission()` 动态申请通知权限。

### 2. iOS 注意事项

* 如需在应用切入后台时保持下载与通知更新，请在 `ios/Runner/Info.plist` 中添加后台模式声明：

```xml
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>processing</string>
</array>
```

* 若测试环境需要下载非 HTTPS（`http://`）链接，请在 `Info.plist` 中配置 `NSAppTransportSecurity`。

### 3. macOS 注意事项

macOS 默认开启 App Sandbox 沙盒限制，请务必在 `macos/Runner/DebugProfile.entitlements` 和 `macos/Runner/Release.entitlements` 中开启客户端网络权限与下载目录读写权限：

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.files.downloads.read-write</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### 4. Windows 注意事项

插件直接链接 Windows 系统原生 `winhttp.lib`、`bcrypt.lib`、`shell32.lib` 和 `ole32.lib`，无需额外部署第三方 DLL。内部已针对中文及特殊 Unicode 路径完成 UTF-8 与 UTF-16（`std::wstring`）双向无损转换。

### 5. Linux 注意事项

在 Linux 环境下编译时需确保系统已安装 `libcurl` 开发头文件及通知工具：

```bash
sudo apt-get install libcurl4-openssl-dev libnotify-bin
```

## 快速上手

### 1. 初始化配置与恢复持久化任务

```dart
import 'dart:async';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

final downloader = XueHuaNaviteBackgroundDownloader.instance;

Future<void> setupDownloader() async {
  // 1. 配置全局最大并发数、超时时间及通知开关
  await downloader.configure(
    const DownloaderConfig(
      maxConcurrentTasks: 3,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000,
      progressUpdateIntervalMs: 250,
      enableNotifications: true,
      autoResumeOnStartup: false,
    ),
  );

  // 2. 请求系统通知权限（适配 Android 13+、iOS、macOS）
  await downloader.requestNotificationPermission();

  // 3. 查询当前平台原生能力与默认下载目录
  final capabilities = await downloader.getCapabilities();
  print('原生引擎: ${capabilities.nativeEngine}');
  print('默认下载目录: ${capabilities.defaultDownloadDirectory}');

  // 4. 恢复上次应用关闭前持久化的下载任务列表
  final persistedTasks = await downloader.getAllTasks();
  print('已恢复历史任务数量: ${persistedTasks.length}');
}
```

### 2. 添加单任务与多任务并发队列

```dart
// 添加单个下载任务
final task = await downloader.enqueue(
  const DownloadRequest(
    url: 'https://proof.ovh.net/files/10Mb.dat',
    saveDirectory: '', // 传空字符串时自动使用当前平台默认下载目录
    fileName: 'ovh_10mb.dat',
    group: 'media',
    priority: DownloadPriority.high,
    conflictResolution: DownloadConflictResolution.uniqueName,
    requiresUnmeteredNetwork: false,
    expectedChecksum: null, // 可选：填入预期的 MD5 或 SHA-256 十六进制字符串
    checksumAlgorithm: ChecksumAlgorithm.sha256,
    notificationConfig: DownloadNotificationConfig(
      enabled: true,
      runningBody: '正在下载 {fileName}: {progress}% ({speed})',
      completedBody: '下载完成: {fileName}',
    ),
  ),
);

// 批量添加多优先级任务队列
final batchTasks = await downloader.enqueueAll([
  const DownloadRequest(
    url: 'https://proof.ovh.net/files/1Mb.dat',
    saveDirectory: '',
    fileName: 'patch_critical.dat',
    group: 'updates',
    priority: DownloadPriority.critical,
  ),
  const DownloadRequest(
    url: 'https://proof.ovh.net/files/10Mb.dat',
    saveDirectory: '',
    fileName: 'assets_normal.dat',
    group: 'updates',
    priority: DownloadPriority.normal,
  ),
]);
```

### 3. 监听实时进度与任务控制

```dart
// 监听全局任务进度流（也可使用 downloader.watchTask(taskId) 或 downloader.watchGroup(group)）
final subscription = downloader.taskUpdates.listen((DownloadTask updated) {
  final pct = (updated.progress * 100).toStringAsFixed(1);
  print('${updated.fileName} [${updated.status.name}] $pct% - ${updated.bytesPerSecond} B/s');
});

// 单任务控制
await downloader.pause(task.taskId);
await downloader.resume(task.taskId);
await downloader.cancel(task.taskId, deletePartialFile: true);
await downloader.retry(task.taskId);
await downloader.removeTask(task.taskId, deleteFile: true);

// 按分组或全局批量控制
await downloader.pauseAll(group: 'updates');
await downloader.resumeAll(group: 'updates');
await downloader.cancelAll(group: 'updates');
await downloader.clearCompleted(deleteFiles: false);
```

## 全功能示例项目

完整的可视化多任务下载管理面板示例位于 [`example/lib/main.dart`](example/lib/main.dart)，包含：
* 动态调整最大并发下载数滑块（`1`–`8` 并发）
* 一键添加 4 个不同优先级的并发测试任务
* 自定义 URL、文件名、同名冲突策略（`overwrite`、`uniqueName`、`skip`、`fail`）及 `MD5` / `SHA-256` 校验值输入
* 单任务暂停/继续/取消/重试/删除，以及全局批量暂停/恢复/取消/清理已完成任务
* 实时进度条、实时网速、预计剩余时间（ETA）与跨应用重启任务恢复演示

## 作者与仓库信息

* **作者**：Matkurban
* **邮箱**：[3496354336@qq.com](mailto:3496354336@qq.com)
* **仓库地址**：[https://github.com/Matkurban/xue_hua_navite_background_downloader](https://github.com/Matkurban/xue_hua_navite_background_downloader)
* **开源协议**：[MIT License](LICENSE)
