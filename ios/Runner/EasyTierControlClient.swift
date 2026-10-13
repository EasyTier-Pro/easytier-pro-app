import Foundation

// This process owns only the foreground control connection. Mobile core does
// not install a TUN interface until set_tun_fd, which is exclusive to the VPN.
final class EasyTierControlClient {
  private let queue = DispatchQueue(label: "net.easytier.pro.control")
  var networksChanged: (() -> Void)?
  private var networkIDs = Set<String>()
  private var running = false
  private var sessionID = ""
  private var machineID = ""
  private var bootstrap: [String: String] = [:]

  func start(_ bootstrap: [String: String]) async throws -> [String: Any] {
    try await perform {
      if !self.running {
        self.bootstrap = bootstrap
        self.machineID = try EasyTierShared.machineID()
        let directory = try EasyTierShared.container().appendingPathComponent("control-logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.check(easytier_ios_configure_diagnostic_logging(directory.path, 1))
        let context = Unmanaged.passUnretained(self).toOpaque()
        try self.check(start_config_server_client(bootstrap["url"]!, bootstrap["hostname"]!,
                                                 self.machineID, true, { event, context in
          guard let event, let context else { return }
          let copied = String(cString: event)
          let control = Unmanaged<EasyTierControlClient>.fromOpaque(context).takeUnretainedValue()
          control.queue.async { control.handleConfigEvent(copied) }
        }, context))
        self.running = true
        self.sessionID = UUID().uuidString
      }
      return try self.snapshot()
    }
  }

  func stop() async throws {
    try await perform {
      guard self.running else { return }
      try self.check(stop_config_server_client())
      self.running = false
      self.networkIDs.removeAll()
      _ = easytier_ios_flush_diagnostic_logging()
    }
  }

  func status() async throws -> [String: Any] {
    try await perform { try self.snapshot() }
  }

  func flushDiagnostics() async {
    _ = try? await perform { easytier_ios_flush_diagnostic_logging() }
  }

  private func snapshot() throws -> [String: Any] {
    return ["session_id": sessionID, "running": running,
            "connected": running && is_config_server_client_connected() != 0,
            "has_networks": !networkIDs.isEmpty, "machine_id": machineID,
            "core_version": Bundle.main.object(forInfoDictionaryKey: "EasyTierCoreVersion") as? String ?? "",
            "events": []]
  }

  private func handleConfigEvent(_ raw: String) {
    guard running, let data = raw.data(using: .utf8),
          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = event["instance_id"] as? String else { return }
    switch event["event"] as? String {
    case "run_network_instance" where event["success"] as? Bool == true:
      networkIDs.insert(id)
    case "delete_network_instance": networkIDs.remove(id)
    default: return
    }
    networksChanged?()
  }

  private func perform<T>(_ action: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try action()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func check(_ result: Int32) throws { if result != 0 { throw coreError() } }

  private func coreError() -> NSError {
    var message = "EasyTier 核心调用失败。"
    if let value = easytier_ios_last_error() {
      message = String(cString: value)
      easytier_ios_free_string(value)
    }
    return NSError(domain: "EasyTier", code: 1, userInfo: [
      NSLocalizedDescriptionKey: EasyTierShared.redacted(message, token: bootstrap["token"] ?? "", url: bootstrap["url"] ?? ""),
    ])
  }
}
