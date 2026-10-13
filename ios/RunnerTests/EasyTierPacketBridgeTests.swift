import Darwin
import Foundation
import XCTest

final class EasyTierPacketBridgeTests: XCTestCase {
  func testSystemPacketBatchResumesAfterCoreDrainsTheSocket() async throws {
    let packets = (0..<64).map { Data(repeating: UInt8($0), count: 1280) }
    let flow = PacketFlowStub(packets: packets)
    let bridge = try EasyTierPacketBridge(flow: flow) { XCTFail("Packet bridge failed: \($0)") }
    bridge.start()
    await fulfillment(of: [flow.readStarted], timeout: 1)
    XCTAssertEqual(flow.readCount, 1)

    let received = expectation(description: "Every packet in the batch reaches the core")
    let cancelled = expectation(description: "Core reader released its fd")
    let queue = DispatchQueue(label: "packet-bridge-test.core")
    let source = DispatchSource.makeReadSource(fileDescriptor: bridge.coreFD, queue: queue)
    var count = 0
    source.setEventHandler {
      var bytes = [UInt8](repeating: 0, count: 2048)
      while true {
        let length = recv(bridge.coreFD, &bytes, bytes.count, 0)
        if length < 0 { break }
        XCTAssertEqual(length, 1284)
        XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, UInt8(AF_INET)])
        if count < packets.count {
          XCTAssertEqual(Data(bytes[4..<length]), packets[count])
        }
        count += 1
        if count == packets.count { received.fulfill() }
      }
    }
    source.setCancelHandler { cancelled.fulfill() }
    source.resume()
    await fulfillment(of: [received, flow.readAgain], timeout: 3)
    source.cancel()
    await fulfillment(of: [cancelled], timeout: 1)
    bridge.stop()
    XCTAssertEqual(count, packets.count)
    XCTAssertEqual(flow.readCount, 2)
  }

  func testCorePacketsKeepTheirBoundariesAndFamilies() async throws {
    let received = expectation(description: "Both packets reach the system flow")
    let flow = PacketFlowStub(onWrite: { packets in
      if packets.count == 2 { received.fulfill() }
    })
    let bridge = try EasyTierPacketBridge(flow: flow) { XCTFail("Packet bridge failed: \($0)") }
    bridge.start()
    await fulfillment(of: [flow.readStarted], timeout: 1)
    for (family, packet) in [(AF_INET, Data([0x45, 1, 2])), (AF_INET6, Data([0x60, 3, 4]))] {
      var header = UInt32(family).bigEndian
      var datagram = Data(bytes: &header, count: 4)
      datagram.append(packet)
      let length = datagram.withUnsafeBytes { send(bridge.coreFD, $0.baseAddress, $0.count, 0) }
      XCTAssertEqual(length, datagram.count)
    }
    await fulfillment(of: [received], timeout: 1)
    bridge.stop()
    XCTAssertEqual(flow.writtenPackets, [Data([0x45, 1, 2]), Data([0x60, 3, 4])])
    XCTAssertEqual(flow.writtenFamilies, [NSNumber(value: AF_INET), NSNumber(value: AF_INET6)])
  }

  func testStopWhileSystemPacketsAreWaitingForTheCore() async throws {
    for _ in 0..<32 {
      let flow = PacketFlowStub(packets: (0..<64).map { Data(repeating: UInt8($0), count: 1280) })
      let bridge = try EasyTierPacketBridge(flow: flow) { XCTFail("Packet bridge failed: \($0)") }
      bridge.start()
      await fulfillment(of: [flow.readStarted], timeout: 1)
      bridge.stop()
      let result = fcntl(bridge.coreFD, F_GETFD)
      let code = errno
      XCTAssertEqual(result, -1)
      XCTAssertEqual(code, EBADF)
      bridge.stop()
    }
  }

  func testCoreReplacementKeepsTheOutstandingSystemRead() async throws {
    let flow = PacketFlowStub()
    let bridge = try EasyTierPacketBridge(flow: flow) { XCTFail("Packet bridge failed: \($0)") }
    bridge.start()
    await fulfillment(of: [flow.readStarted], timeout: 1)
    for _ in 0..<32 {
      bridge.detachCore()
      bridge.attachCore()
    }
    XCTAssertEqual(flow.readCount, 1)

    let packet = Data([0x45, 1, 2, 3])
    flow.deliverPackets([packet])
    await fulfillment(of: [flow.readAgain], timeout: 1)
    var bytes = [UInt8](repeating: 0, count: 2048)
    let length = recv(bridge.coreFD, &bytes, bytes.count, 0)
    XCTAssertEqual(length, packet.count + 4)
    XCTAssertEqual(Data(bytes[4..<max(4, length)]), packet)
    bridge.stop()
  }

  func testCoreReplacementDiscardsTheOldBatchUnderBackpressure() async throws {
    let flow = PacketFlowStub(packets: (0..<64).map { Data(repeating: UInt8($0), count: 1280) })
    let bridge = try EasyTierPacketBridge(flow: flow) { XCTFail("Packet bridge failed: \($0)") }
    bridge.start()
    await fulfillment(of: [flow.readStarted], timeout: 1)
    bridge.detachCore()
    bridge.attachCore()
    await fulfillment(of: [flow.readAgain], timeout: 1)

    var bytes = [UInt8](repeating: 0, count: 2048)
    XCTAssertEqual(recv(bridge.coreFD, &bytes, bytes.count, 0), -1)
    XCTAssertEqual(errno, EAGAIN)
    let packet = Data([0x45, 9, 8, 7])
    flow.deliverPackets([packet])
    await fulfillment(of: [flow.readThird], timeout: 1)
    let length = recv(bridge.coreFD, &bytes, bytes.count, 0)
    XCTAssertEqual(length, packet.count + 4)
    XCTAssertEqual(Data(bytes[4..<max(4, length)]), packet)
    bridge.stop()
  }
}

