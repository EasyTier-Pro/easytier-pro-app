import Darwin
import Foundation
import NetworkExtension

// Public packetFlow packets cross a datagram socketpair into EasyTier's
// existing iOS TUN adapter. No private utun descriptor is accessed.
final class EasyTierPacketBridge {
  let coreFD: Int32
  private let flow: NEPacketTunnelFlow
  private let queue = DispatchQueue(label: "net.easytier.pro.packets")
  private let flowFD: Int32
  private var source: DispatchSourceRead?
  private var stopped = false

  init(flow: NEPacketTunnelFlow) throws {
    self.flow = flow
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    flowFD = fds[0]
    coreFD = fds[1]
    for fd in fds {
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
  }

  func start() {
    queue.async {
      let source = DispatchSource.makeReadSource(fileDescriptor: self.flowFD, queue: self.queue)
      source.setEventHandler { [weak self] in self?.readCorePackets() }
      let fd = self.flowFD
      source.setCancelHandler { close(fd) }
      self.source = source
      source.resume()
      self.readSystemPackets()
    }
  }

  // Call after the core has stopped using coreFD. The core borrows this fd.
  func stop() {
    queue.sync {
      guard !stopped else { return }
      stopped = true
      if let source { source.cancel() }
      else { close(flowFD) }
      source = nil
      close(coreFD)
    }
  }

  private func readSystemPackets() {
    guard !stopped else { return }
    flow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      self.queue.async {
        guard !self.stopped else { return }
        for (packet, family) in zip(packets, protocols) {
          // EasyTier's Darwin TUN codec expects a big-endian 4-byte family.
          var header = family.uint32Value.bigEndian
          var datagram = Data(bytes: &header, count: 4)
          datagram.append(packet)
          datagram.withUnsafeBytes { bytes in
            _ = send(self.flowFD, bytes.baseAddress, bytes.count, 0)
          }
        }
        self.readSystemPackets()
      }
    }
  }

  private func readCorePackets() {
    guard !stopped else { return }
    var buffer = [UInt8](repeating: 0, count: 65539)
    var packets: [Data] = []
    var protocols: [NSNumber] = []
    for _ in 0..<64 {
      let length = recv(flowFD, &buffer, buffer.count, 0)
      if length < 0 { break }
      guard length > 4 else { continue }
      let family = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { continue }
      packets.append(Data(buffer[4..<length]))
      protocols.append(NSNumber(value: family))
    }
    if !packets.isEmpty { _ = flow.writePackets(packets, withProtocols: protocols) }
  }
}
