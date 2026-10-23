import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xue_hua_navite_background_downloader/xue_hua_navite_background_downloader.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('getCapabilities returns valid platform capabilities', (
    WidgetTester tester,
  ) async {
    final downloader = XueHuaNaviteBackgroundDownloader.instance;
    final caps = await downloader.getCapabilities();
    expect(caps.platform.isNotEmpty, true);
    expect(caps.supportsPauseResume, true);
    expect(caps.supportsPersistence, true);
  });
}
