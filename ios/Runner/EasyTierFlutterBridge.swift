import Flutter
import Foundation
import NetworkExtension
import UIKit

@MainActor
final class EasyTierFlutterBridge: NSObject, @preconcurrency FlutterPlugin, @preconcurrency FlutterStreamHandler {
  private var registrar: FlutterPluginRegistrar?
  private var eventSink: FlutterEventSink?
  private var statusNotification: EasyTierStatusNotification?
  private var reconcilePending = false
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var networkConnections = 0
  private var activatingVPN = false
  private var stateWaiters: [UUID: (() throws -> Bool, CheckedContinuation<Void, Error>, DispatchWorkItem)] = [:]
  private var statusObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?
  private var manager: NETunnelProviderManager?
  private var managerLoaded = false
  private var reconciling = false
  private var lastEventID = 0
  private var lastSessionID = ""
  private var wasRunning = false
  private var operation: Task<Void, Never>?
  private let control = EasyTierControlClient()
  private var shouldRun = false
  private var vpnNeedsRetry = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = EasyTierFlutterBridge()
    bridge.registrar = registrar
    let channel = FlutterMethodChannel(name: "net.easytier.pro/core_runtime", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(bridge, channel: channel)
    FlutterEventChannel(name: "net.easytier.pro/core_runtime_events", binaryMessenger: registrar.messenger())
      .setStreamHandler(bridge)
  }