private final class PacketFlowStub: EasyTierPacketFlow {
  let readStarted = XCTestExpectation(description: "System flow read requested")
  let readAgain = XCTestExpectation(description: "Next system batch requested")
  let readThird = XCTestExpectation(description: "Third system batch requested")
  private let lock = NSLock()
  private var firstBatch: [Data]
  private var reads = 0
  private var pendingRead: (([Data], [NSNumber]) -> Void)?
  private var packets: [Data] = []
  private var families: [NSNumber] = []
  private let onWrite: ([Data]) -> Void

  init(packets: [Data] = [], onWrite: @escaping ([Data]) -> Void = { _ in }) {
    firstBatch = packets
    self.onWrite = onWrite
    readStarted.assertForOverFulfill = false
  }

  var readCount: Int { lock.withLock { reads } }
  var writtenPackets: [Data] { lock.withLock { packets } }
  var writtenFamilies: [NSNumber] { lock.withLock { families } }

  func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void) {
    let (batch, readCount) = lock.withLock {
      XCTAssertNil(pendingRead, "Only one system read may be outstanding")
      reads += 1
      let batch = firstBatch
      firstBatch = []
      if batch.isEmpty { pendingRead = completionHandler }
      return (batch, reads)
    }
    if !batch.isEmpty {
      completionHandler(batch, Array(repeating: NSNumber(value: AF_INET), count: batch.count))
    }
    readStarted.fulfill()
    if readCount == 2 { readAgain.fulfill() }
    if readCount == 3 { readThird.fulfill() }
  }

  func deliverPackets(_ packets: [Data]) {
    let completion = lock.withLock {
      let completion = pendingRead
      pendingRead = nil
      return completion
    }
    XCTAssertNotNil(completion)
    completion?(packets, Array(repeating: NSNumber(value: AF_INET), count: packets.count))
  }

  func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
    let received = lock.withLock {
      self.packets.append(contentsOf: packets)
      families.append(contentsOf: protocols)
      return self.packets
    }
    onWrite(received)
    return true
  }
}
