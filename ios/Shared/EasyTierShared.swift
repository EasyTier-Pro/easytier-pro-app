import Foundation
import Security

enum EasyTierShared {
  static var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "EasyTierAppGroup") as! String }
  static var keychainGroup: String { Bundle.main.object(forInfoDictionaryKey: "EasyTierKeychainGroup") as! String }

  static func container() throws -> URL {
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      throw NSError(domain: "EasyTier", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开 VPN 共享目录，请检查 App Groups 签名配置。"])
    }
    return url
  }

  static func readSecret(_ key: String) throws -> String? {
    var query = secretQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else { throw keychainError(status) }
    return value
  }

  static func writeSecret(_ key: String, value: String) throws {
    let query = secretQuery(key)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw keychainError(status) }
  }

  static func deleteSecret(_ key: String) throws {
    let status = SecItemDelete(secretQuery(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
  }

  static func machineID() throws -> String {
    if let value = try readSecret("machine_id") { return value }
    let value = UUID().uuidString.lowercased()
    try writeSecret("machine_id", value: value)
    return value
  }

  static func readStatus() throws -> [String: Any] {
    let url = try container().appendingPathComponent("runtime-status.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
  }

  static func writeStatus(_ status: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
    try data.write(to: container().appendingPathComponent("runtime-status.json"), options: .atomic)
    EasyTierStatusNotification.post()
  }

  static func redacted(_ text: String, token: String, url: String) -> String {
    let encodedToken = URLComponents(string: url)?.percentEncodedPath.split(separator: "/").last.map(String.init) ?? ""
    return [url, token, encodedToken].filter { !$0.isEmpty }.reduce(text) {
      $0.replacingOccurrences(of: $1, with: "<redacted>")
    }
  }

  private static func secretQuery(_ key: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "net.easytier.pro",
     kSecAttrAccount as String: key,
     kSecAttrAccessGroup as String: keychainGroup]
  }

  private static func keychainError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)",
    ])
  }
}

// Darwin notifications are wakeups only. Readers obtain the authoritative
// snapshot from the App Group, including after returning from suspension.
final class EasyTierStatusNotification {
  private let handler: () -> Void
  private static var name: CFNotificationName {
    CFNotificationName((EasyTierShared.appGroup + ".runtime-status") as CFString)
  }

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
      guard let observer else { return }
      let notification = Unmanaged<EasyTierStatusNotification>.fromOpaque(observer).takeUnretainedValue()
      notification.handler()
    }, Self.name.rawValue, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       Unmanaged.passUnretained(self).toOpaque(), Self.name, nil)
  }

  static func post() {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
  }
}