  override init() {
    super.init()
    // These wakeups also complete waits directly. Enqueueing the completion
    // behind activateVPN would make that operation wait on itself.
    statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.runtimeChanged() }
    }
    statusNotification = EasyTierStatusNotification { [weak self] in
      Task { @MainActor in self?.runtimeChanged() }
    }
    control.networksChanged = { [weak self] in
      Task { @MainActor in self?.runtimeChanged() }
    }
    foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.runtimeChanged() }
    }
    backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.stopIdleControlInBackground() }
    }
  }

  deinit {
    for observer in [statusObserver, foregroundObserver, backgroundObserver].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if ["ensureRunning", "stopRuntime", "readStatus", "collectNetworkInfos", "callJsonRpc"].contains(call.method) {
      enqueue { await self.handleAsync(call.method, args: args, result: result) }
    } else {
      Task { @MainActor in await handleAsync(call.method, args: args, result: result) }
    }
  }

  private func enqueue(_ action: @escaping @MainActor () async -> Void) {
    let previous = operation
    operation = Task { @MainActor in
      await previous?.value
      await action()
    }
  }

  private var isForeground: Bool { UIApplication.shared.applicationState != .background }

  private func handleAsync(_ method: String, args: [String: Any], result: @escaping FlutterResult) async {
    do {
      switch method {
      case "beginNetworkConnection":
        try beginBackgroundTask()
        networkConnections += 1
        vpnNeedsRetry = false
        runtimeChanged()
        result(nil)
      case "endNetworkConnection":
        networkConnections = max(0, networkConnections - 1)
        if networkConnections == 0 && !activatingVPN { endBackgroundTask() }
        stopIdleControlInBackground()
        result(nil)
      case "waitForNetworkConnection":
        let network = try requiredString(args, "networkName")
        let after = args["after"] as? [String: Any]
        let timeout = args["timeoutSeconds"] as? Double ?? 40
        var connection: [String: Any]?
        try await waitForState("等待网络连接超时。", timeout: timeout) {
          guard self.isRunning else {
            if self.vpnNeedsRetry { throw self.runtimeError("VPN 启动失败，请重试连接。") }
            return false
          }
          let status = try EasyTierShared.readStatus()
          connection = Self.networkConnectionStatus(status, network: network, after: after)
          return connection != nil
        }
        result(connection)
      case "getMachineId": result(try EasyTierShared.machineID())
      case "getHostname": result("iPhone-\(try EasyTierShared.machineID().prefix(8))")
      case "readStatus":
        var status = try await readStatus()
        if let url = args["url"] as? String, let token = args["token"] as? String {
          let raw = try EasyTierShared.readSecret("runtime_bootstrap") ?? "{}"
          let saved = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] ?? [:]
          if saved["url"] != url || saved["token"] != token { status["running"] = false }
          else if isRunning { shouldRun = true; wasRunning = true }
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

  private func loadManager(refresh: Bool = false) async throws -> NETunnelProviderManager? {
    if managerLoaded && !refresh { return manager }
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
    managerLoaded = true
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
    let url = try requiredString(args, "url")
    let token = try requiredString(args, "token")
    let hostname = try requiredString(args, "hostname")
    let bootstrap = try jsonString(["url": url, "token": token, "hostname": hostname])
    let oldBootstrap = try EasyTierShared.readSecret("runtime_bootstrap")
    _ = try await loadManager(refresh: true)
    shouldRun = true
    vpnNeedsRetry = false
    if oldBootstrap == bootstrap, args["forceReinstall"] as? Bool != true {
      if isRunning { wasRunning = true; return try await readStatus() }
      let status = try await control.status()
      if status["running"] as? Bool == true { return status }
    }
    try await disconnectVPN()
    try await control.stop()
    try EasyTierShared.writeSecret("runtime_bootstrap", value: bootstrap)
    guard isForeground else { return try await readStatus() }
    let status = try await control.start(["url": url, "token": token, "hostname": hostname])
    controlStarted(hostname)
    return status
  }

  private func activateVPN() async throws {
    #if targetEnvironment(simulator)
    throw runtimeError("iOS 模拟器不支持系统 VPN，请使用真机连接网络。")
    #else
    try beginBackgroundTask()
    activatingVPN = true
    defer {
      activatingVPN = false
      if networkConnections == 0 { endBackgroundTask() }
    }
    let bootstrap = try savedBootstrap()
    let manager = try await loadManager(refresh: true) ?? NETunnelProviderManager()
    self.manager = manager
    if isRunning || !shouldRun { return }
    let config = NETunnelProviderProtocol()
    config.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
    config.serverAddress = URL(string: bootstrap["url"]!)?.host ?? "EasyTier Pro"
    // Secrets live in the shared Keychain, never in providerConfiguration.
    manager.protocolConfiguration = config
    manager.localizedDescription = "EasyTier Pro"
    manager.isEnabled = true
    manager.isOnDemandEnabled = false
    // Keep the foreground connection until VPN authorization succeeds.
    try await save(manager)
    try await control.stop()
    try manager.connection.startVPNTunnel()
    try await waitFor(manager, running: true)
    wasRunning = true
    #endif
  }

  private func stopRuntime() async throws {
    shouldRun = false
    vpnNeedsRetry = false
    failStateWaiters(runtimeError("连接已停止。"))
    networkConnections = 0
    endBackgroundTask()
    try await disconnectVPN()
    try await control.stop()
    try EasyTierShared.deleteSecret("runtime_bootstrap")
  }

  private func disconnectVPN() async throws {
    guard let manager = try await loadManager(refresh: true) else { return }
    if manager.connection.status != .disconnected && manager.connection.status != .invalid {
      manager.connection.stopVPNTunnel()
      try await waitFor(manager, running: false)
    }
    wasRunning = false
  }

  private func savedBootstrap() throws -> [String: String] {
    let raw = try EasyTierShared.readSecret("runtime_bootstrap") ?? "{}"
    let bootstrap = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] ?? [:]
    for key in ["url", "hostname"] { _ = try requiredString(bootstrap, key) }
    return bootstrap
  }

  private func resumeControl() async throws -> [String: Any] {
    let before = try await control.status()
    if before["running"] as? Bool == true { return before }
    let bootstrap = try savedBootstrap()
    let status = try await control.start(bootstrap)
    controlStarted(bootstrap["hostname"]!)
    return status
  }

  private func controlStarted(_ hostname: String) {
    eventSink?(["type": "config_server_started", "payload": ["hostname": hostname, "mode": "control"]])
  }

  private func report(_ error: Error) {
    let nsError = error as NSError
    let permissionDenied = nsError.domain == NEVPNErrorDomain && nsError.code == NEVPNError.configurationReadWriteFailed.rawValue
    eventSink?(["type": permissionDenied ? "vpn_permission_denied" : "error",
                "payload": ["error": redacted(error.localizedDescription)]])
  }

  private func waitFor(_ manager: NETunnelProviderManager, running: Bool) async throws {
    var sawConnecting = false
    try await waitForState(running ? "等待 VPN 启动超时。" : "等待 VPN 断开超时。") {
      let status = manager.connection.status
      if status == .connecting { sawConnecting = true }
      if running && (status == .connected || status == .reasserting) { return true }
      if !running && (status == .disconnected || status == .invalid) { return true }
      if running && sawConnecting && status == .disconnected {
        let state = try EasyTierShared.readStatus()
        let message = state["last_error"] as? String ?? ""
        throw self.runtimeError(message.isEmpty ? "VPN 启动失败，请检查系统 VPN 权限。" : message)
      }
      return false
    }
  }

  static func networkConnectionStatus(_ status: [String: Any], network: String,
                                      after: [String: Any]? = nil) -> [String: Any]? {
    guard status["vpn_ready"] as? Bool == true, status["network_name"] as? String == network,
          let instanceID = status["instance_id"] as? String, !instanceID.isEmpty else { return nil }
    let sessionID = status["session_id"] as? String ?? ""
    let eventID = (status["events"] as? [[String: Any]])?.last?["id"] as? Int ?? 0
    if let after, after["session_id"] as? String == sessionID,
       eventID <= (after["event_id"] as? Int ?? 0) { return nil }
    return ["instance_id": instanceID, "virtual_ipv4": status["virtual_ipv4"] ?? "",
            "session_id": sessionID, "event_id": eventID]
  }

  private func waitForState(_ timeoutMessage: String, timeout timeoutInterval: TimeInterval = 40,
                            check: @escaping () throws -> Bool) async throws {
    let id = UUID()
    try await withCheckedThrowingContinuation { continuation in
      let timeout = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.completeStateWaiter(id, error: self.runtimeError(timeoutMessage))
      }
      stateWaiters[id] = (check, continuation, timeout)
      DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
      checkStateWaiters()
    }
  }

  private func checkStateWaiters() {
    for (id, waiter) in stateWaiters {
      do { if try waiter.0() { completeStateWaiter(id) } }
      catch { completeStateWaiter(id, error: error) }
    }
  }

  private func completeStateWaiter(_ id: UUID, error: Error? = nil) {
    guard let waiter = stateWaiters.removeValue(forKey: id) else { return }
    waiter.2.cancel()
    if let error { waiter.1.resume(throwing: error) }
    else { waiter.1.resume() }
  }

  private func failStateWaiters(_ error: Error) {
    for id in stateWaiters.keys { completeStateWaiter(id, error: error) }
  }

  private func beginBackgroundTask() throws {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "EasyTier network connection") { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.endBackgroundTask()
        self.failStateWaiters(self.runtimeError("网络连接的后台执行时间已结束，请返回应用重试。"))
        self.stopIdleControlInBackground()
      }
    }
    guard backgroundTask != .invalid else { throw runtimeError("无法申请网络连接的后台执行时间。") }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    let task = backgroundTask
    backgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }

  private func stopIdleControlInBackground() {
    enqueue {
      guard !self.isForeground, self.backgroundTask == .invalid else { return }
      do { try await self.control.stop() }
      catch { self.report(error) }
    }
  }
  private func readStatus() async throws -> [String: Any] {
    _ = try await loadManager()
    if let manager, manager.connection.status != .disconnected && manager.connection.status != .invalid {
      // iOS and Shortcuts can start the VPN independently of this bridge.
      // Once it owns the tunnel, retire this process's control connection.
      try await control.stop()
    }
    var status: [String: Any]
    if isRunning {
      // The extension commits this snapshot before every status notification.
      // It remains readable while iOS tears down the provider message channel.
      status = try EasyTierShared.readStatus()
    } else {
      status = try await control.status()
      if status["running"] as? Bool != true {
        status = try EasyTierShared.readStatus()
        status["running"] = false
        status["connected"] = false
        status["core_version"] = Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String ?? ""
      }
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
    runtimeChanged()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func runtimeChanged() {
    checkStateWaiters()
    reconcilePending = true
    guard !reconciling else { return }
    reconciling = true
    enqueue {
      while self.reconcilePending {
        self.reconcilePending = false
        await self.reconcileRuntime()
      }
      self.reconciling = false
    }
  }

  private func reconcileRuntime() async {
    guard isForeground || backgroundTask != .invalid else { return }
    do {
      let status = try await readStatus()
      let sessionID = status["session_id"] as? String ?? ""
      if sessionID != lastSessionID { lastSessionID = sessionID; lastEventID = 0 }
      for event in status["events"] as? [[String: Any]] ?? [] {
        let id = event["id"] as? Int ?? 0
        guard id > lastEventID else { continue }
        lastEventID = id
        let reason = (event["payload"] as? [String: Any])?["reason"] as? String ?? ""
        if event["type"] as? String == "config_server_stopped" && ["network_removed", "start_failed"].contains(reason) {
          continue // Native ownership changes do not trigger Dart reconnection.
        }
        eventSink?(event)
      }
      if wasRunning && !isRunning {
        let lastStop = (status["events"] as? [[String: Any]] ?? []).last { $0["type"] as? String == "config_server_stopped" }
        let reason = (lastStop?["payload"] as? [String: Any])?["reason"] as? String ?? "system_stop"
        if !["network_removed", "start_failed"].contains(reason) {
          shouldRun = false
        }
        if lastStop == nil {
          eventSink?(["type": "config_server_stopped", "payload": ["reason": "system_stop"]])
        }
      }
      wasRunning = isRunning
      guard shouldRun, !isRunning,
            manager == nil || manager?.connection.status == .disconnected || manager?.connection.status == .invalid else { return }
      let controlStatus = try await resumeControl()
      if controlStatus["has_networks"] as? Bool != true {
        if vpnNeedsRetry {
          vpnNeedsRetry = false
          controlStarted(try savedBootstrap()["hostname"]!)
        }
        return
      }
      guard !vpnNeedsRetry else { return }
      do {
        try await activateVPN()
      } catch {
        vpnNeedsRetry = true
        checkStateWaiters()
        // Never overlap the two cores, including after a failed VPN start.
        try await disconnectVPN()
        if shouldRun && isForeground { _ = try await resumeControl() }
        report(error)
      }
    } catch {
      report(error)
    }
  }

  private func shareDiagnostics(_ args: [String: Any]) async throws {
    let path = try requiredString(args, "path")
    // /var and /private/var refer to the same iOS application container.
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(home.path + "/") else { throw runtimeError("诊断文件不在应用目录中。") }
    if isRunning { _ = try await providerMessage(["method": "flushDiagnostics"]) }
    await control.flushDiagnostics()
    let container = try EasyTierShared.container()
    var data = try Data(contentsOf: url)
    let logURLs = [container.appendingPathComponent("vpn.previous.log"), container.appendingPathComponent("vpn.log")]
      + ["core-logs", "control-logs"].flatMap { directory in
        ((try? FileManager.default.contentsOfDirectory(at: container.appendingPathComponent(directory), includingPropertiesForKeys: nil)) ?? [])
          .sorted { $0.lastPathComponent < $1.lastPathComponent }
      }
    for url in logURLs where url.pathExtension == "log" {
      if let logs = try? Data(contentsOf: url) {
        data.append(Data("\n--- iOS VPN: \(url.lastPathComponent) ---\n".utf8))
        data.append(logs)
      }
    }
    try Data(redacted(String(decoding: data, as: UTF8.self)).utf8).write(to: url, options: .atomic)
    guard let viewController = registrar?.viewController else { throw runtimeError("无法打开分享面板。") }
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
