import Foundation
import Darwin
import os

/// Loopback TCP fan-out for the encoded H.264 stream.
///
/// Binds `127.0.0.1:<port>`, accepts multiple clients, and broadcasts Annex-B
/// bytes to each. This is the on-device `:12005` endpoint the bmfarm producer
/// forwards off-device (`iproxy` → relay reframer). Reconnect-safe:
/// - a new client is immediately primed with the cached SPS/PPS config, then
/// - `onClientConnected` fires so the owner can force an IDR — the client decodes
///   from the very next keyframe instead of waiting up to a full GOP.
/// Dead sockets are reaped on a failed write; SIGPIPE is ignored process-wide.
final class LoopbackServer {
    private let log = Logger(subsystem: BroadcastMirror.subsystem, category: "tcp")
    private let port: UInt16
    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    private let lock = NSLock()
    private var config: Data?
    private(set) var acceptedTotal = 0

    /// Fired (off the accept thread's critical section) when a client connects.
    var onClientConnected: (() -> Void)?

    init(port: UInt16) { self.port = port }

    func start() {
        signal(SIGPIPE, SIG_IGN)   // once: a dropped client must not kill us
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { log.error("socket() failed errno=\(errno)"); return }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { log.error("bind(:\(self.port)) failed errno=\(errno)"); close(listenFD); listenFD = -1; return }
        guard listen(listenFD, 4) == 0 else { log.error("listen failed errno=\(errno)"); close(listenFD); listenFD = -1; return }
        log.info("listening on 127.0.0.1:\(self.port)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; break }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            clients.append(fd)
            acceptedTotal += 1
            let cfg = config
            lock.unlock()
            log.info("client fd=\(fd) connected total=\(self.acceptedTotal)")
            if let c = cfg { writeAll(fd, c) }   // prime with cached SPS/PPS
            onClientConnected?()                 // ask owner for a fresh IDR
        }
    }

    /// Remember the latest SPS/PPS (Annex-B) for priming future clients.
    func setConfig(_ data: Data) { lock.lock(); config = data; lock.unlock() }

    func broadcast(_ data: Data) {
        lock.lock(); let fds = clients; lock.unlock()
        guard !fds.isEmpty else { return }
        var dead: [Int32] = []
        for fd in fds where !writeAll(fd, data) { dead.append(fd) }
        if !dead.isEmpty {
            lock.lock(); clients.removeAll { dead.contains($0) }; lock.unlock()
            dead.forEach { close($0) }
            log.info("reaped \(dead.count) dead client(s)")
        }
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = send(fd, p, remaining, 0)
                if n <= 0 { if errno == EINTR { continue }; return false }
                p = p.advanced(by: n); remaining -= n
            }
            return true
        }
    }

    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return clients.count }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        lock.lock(); let fds = clients; clients = []; config = nil; lock.unlock()
        fds.forEach { close($0) }
    }
}
