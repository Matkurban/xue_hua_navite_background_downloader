import Flutter
import UIKit
import XCTest

@testable import xue_hua_navite_background_downloader

class RunnerTests: XCTestCase {
  func testGetCapabilities() {
    let plugin = XueHuaNaviteBackgroundDownloaderPlugin.shared
    let call = FlutterMethodCall(methodName: "getCapabilities", arguments: nil)

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      let map = result as? [String: Any]
      XCTAssertEqual(map?["platform"] as? String, "ios")
      XCTAssertEqual(map?["supportsPauseResume"] as? Bool, true)
      let store = map?["taskStorePath"] as? String
      XCTAssertEqual(store?.contains("xue_hua_background_downloader"), true)
      XCTAssertEqual(store?.hasSuffix("tasks.json"), true)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 2)
  }
}
