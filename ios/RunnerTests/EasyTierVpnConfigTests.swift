import NetworkExtension
import XCTest

final class EasyTierVpnConfigTests: XCTestCase {
  func testRoutesIncludePeerHostsAndMappedSubnets() throws {
    let config = try EasyTierVpnConfig(node: [
      "virtual_ipv4": ["address": ["addr": 168427522], "network_length": 32],
    ], routes: [
      ["ipv4_addr": ["address": ["addr": 168427523], "network_length": 32],
       "proxy_cidrs": ["192.168.0.0/24->172.20.0.7/24", "172.20.0.0/24"]],
    ])
    XCTAssertEqual(config.address, "10.10.0.2/32")
    XCTAssertEqual(config.routes, ["10.10.0.2/32", "10.10.0.3/32", "172.20.0.0/24"])
    XCTAssertEqual(config.settings().ipv4Settings?.addresses, ["10.10.0.2"])
    XCTAssertEqual(config.settings().ipv4Settings?.includedRoutes?.count, 3)
  }

  func testMagicDNSIsScopedToCoreZoneAndHasAHostRoute() throws {
    let config = try EasyTierVpnConfig(node: ["virtual_ipv4": "10.1.0.2/24"], routes: [],
                                      network: ["enable_magic_dns": true])
    XCTAssertEqual(config.routes, ["10.1.0.0/24", "100.100.100.101/32"])
    XCTAssertEqual(config.settings().dnsSettings?.servers, ["100.100.100.101"])
    XCTAssertEqual(config.settings().dnsSettings?.matchDomains, ["et.net"])
    let noDNS = try EasyTierVpnConfig(node: ["virtual_ipv4": "10.1.0.2/24"], routes: [])
    XCTAssertNil(noDNS.settings().dnsSettings)
  }

  func testManualRoutesOverrideAutomaticRoutes() throws {
    let config = try EasyTierVpnConfig(node: ["virtual_ipv4": "10.1.0.2/24"], routes: [],
                                      network: ["enable_manual_routes": true, "routes": ["0.0.0.0/0"]])
    XCTAssertEqual(config.routes, ["0.0.0.0/0"])
    XCTAssertEqual(config.settings().ipv4Settings?.includedRoutes?.first?.destinationSubnetMask, "0.0.0.0")
  }

  func testUnassignedAddressDoesNotClaimAnyRoute() {
    XCTAssertThrowsError(try EasyTierVpnConfig(node: [:], routes: [])) { error in
      XCTAssertEqual((error as NSError).code, 2)
    }
    XCTAssertNil(EasyTierVpnConfig.ipv4("10.0.0.1/33"))
    XCTAssertNil(EasyTierVpnConfig.ipv4("256.0.0.1/24"))
  }
}
