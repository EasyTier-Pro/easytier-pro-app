import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testDiagnosticRedactionCoversEncodedTokenAndURL() {
    let text = "tcp://server:22020/token%2Fsecret token/secret token%2Fsecret"
    XCTAssertEqual(EasyTierShared.redacted(text, token: "token/secret", url: "tcp://server:22020/token%2Fsecret"),
                   "<redacted> <redacted> <redacted>")
  }

  func testStatusNotificationPublishesTheCommittedSnapshot() async throws {
    let before = try EasyTierShared.readStatus()
    defer { try? EasyTierShared.writeStatus(before) }
    let marker = UUID().uuidString
    let published = expectation(description: "App Group status notification")
    published.assertForOverFulfill = false
    let observer = EasyTierStatusNotification {
      if (try? EasyTierShared.readStatus()["session_id"] as? String) == marker {
        published.fulfill()
      }
    }
    try EasyTierShared.writeStatus(["session_id": marker, "vpn_ready": false])
    await fulfillment(of: [published], timeout: 2)
    withExtendedLifetime(observer) {}
    XCTAssertEqual(try EasyTierShared.readStatus()["session_id"] as? String, marker)
  }

  @MainActor
  func testKeychainThroughFlutterBridge() async throws {
    let bridge = EasyTierFlutterBridge()
    let key = "ios_native_test_\(UUID().uuidString)"
    _ = try await call(bridge, "writeSecureValue", ["key": key, "value": "test-secret"])
    let saved = try await call(bridge, "readSecureValue", ["key": key]) as? String
    XCTAssertEqual(saved, "test-secret")
    _ = try await call(bridge, "deleteSecureValue", ["key": key])
    let cleared = try await call(bridge, "readSecureValue", ["key": key])
    XCTAssertNil(cleared)
    let firstID = try await call(bridge, "getMachineId", [:]) as? String
    let secondID = try await call(bridge, "getMachineId", [:]) as? String
    XCTAssertNotNil(firstID)
    XCTAssertEqual(firstID, secondID)
  }

  #if targetEnvironment(simulator)
  @MainActor
  func testSimulatorRunsForegroundControlWithoutVPN() async throws {
    let bridge = EasyTierFlutterBridge()
    let status = try await call(bridge, "readStatus", [:]) as? [String: Any]
    XCTAssertEqual(status?["running"] as? Bool, false)
    XCTAssertEqual(status?["core_version"] as? String,
                   Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String)
    let bootstrap: [String: Any] = ["url": "tcp://127.0.0.1:9/native-test", "token": "native-test",
                                    "hostname": "native-test", "forceReinstall": false]
    do {
      let first = try await call(bridge, "ensureRunning", bootstrap) as? [String: Any]
      XCTAssertEqual(first?["running"] as? Bool, true)
      XCTAssertEqual(first?["has_networks"] as? Bool, false)
      XCTAssertEqual(first?["connected"] as? Bool, false)
      XCTAssertEqual(first?["machine_id"] as? String, status?["machine_id"] as? String)
      let second = try await call(bridge, "ensureRunning", bootstrap) as? [String: Any]
      XCTAssertEqual(first?["session_id"] as? String, second?["session_id"] as? String)
      let stale = try await call(bridge, "readStatus", ["url": "tcp://127.0.0.1:9/other", "token": "other"]) as? [String: Any]
      XCTAssertEqual(stale?["running"] as? Bool, false)
    } catch {
      _ = try? await call(bridge, "stopRuntime", [:])
      throw error
    }
    _ = try await call(bridge, "stopRuntime", [:])
    let stopped = try await call(bridge, "readStatus", [:]) as? [String: Any]
    XCTAssertEqual(stopped?["running"] as? Bool, false)
    XCTAssertEqual(stopped?["machine_id"] as? String, status?["machine_id"] as? String)
  }
  #endif

  @MainActor
  private func call(_ bridge: EasyTierFlutterBridge, _ method: String, _ arguments: [String: Any]) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
      bridge.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { result in
        if let error = result as? FlutterError {
          continuation.resume(throwing: NSError(domain: error.code, code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: error.message ?? ""]))
        } else { continuation.resume(returning: result) }
      }
    }
  }

}
