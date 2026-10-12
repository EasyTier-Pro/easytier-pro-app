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
  func testSimulatorReportsPackagedCoreAndRejectsVPN() async throws {
    let bridge = EasyTierFlutterBridge()
    let status = try await call(bridge, "readStatus", [:]) as? [String: Any]
    XCTAssertEqual(status?["running"] as? Bool, false)
    XCTAssertEqual(status?["core_version"] as? String,
                   Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String)
    do {
      _ = try await call(bridge, "ensureRunning", [:])
      XCTFail("Simulator must not report a working system VPN")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("模拟器不支持系统 VPN"))
    }
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
