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
  private let log: (String) -> Void
  private let queue = DispatchQueue(label: "net.easytier.pro.packets")
  private let flowFD: Int32
  private var source: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var waitingForWrite = false
  private var pendingPackets: [Data] = []
  private var pendingIndex = 0
  private var coreAttached = true
  private var readPending = false
  private var failed = false
  private var stopped = false
  private var readLogged = false
  private var sentLogged = false
  private var receivedLogged = false
  private var pressureLogged = false

  init(flow: EasyTierPacketFlow, log: @escaping (String) -> Void = { _ in },
       onError: @escaping (Error) -> Void) throws {
    self.flow = flow
    self.log = log
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
      let cancelled = DispatchGroup()
      cancelled.enter()
      cancelled.enter()
      source.setCancelHandler { cancelled.leave() }
      self.source = source
      let writeSource = DispatchSource.makeWriteSource(fileDescriptor: self.flowFD, queue: self.queue)
      writeSource.setEventHandler { [weak self] in self?.writeSystemPackets() }
      writeSource.setCancelHandler { cancelled.leave() }
      // Both sources must release their kernel references before fd reuse.
      cancelled.notify(queue: self.queue) { close(fd) }
      self.writeSource = writeSource
      source.resume()
      self.log("Packet bridge started core_fd=\(self.coreFD) flow_fd=\(self.flowFD)")
      self.readSystemPackets()
    }
  }

  // Call after the old core has stopped borrowing coreFD. Keep the VPN's
  // outstanding system read; NEPacketTunnelFlow provides no cancellation.
  func detachCore() {
    queue.sync {
      guard !stopped else { return }
      coreAttached = false
      if waitingForWrite {
        writeSource?.suspend()
        waitingForWrite = false
      }
      pendingPackets = []
      pendingIndex = 0
      var buffer = [UInt8](repeating: 0, count: 65539)
      // Neither direction may carry an old instance's queued packets across
      // reattachment. The core is stopped, so both ends are ours to drain.
      for fd in [coreFD, flowFD] {
        while recv(fd, &buffer, buffer.count, 0) >= 0 {}
      }
    }
  }

  func attachCore() {
    queue.sync {
      guard !stopped, !failed else { return }
      coreAttached = true
      readCorePackets()
      readSystemPackets()
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
    guard !stopped, !failed, coreAttached, !readPending, pendingPackets.isEmpty else { return }
    readPending = true
    flow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      self.queue.async {
        self.readPending = false
        guard !self.stopped, !self.failed else { return }
        guard self.coreAttached else { return }
        if !self.readLogged {
          self.readLogged = true
          self.log("Packet bridge first system batch core_fd=\(self.coreFD) packets=\(packets.count) protocols=\(protocols.count)")
        }
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
    guard !stopped, !failed, coreAttached else { return }
    while pendingIndex < pendingPackets.count {
      let packet = pendingPackets[pendingIndex]
      let length = packet.withUnsafeBytes { send(flowFD, $0.baseAddress, $0.count, 0) }
      if length < 0 {
        let code = errno
        if code == EAGAIN || code == ENOBUFS {
          if !pressureLogged {
            pressureLogged = true
            log("Packet bridge waiting for core core_fd=\(coreFD) error=\(code) pending=\(pendingPackets.count - pendingIndex)")
          }
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
      if !sentLogged {
        sentLogged = true
        log("Packet bridge first system send core_fd=\(coreFD) bytes=\(length)")
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
    guard !stopped, coreAttached else { return }
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
    if !packets.isEmpty {
      let written = flow.writePackets(packets, withProtocols: protocols)
      if !receivedLogged {
        receivedLogged = true
        log("Packet bridge first core batch core_fd=\(coreFD) packets=\(packets.count) system_written=\(written)")
      }
    }
  }
}
