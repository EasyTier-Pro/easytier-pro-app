import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let queue = DispatchQueue(label: "net.easytier.pro.runtime")
  private var timer: DispatchSourceTimer?
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
        let generation = self.generation
        // Enrollment precedes joining a network. Claim no traffic while the
        // control plane is waiting for the user to choose an authorized network.
        self.settingsUpdating = true
        self.setTunnelNetworkSettings(self.idleSettings()) { error in
          self.queue.async {
            self.settingsUpdating = false
            guard self.started, self.generation == generation else { return }
            if let error {
              self.recordError(error)
              self.finishStart(error)
              self.stopCore(reason: "start_failed")
              return
            }
            self.emit("config_server_started", ["hostname": hostname])
            self.startMonitoring()
            self.finishStart(nil)
          }
        }
      } catch {
        self.recordError(error)
        self.finishStart(error)
        self.stopCore(reason: "start_failed")
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
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .seconds(3))
    timer.setEventHandler { [weak self] in self?.refresh() }
    self.timer = timer
    timer.resume()
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.reasserting = path.status != .satisfied
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
    if event["event"] as? String == "run_network_instance", event["success"] as? Bool == true, !name.isEmpty {
      do {
        try retain(name)
        // A successful run callback also follows replacements with the same
        // name and ID. The old runtime has stopped and the new one needs its
        // own fd, even when its virtual address and routes are unchanged.
        bridge?.stop()
        bridge = nil
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
    }
    refresh()
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
      guard config != appliedConfig || bridge == nil else { return }
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
        guard self.selectedName == name, self.selectedID == id else {
          self.refresh()
          return
        }
        do {
          if let error { throw error }
          if let config {
            let needsAttachment = self.bridge == nil || addressChanged
            if self.bridge == nil {
              self.bridge = try EasyTierPacketBridge(flow: self.packetFlow)
              self.bridge?.start()
            }
            if needsAttachment, let bridge = self.bridge {
              // Core DHCP replaces its NIC when the virtual address changes.
              // Reuse the owned socketpair; route-only changes need no fd swap.
              try self.check(set_tun_fd(name, bridge.coreFD))
            }
            self.lastError = ""
            self.emit("vpn_started", ["instance_name": name, "network_name": self.runtimeName,
                                       "addresses": [config.address], "routes": config.routes,
                                       "dns": config.dns])
          } else {
            self.emit("vpn_stopped", ["reason": name.isEmpty ? "network_removed" : "address_unassigned"])
          }
          self.persistStatus()
          self.refresh()
        } catch {
          self.recordError(error)
          self.cancelTunnelWithError(error)
        }
      }
    }
  }

  private func stopCore(reason: String) {
    finishStart(error("VPN 启动已取消。"))
    started = false
    generation += 1
    timer?.cancel()
    timer = nil
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
  }

  private func finishStart(_ error: Error?) {
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
    return ["instances": infos, "instance_name": selectedName, "network_name": runtimeName]
  }

  private func rpc(_ service: String, _ method: String, payload: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: payload)
    let json = String(decoding: data, as: UTF8.self)
    guard let value = easytier_ios_call_json_rpc(service, method, json) else { throw coreError() }
    defer { easytier_ios_free_string(value) }
    return try JSONSerialization.jsonObject(with: Data(String(cString: value).utf8)) as? [String: Any] ?? [:]
  }

  private func status() -> [String: Any] {
    ["session_id": sessionID, "running": started, "connected": started && is_config_server_client_connected() != 0,
     "machine_id": machineID, "instance_name": selectedName, "network_name": runtimeName,
     "core_version": Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String ?? "",
     "last_error": lastError, "events": events]
  }

  private func emit(_ type: String, _ payload: [String: Any]) {
    eventSequence += 1
    events.append(["id": eventSequence, "type": type, "payload": payload])
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
