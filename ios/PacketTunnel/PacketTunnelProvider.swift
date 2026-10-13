import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let queue = DispatchQueue(label: "net.easytier.pro.runtime")
  private var tunGeneration = 0
  private var tunReady = false
  private var tunAttachmentPending = false
  private var selection = UUID()
  private var announcedConfig: EasyTierVpnConfig?
  private var pathMonitor: NWPathMonitor?
  private var bridge: EasyTierPacketBridge?
  private var started = false
  private var generation = 0
  private var selectedName = ""
  private var selectedID = ""
  private var runtimeName = ""
  private var appliedConfig: EasyTierVpnConfig?
  private var appliedName = ""
  private var appliedID = ""
  private var settingsUpdating = false
  private var startCompletion: ((Error?) -> Void)?
  private var startTimeout: DispatchWorkItem?
  private var eventSequence = 0
  private var events: [[String: Any]] = []
  private var lastError = ""
  private var bootstrapToken = ""
  private var bootstrapURL = ""
  private var machineID = ""
  private let sessionID = UUID().uuidString

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    queue.async {
      self.startCompletion = completionHandler
      do {
        guard let raw = try EasyTierShared.readSecret("runtime_bootstrap"),
              let data = raw.data(using: .utf8),
              let bootstrap = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let url = bootstrap["url"], let hostname = bootstrap["hostname"] else {
          throw self.error("连接配置缺失，请打开 EasyTier Pro 重新连接。")
        }
        self.bootstrapToken = bootstrap["token"] ?? ""
        self.bootstrapURL = url
        self.machineID = try EasyTierShared.machineID()
        let logDirectory = try EasyTierShared.container().appendingPathComponent("core-logs")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try self.check(easytier_ios_configure_diagnostic_logging(logDirectory.path, 1))
        let context = Unmanaged.passUnretained(self).toOpaque()
        try self.check(start_config_server_client(url, hostname, self.machineID, true, { event, context in
          guard let event, let context else { return }
          // The FFI callback borrows this string and holds a delivery lock.
          // Copy it here; all core calls run later, outside the callback.
          let copied = String(cString: event)
          let provider = Unmanaged<PacketTunnelProvider>.fromOpaque(context).takeUnretainedValue()
          provider.queue.async { provider.handleConfigEvent(copied) }
        }, context))
        self.started = true
        self.generation += 1
        // A VPN start succeeds only once a real network and packet bridge are
        // ready. No network may survive the control-connection handoff.
        let timeout = DispatchWorkItem { [weak self] in
          guard let self, self.startCompletion != nil else { return }
          let error = self.error("未收到可用的网络配置，请检查控制台后重试。")
          self.recordError(error)
          self.stopCore(reason: "start_failed", error: error)
          self.cancelTunnelWithError(error)
        }
        self.startTimeout = timeout
        self.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        self.emit("config_server_started", ["hostname": hostname])
        self.startMonitoring()
      } catch {
        self.recordError(error)
        self.stopCore(reason: "start_failed", error: error)
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    queue.async {
      self.stopCore(reason: reason == .userInitiated ? "revoked" : "system_\(reason.rawValue)")
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    queue.async {
      do {
        let message = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] ?? [:]
        let result: Any
        switch message["method"] as? String {
        case "readStatus": result = self.status()
        case "collectNetworkInfos": result = try self.networkInfos()
        case "callJsonRpc":
          result = try self.rpc(message["serviceName"] as? String ?? "",
                                message["methodName"] as? String ?? "",
                                payload: message["payload"] as? [String: Any] ?? [:])
        case "flushDiagnostics":
          try self.check(easytier_ios_flush_diagnostic_logging())
          result = true
        default: throw self.error("不支持的 VPN 查询。")
        }
        completionHandler?(try JSONSerialization.data(withJSONObject: ["result": result]))
      } catch {
        completionHandler?(try? JSONSerialization.data(withJSONObject: ["error": self.redacted(error.localizedDescription)]))
      }
    }
  }

  private func startMonitoring() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self, self.started else { return }
      if self.startCompletion == nil { self.reasserting = path.status != .satisfied }
      self.log("Network path \(path.status)")
      self.refresh()
    }
    pathMonitor = monitor
    monitor.start(queue: queue)
  }

  private func handleConfigEvent(_ raw: String) {
    guard started, let data = raw.data(using: .utf8),
          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    emit("config_server", event)
    let name = event["instance_name"] as? String ?? ""
    let id = event["instance_id"] as? String ?? ""
    if event["event"] as? String == "network_instance_event" {
      // Removal clears the core registry before its delete callback arrives.
      // Such callbacks no longer identify a current instance to query.
      guard !name.isEmpty, name == selectedName, id == selectedID else { return }
    }
    if event["event"] as? String == "run_network_instance", event["success"] as? Bool == true, !name.isEmpty {
      do {
        try retain(name)
        // A successful run callback also follows replacements with the same
        // name and ID. The old runtime has stopped and the new one needs its
        // fd attached, even when its virtual address and routes are unchanged.
        // Keep the VPN's system reader; discard the old instance's packets.
        bridge?.detachCore()
        tunGeneration = 0
        tunReady = false
        tunAttachmentPending = false
        announcedConfig = nil
        selection = UUID()
        selectedName = name
        selectedID = id
        runtimeName = event["network_name"] as? String ?? name
      } catch { recordError(error) }
    } else if event["event"] as? String == "delete_network_instance", id == selectedID {
      bridge?.stop()
      bridge = nil
      selectedName = ""
      selectedID = ""
      runtimeName = ""
      emit("vpn_stopped", ["reason": "network_removed"])
      stopCore(reason: "network_removed")
      cancelTunnelWithError(nil)
      return
    }
    if event["event"] as? String == "network_instance_event", id == selectedID,
       let runtime = event["runtime"] as? [String: Any] {
      do {
        // Notifications can wait in this queue while a newer fd is installed.
        // Read current state before acknowledging or releasing its bridge.
        // The instance may disappear after a valid callback was queued. Its
        // delete callback follows shutdown and releases the owned bridge.
        guard let state = try readTunState(name) else { return }
        if state.generation == tunGeneration {
          if state.released && !tunAttachmentPending {
            bridge?.detachCore()
            tunGeneration = 0
            announcedConfig = nil
          }
          tunReady = state.ready
          if state.ready { tunAttachmentPending = false }
        }
        let nativeEvent = runtime["event"] as? [String: Any] ?? [:]
        if let message = nativeEvent["TunDeviceError"] as? String {
          let error = error(message)
          recordError(error)
          stopCore(reason: "start_failed", error: error)
          cancelTunnelWithError(error)
          return
        }
      } catch { recordError(error) }
    }
    refresh()
    finishIfReady()
  }

  private func refresh() {
    guard started else { return }
    defer { persistStatus() }
    guard !settingsUpdating else { return }
    do {
      if appliedConfig != nil && (appliedName != selectedName || appliedID != selectedID) {
        apply(nil)
        return
      }
      if selectedName.isEmpty {
        if appliedConfig != nil { apply(nil) }
        return
      }
      let payload: [String: Any] = ["instance": ["instance_selector": ["name": selectedName]]]
      let nodeResult = try rpc("api.instance.PeerManageRpcService", "show_node_info", payload: payload)
      let node = nodeResult["node_info"] as? [String: Any] ?? nodeResult
      let routeResult = try rpc("api.instance.PeerManageRpcService", "list_route", payload: payload)
      let networkResult = try rpc("api.config.ConfigRpcService", "GetConfig", payload: payload)
      let config = try EasyTierVpnConfig(node: node,
                                        routes: routeResult["routes"] as? [[String: Any]] ?? [],
                                        network: networkResult["config"] as? [String: Any] ?? [:])
      guard config != appliedConfig || bridge == nil || tunGeneration == 0 else { return }
      apply(config)
    } catch {
      // DHCP can remove an existing NIC as well as delay the initial address.
      // Clear its settings so recovery to the same IP still reattaches the fd.
      if (error as NSError).domain == "EasyTier" && (error as NSError).code == 2 {
        if appliedConfig != nil { apply(nil) }
      } else {
        recordError(error)
      }
    }
  }

  private func apply(_ config: EasyTierVpnConfig?) {
    settingsUpdating = true
    let generation = self.generation
    let selection = self.selection
    let name = selectedName
    let id = selectedID
    let addressChanged = bridge == nil || appliedConfig?.address != config?.address
    setTunnelNetworkSettings(config?.settings() ?? idleSettings()) { error in
      self.queue.async {
        self.settingsUpdating = false
        guard self.started, self.generation == generation else { return }
        // Track the settings actually installed by iOS, even if the selected
        // instance changed while the asynchronous settings call was pending.
        if error == nil {
          self.appliedConfig = config
          self.appliedName = config == nil ? "" : name
          self.appliedID = config == nil ? "" : id
        }
        guard self.selection == selection, self.selectedName == name, self.selectedID == id else {
          self.refresh()
          return
        }
        do {
          if let error { throw error }
          if config != nil {
            let needsAttachment = self.bridge == nil || addressChanged || self.tunGeneration == 0
            if self.bridge == nil {
              self.bridge = try EasyTierPacketBridge(flow: self.packetFlow, log: { [weak self] message in
                guard let self else { return }
                self.queue.async { self.log(message) }
              }) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                  guard self.started else { return }
                  self.recordError(error)
                  self.stopCore(reason: "packet_flow_failed", error: error)
                  self.cancelTunnelWithError(error)
                }
              }
              self.bridge?.start()
            }
            if needsAttachment, let bridge = self.bridge {
              // Core DHCP replaces its NIC when the virtual address changes.
              // Reuse the owned socketpair; route-only changes need no fd swap.
              self.tunReady = false
              self.tunAttachmentPending = true
              self.announcedConfig = nil
              try self.check(set_tun_fd(name, bridge.coreFD))
              bridge.attachCore()
              guard let state = try self.readTunState(name) else { return }
              self.tunGeneration = state.generation
              self.tunReady = state.ready
              if self.tunReady { self.tunAttachmentPending = false }
            }
            self.lastError = ""
          } else {
            self.emit("vpn_stopped", ["reason": name.isEmpty ? "network_removed" : "address_unassigned"])
          }
          self.persistStatus()
          self.refresh()
          self.finishIfReady()
        } catch {
          self.recordError(error)
          self.cancelTunnelWithError(error)
        }
      }
    }
  }

  private func readTunState(_ name: String) throws -> (generation: Int, ready: Bool, released: Bool)? {
    guard let value = easytier_ios_tun_state(name) else { throw coreError() }
    defer { easytier_ios_free_string(value) }
    let decoded = try JSONSerialization.jsonObject(with: Data(String(cString: value).utf8), options: [.fragmentsAllowed])
    if decoded is NSNull { return nil }
    guard let state = decoded as? [Any],
          state.count == 3, let generation = state[0] as? Int,
          let ready = state[1] as? Bool, let released = state[2] as? Bool else {
      throw error("无法读取核心接口状态。")
    }
    return (generation, ready, released)
  }

  private func finishIfReady() {
    guard started, !settingsUpdating, tunReady, bridge != nil,
          let config = appliedConfig, appliedName == selectedName, appliedID == selectedID else { return }
    if announcedConfig != config {
      announcedConfig = config
      emit("vpn_started", ["instance_name": selectedName, "instance_id": selectedID, "network_name": runtimeName,
                           "addresses": [config.address], "routes": config.routes, "dns": config.dns])
    }
    finishStart(nil)
  }

  private func stopCore(reason: String, error: Error? = nil) {
    guard started || startCompletion != nil else { return }
    started = false
    generation += 1
    tunReady = false
    tunGeneration = 0
    tunAttachmentPending = false
    announcedConfig = nil
    pathMonitor?.cancel()
    pathMonitor = nil
    let rc = stop_config_server_client()
    if rc != 0 {
      recordError(coreError())
    } else {
      // A successful stop waits for managed instances to release borrowed fds.
      // On failure keep them open until the extension process is terminated.
      bridge?.stop()
      bridge = nil
    }
    selectedName = ""
    selectedID = ""
    runtimeName = ""
    appliedConfig = nil
    appliedName = ""
    appliedID = ""
    reasserting = false
    emit("config_server_stopped", ["reason": reason])
    _ = easytier_ios_flush_diagnostic_logging()
    finishStart(error ?? self.error("VPN 启动已取消。"))
  }

  private func finishStart(_ error: Error?) {
    startTimeout?.cancel()
    startTimeout = nil
    let completion = startCompletion
    startCompletion = nil
    completion?(error)
  }

  private func idleSettings() -> NEPacketTunnelNetworkSettings {
    NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
  }

  private func retain(_ name: String) throws {
    try name.withCString { pointer in
      var pointers: [UnsafePointer<CChar>?] = [pointer]
      try pointers.withUnsafeMutableBufferPointer { try check(retain_network_instance($0.baseAddress, 1)) }
    }
  }

  private func networkInfos() throws -> [String: Any] {
    guard let value = easytier_ios_collect_network_infos(64) else { throw coreError() }
    defer { easytier_ios_free_string(value) }
    let data = Data(String(cString: value).utf8)
    let infos = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return ["instances": infos, "instance_name": selectedName, "instance_id": selectedID, "network_name": runtimeName,
            "vpn_ready": tunReady && !settingsUpdating && appliedConfig != nil && bridge != nil]
  }

  private func rpc(_ service: String, _ method: String, payload: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: payload)
    let json = String(decoding: data, as: UTF8.self)
    guard let value = easytier_ios_call_json_rpc(service, method, json) else { throw coreError() }
    defer { easytier_ios_free_string(value) }
    return try JSONSerialization.jsonObject(with: Data(String(cString: value).utf8)) as? [String: Any] ?? [:]
  }

  private func status() -> [String: Any] {
    ["session_id": sessionID, "running": started,
     "vpn_ready": tunReady && !settingsUpdating && appliedConfig != nil && bridge != nil, "connected": started && is_config_server_client_connected() != 0,
     "virtual_ipv4": appliedConfig?.address ?? "",
     "machine_id": machineID, "instance_name": selectedName, "instance_id": selectedID, "network_name": runtimeName,
     "core_version": Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String ?? "",
     "last_error": lastError, "events": events]
  }

  private func emit(_ type: String, _ payload: [String: Any]) {
    eventSequence += 1
    events.append(["id": eventSequence, "type": type, "payload": payload,
                   "timestamp": Date().timeIntervalSince1970])
    if events.count > 64 { events.removeFirst(events.count - 64) }
    log("\(type): \(payload)")
    persistStatus()
  }

  private func persistStatus() {
    do { try EasyTierShared.writeStatus(status()) }
    catch { log("Status write failed: \(error.localizedDescription)") }
  }

  private func log(_ text: String) {
    guard let container = try? EasyTierShared.container() else { return }
    let url = container.appendingPathComponent("vpn.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(redacted(text))\n"
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1024 * 1024 {
      let previous = container.appendingPathComponent("vpn.previous.log")
      try? FileManager.default.removeItem(at: previous)
      try? FileManager.default.moveItem(at: url, to: previous)
    }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      handle.closeFile()
    }
  }

  private func redacted(_ text: String) -> String {
    EasyTierShared.redacted(text, token: bootstrapToken, url: bootstrapURL)
  }

  private func recordError(_ error: Error) {
    let message = redacted(error.localizedDescription)
    guard message != lastError else { return }
    lastError = message
    emit("error", ["error": message])
  }

  private func coreError() -> NSError {
    guard let value = easytier_ios_last_error() else { return error("EasyTier 核心调用失败。") }
    defer { easytier_ios_free_string(value) }
    return error(redacted(String(cString: value)))
  }

  private func check(_ result: Int32) throws { if result != 0 { throw coreError() } }
  private func error(_ message: String) -> NSError {
    NSError(domain: "EasyTier", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
