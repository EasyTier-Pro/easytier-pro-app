import Darwin
import Foundation
import NetworkExtension

protocol EasyTierPacketFlow: AnyObject {
  func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void)
  func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool
}

extension NEPacketTunnelFlow: EasyTierPacketFlow {}

// Public packetFlow packets cross a datagram socketpair into EasyTier's
// existing iOS TUN adapter. No private utun descriptor is accessed.
final class EasyTierPacketBridge {
  let coreFD: Int32
  private let flow: EasyTierPacketFlow
  private let onError: (Error) -> Void
  private let queue = DispatchQueue(label: "net.easytier.pro.packets")
  private let flowFD: Int32
  private var source: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var waitingForWrite = false
  private var pendingPackets: [Data] = []
  private var pendingIndex = 0
  private var failed = false
  private var stopped = false

  init(flow: EasyTierPacketFlow, onError: @escaping (Error) -> Void) throws {
    self.flow = flow
    self.onError = onError
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
      let writeSource = DispatchSource.makeWriteSource(fileDescriptor: self.flowFD, queue: self.queue)
      writeSource.setEventHandler { [weak self] in self?.writeSystemPackets() }
      self.writeSource = writeSource
      source.resume()
      self.readSystemPackets()
    }
  }

  // Call after the core has stopped using coreFD. The core borrows this fd.
  func stop() {
    queue.sync {
      guard !stopped else { return }
      stopped = true
      if let writeSource {
        // A suspended source must be resumed before releasing it.
        if !waitingForWrite { writeSource.resume() }
        writeSource.cancel()
      }
      writeSource = nil
      if let source { source.cancel() }
      else { close(flowFD) }
      source = nil
      pendingPackets = []
      close(coreFD)
    }
  }

  private func readSystemPackets() {
    guard !stopped, !failed else { return }
    flow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      self.queue.async {
        guard !self.stopped, !self.failed else { return }
        for (packet, family) in zip(packets, protocols) {
          // EasyTier's Darwin TUN codec expects a big-endian 4-byte family.
          var header = family.uint32Value.bigEndian
          var datagram = Data(bytes: &header, count: 4)
          datagram.append(packet)
          self.pendingPackets.append(datagram)
        }
        self.writeSystemPackets()
      }
    }
  }

  private func writeSystemPackets() {
    guard !stopped, !failed else { return }
    while pendingIndex < pendingPackets.count {
      let packet = pendingPackets[pendingIndex]
      let length = packet.withUnsafeBytes { send(flowFD, $0.baseAddress, $0.count, 0) }
      if length < 0 {
        let code = errno
        if code == EAGAIN || code == ENOBUFS {
          if !waitingForWrite {
            waitingForWrite = true
            writeSource?.resume()
          }
          return
        }
        failed = true
        if waitingForWrite {
          writeSource?.suspend()
          waitingForWrite = false
        }
        onError(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        return
      }
      pendingIndex += 1
    }
    if waitingForWrite {
      writeSource?.suspend()
      waitingForWrite = false
    }
    pendingPackets = []
    pendingIndex = 0
    // Keep only this batch; do not read more until the core has accepted it.
    readSystemPackets()
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
