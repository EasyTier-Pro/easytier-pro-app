import Foundation
import NetworkExtension

struct EasyTierVpnConfig: Equatable {
  let address: String
  let routes: [String]
  let dns: [String]
  let dnsDomains: [String]
  let mtu = 1280

  init(node: [String: Any], routes: [[String: Any]], network: [String: Any] = [:]) throws {
    // show_node_info returns api.instance.NodeInfo, not collect's MyNodeInfo.
    guard let cidr = Self.cidr(node["ipv4_addr"]),
          Self.ipv4(cidr) != nil else {
      throw NSError(domain: "EasyTier", code: 2, userInfo: [NSLocalizedDescriptionKey: "等待控制台分配虚拟 IP。"])
    }
    address = cidr
    var cidrs: Set<String> = [cidr]
    for route in routes {
      if let address = Self.cidr(route["ipv4_addr"] ?? route["ipv4Addr"]) { cidrs.insert(address) }
      for value in (route["proxy_cidrs"] ?? route["proxyCidrs"]) as? [Any] ?? [] {
        if let cidr = Self.cidr(value) { cidrs.insert(cidr) }
      }
    }
    if network["enable_manual_routes"] as? Bool == true {
      cidrs = Set(network["routes"] as? [String] ?? [])
    }
    // These constants are the pinned core's MAGIC_DNS_FAKE_IP and default
    // DNS zone. The control console currently uses that default zone.
    let magicDNS = network["enable_magic_dns"] as? Bool == true
    if magicDNS { cidrs.insert("100.100.100.101/32") }
    self.routes = Set(cidrs.compactMap(Self.ipv4).map { "\($0.network)/\($0.prefix)" }).sorted()
    dns = magicDNS ? ["100.100.100.101"] : []
    dnsDomains = magicDNS ? ["et.net"] : []
  }

  func settings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let local = Self.ipv4(address)!
    let ipv4 = NEIPv4Settings(addresses: [local.address], subnetMasks: [local.mask])
    ipv4.includedRoutes = routes.compactMap(Self.ipv4).map {
      NEIPv4Route(destinationAddress: $0.network, subnetMask: $0.mask)
    }
    settings.ipv4Settings = ipv4
    settings.mtu = NSNumber(value: mtu)
    if !dns.isEmpty {
      let dnsSettings = NEDNSSettings(servers: dns)
      dnsSettings.matchDomains = dnsDomains
      dnsSettings.searchDomains = dnsDomains
      settings.dnsSettings = dnsSettings
    }
    return settings
  }

  static func cidr(_ value: Any?) -> String? {
    if let text = value as? String {
      let mapped = text.components(separatedBy: "->").last!.trimmingCharacters(in: .whitespaces)
      return mapped.contains("/") ? mapped : "\(mapped)/32"
    }
    guard let value = value as? [String: Any] else { return nil }
    if let mapped = value["mapped_cidr"] ?? value["mappedCidr"] { return cidr(mapped) }
    let raw = value["address"] ?? value["ipv4"]
    let ip: String?
    if let number = raw as? NSNumber { ip = ipText(number.uint32Value) }
    else if let text = raw as? String { ip = text }
    else if let nested = raw as? [String: Any], let number = nested["addr"] as? NSNumber { ip = ipText(number.uint32Value) }
    else { ip = nil }
    guard let ip else { return nil }
    let prefix = value["network_length"] ?? value["networkLength"] ?? 32
    return "\(ip)/\(prefix)"
  }

  static func ipv4(_ cidr: String) -> (address: String, prefix: Int, mask: String, network: String)? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
    let octets = parts[0].split(separator: ".")
    guard octets.count == 4 else { return nil }
    var address: UInt32 = 0
    for octet in octets {
      guard let value = UInt32(octet), value <= 255 else { return nil }
      address = (address << 8) | value
    }
    let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
    return (String(parts[0]), prefix, ipText(mask), ipText(address & mask))
  }

  private static func ipText(_ ip: UInt32) -> String {
    "\((ip >> 24) & 255).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
  }
}
