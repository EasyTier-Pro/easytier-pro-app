import Flutter
import Foundation
import NetworkExtension
import UIKit

@MainActor
final class EasyTierFlutterBridge: NSObject, @preconcurrency FlutterPlugin, @preconcurrency FlutterStreamHandler {
  private var registrar: FlutterPluginRegistrar?
  private var eventSink: FlutterEventSink?
  private var timer: Timer?
  private var statusObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?
  private var manager: NETunnelProviderManager?
  private var polling = false
  private var lastEventID = 0
  private var lastSessionID = ""
  private var wasRunning = false
  private var operation: Task<Void, Never>?

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = EasyTierFlutterBridge()
    bridge.registrar = registrar
    let channel = FlutterMethodChannel(name: "net.easytier.pro/core_runtime", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(bridge, channel: channel)
    FlutterEventChannel(name: "net.easytier.pro/core_runtime_events", binaryMessenger: registrar.messenger())
      .setStreamHandler(bridge)
    bridge.statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak bridge] _ in
      Task { @MainActor in await bridge?.poll() }
    }
    bridge.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak bridge] _ in
      Task { @MainActor in bridge?.startPolling() }
    }
    bridge.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak bridge] _ in
      Task { @MainActor in bridge?.timer?.invalidate(); bridge?.timer = nil }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "ensureRunning" || call.method == "stopRuntime" {
      let previous = operation
      let task = Task { @MainActor in
        await previous?.value
        await handleAsync(call.method, args: args, result: result)
      }
      operation = task
    } else {
      Task { @MainActor in await handleAsync(call.method, args: args, result: result) }
    }
  }

  private func handleAsync(_ method: String, args: [String: Any], result: @escaping FlutterResult) async {
    do {
      switch method {
      case "getMachineId": result(try EasyTierShared.machineID())
      case "getHostname": result("iPhone-\(try EasyTierShared.machineID().prefix(8))")
      case "readStatus":
        var status = try await readStatus()
        if let url = args["url"] as? String, let token = args["token"] as? String {
          let raw = try EasyTierShared.readSecret("runtime_bootstrap") ?? "{}"
          let saved = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] ?? [:]
          if saved["url"] != url || saved["token"] != token { status["running"] = false }
        }
        result(status)
      case "ensureRunning": result(try await ensureRunning(args))
      case "stopRuntime":
        try await stopRuntime()
        result(nil)
      case "collectNetworkInfos":
        if !isRunning { result("{\"instances\":{}}") }
        else { result(try jsonString(try await providerMessage(["method": method]))) }
      case "callJsonRpc":
        let payload = try JSONSerialization.jsonObject(with: Data((args["payloadJson"] as? String ?? "{}").utf8))
        let response = try await providerMessage(["method": method, "serviceName": args["serviceName"] ?? "",
                                                  "methodName": args["methodName"] ?? "", "payload": payload])
        result(try jsonString(response))
      case "readSecureValue": result(try EasyTierShared.readSecret(try requiredString(args, "key")))
      case "writeSecureValue":
        try EasyTierShared.writeSecret(try requiredString(args, "key"), value: try requiredString(args, "value"))
        result(nil)
      case "deleteSecureValue":
        try EasyTierShared.deleteSecret(try requiredString(args, "key"))
        result(nil)
      case "shareFile": try await shareDiagnostics(args); result(true)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      let nsError = error as NSError
      let permissionDenied = nsError.domain == NEVPNErrorDomain && nsError.code == NEVPNError.configurationReadWriteFailed.rawValue
      result(FlutterError(code: permissionDenied ? "VPN_PERMISSION_DENIED" : "IOS_RUNTIME_ERROR",
                          message: redacted(error.localizedDescription), details: nil))
    }
  }

  private var isRunning: Bool {
    guard let status = manager?.connection.status else { return false }
    return status == .connected || status == .reasserting
  }

  private func loadManager() async throws -> NETunnelProviderManager? {
    #if targetEnvironment(simulator)
    // iOS Simulator has no system Network Extension VPN service.
    manager = nil
    return nil
    #else
    let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: managers ?? []) }
      }
    }
    let bundle = Bundle.main.bundleIdentifier! + ".PacketTunnel"
    manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundle }
    return manager
    #endif
  }

  private func save(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func ensureRunning(_ args: [String: Any]) async throws -> [String: Any] {
    #if targetEnvironment(simulator)
    throw runtimeError("iOS 模拟器不支持系统 VPN，请使用真机连接网络。")
    #else
    let url = try requiredString(args, "url")
    let token = try requiredString(args, "token")
    let hostname = try requiredString(args, "hostname")
    let bootstrap = try jsonString(["url": url, "token": token, "hostname": hostname])
    let oldBootstrap = try EasyTierShared.readSecret("runtime_bootstrap")
    let manager = try await loadManager() ?? NETunnelProviderManager()
    self.manager = manager
    if oldBootstrap == bootstrap, isRunning, args["forceReinstall"] as? Bool != true {
      return try await readStatus()
    }
    if manager.connection.status != .disconnected && manager.connection.status != .invalid {
      manager.connection.stopVPNTunnel()
      try await waitFor(manager, running: false)
    }
    try EasyTierShared.writeSecret("runtime_bootstrap", value: bootstrap)
    let config = NETunnelProviderProtocol()
    config.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
    config.serverAddress = URL(string: url)?.host ?? "EasyTier Pro"
    // Secrets live in the shared Keychain, never in providerConfiguration.
    manager.protocolConfiguration = config
    manager.localizedDescription = "EasyTier Pro"
    manager.isEnabled = true
    manager.isOnDemandEnabled = false
    try await save(manager)
    try manager.connection.startVPNTunnel()
    try await waitFor(manager, running: true)
    return try await readStatus()
    #endif
  }

  private func stopRuntime() async throws {
    guard let manager = try await loadManager() else {
      try EasyTierShared.deleteSecret("runtime_bootstrap")
      return
    }
    manager.isOnDemandEnabled = false
    if manager.connection.status != .disconnected && manager.connection.status != .invalid {
      manager.connection.stopVPNTunnel()
      try await waitFor(manager, running: false)
    }
    try EasyTierShared.deleteSecret("runtime_bootstrap")
    try await save(manager)
  }

  private func waitFor(_ manager: NETunnelProviderManager, running: Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    var sawConnecting = false
    while Date() < deadline {
      let status = manager.connection.status
      if status == .connecting { sawConnecting = true }
      if running && (status == .connected || status == .reasserting) { return }
      if !running && (status == .disconnected || status == .invalid) { return }
      if running && sawConnecting && status == .disconnected {
        let state = try EasyTierShared.readStatus()
        let message = state["last_error"] as? String ?? ""
        throw runtimeError(message.isEmpty ? "VPN 启动失败，请检查系统 VPN 权限。" : message)
      }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    throw runtimeError(running ? "等待 VPN 启动超时。" : "等待 VPN 断开超时。")
  }

  private func readStatus() async throws -> [String: Any] {
    _ = try await loadManager()
    var status: [String: Any]
    if isRunning {
      status = try await providerMessage(["method": "readStatus"]) as? [String: Any] ?? [:]
    } else {
      status = try EasyTierShared.readStatus()
      status["running"] = false
      status["connected"] = false
      status["core_version"] = Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String ?? ""
    }
    status["machine_id"] = try EasyTierShared.machineID()
    return status
  }

  private func providerMessage(_ message: [String: Any]) async throws -> Any {
    guard let session = manager?.connection as? NETunnelProviderSession, isRunning else {
      throw runtimeError("VPN 扩展未运行。")
    }
    let data = try JSONSerialization.data(withJSONObject: message)
    let response: Data = try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(data) { response in
          if let response { continuation.resume(returning: response) }
          else { continuation.resume(throwing: self.runtimeError("VPN 扩展没有返回响应。")) }
        }
      } catch { continuation.resume(throwing: error) }
    }
    let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any] ?? [:]
    if let error = decoded["error"] as? String { throw runtimeError(error) }
    return decoded["result"] ?? NSNull()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    startPolling()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    eventSink = nil
    return nil
  }

  private func startPolling() {
    guard eventSink != nil, timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.poll() }
    }
    Task { await poll() }
  }

  private func poll() async {
    guard !polling, eventSink != nil else { return }
    polling = true
    defer { polling = false }
    do {
      let status = try await readStatus()
      let sessionID = status["session_id"] as? String ?? ""
      if sessionID != lastSessionID { lastSessionID = sessionID; lastEventID = 0 }
      for event in status["events"] as? [[String: Any]] ?? [] {
        let id = event["id"] as? Int ?? 0
        if id > lastEventID { eventSink?(event); lastEventID = id }
      }
      if wasRunning && !isRunning {
        let lastStop = (status["events"] as? [[String: Any]] ?? []).last { $0["type"] as? String == "config_server_stopped" }
        if lastStop == nil {
          eventSink?(["type": "config_server_stopped", "payload": ["reason": "system_stop"]])
        }
      }
      wasRunning = isRunning
    } catch {
      eventSink?(["type": "error", "payload": ["error": redacted(error.localizedDescription)]])
    }
  }

  private func shareDiagnostics(_ args: [String: Any]) async throws {
    let path = try requiredString(args, "path")
    guard path.hasPrefix(NSHomeDirectory() + "/") else { throw runtimeError("诊断文件不在应用目录中。") }
    if isRunning { _ = try await providerMessage(["method": "flushDiagnostics"]) }
    let container = try EasyTierShared.container()
    var data = try Data(contentsOf: URL(fileURLWithPath: path))
    let logURLs = [container.appendingPathComponent("vpn.previous.log"), container.appendingPathComponent("vpn.log")]
      + ((try? FileManager.default.contentsOfDirectory(at: container.appendingPathComponent("core-logs"), includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    for url in logURLs where url.pathExtension == "log" {
      if let logs = try? Data(contentsOf: url) {
        data.append(Data("\n--- iOS VPN: \(url.lastPathComponent) ---\n".utf8))
        data.append(logs)
      }
    }
    try Data(redacted(String(decoding: data, as: UTF8.self)).utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    guard let viewController = registrar?.viewController else { throw runtimeError("无法打开分享面板。") }
    let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = viewController.view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 1, height: 1)
    viewController.present(sheet, animated: true)
  }

  private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.isEmpty else { throw runtimeError("缺少参数 \(key)。") }
    return value
  }

  private func redacted(_ text: String) -> String {
    guard let raw = try? EasyTierShared.readSecret("runtime_bootstrap"),
          let data = raw.data(using: .utf8),
          let bootstrap = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return text }
    return EasyTierShared.redacted(text, token: bootstrap["token"] ?? "", url: bootstrap["url"] ?? "")
  }

  private func jsonString(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }

  private func runtimeError(_ text: String) -> NSError {
    NSError(domain: "EasyTier", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
}
