import Foundation
import Darwin
import os

/// TCP fan-out for the encoded H.264 Annex-B stream — the on-device `:12005`
/// endpoint. As of `broadcast-mirror-v0.3.0` (busymate-devtools #1759) this binds
/// **`0.0.0.0`** (all interfaces) instead of loopback-only, so the bmfarm host can
/// reach it EITHER over USB (`ios forward … 12005` → 127.0.0.1) OR directly over
/// WiFi (`<phone_lan_ip>:12005`) — a transport disjoint from the USB link, so a
/// usbmux-dark USB brownout no longer blinds the mirror.
///
/// A `0.0.0.0` H.264 stream on a shared LAN MUST NOT be open, so a **shared-token
/// handshake** gates every NON-loopback (LAN/WiFi) connection: the client sends
/// `AUTH <token>\n` BEFORE any frames; the server validates it (constant-time)
/// and only then admits the client into the fan-out. **Loopback (127.0.0.0/8)
/// connections are trusted + token-EXEMPT** — only code already ON the device
/// (the go-ios USB forward) can reach 127.0.0.1, so the USB path is unchanged.
/// The handshake runs on a per-client thread with a bounded recv timeout, so a
/// silent/slow scanner can never stall the accept loop or a real client.
///
/// After auth the wire is byte-identical to v0.2.0: a new client is primed with
/// the cached SPS/PPS config, then `onClientConnected` fires so the owner forces
/// an IDR — the client decodes from the very next keyframe. Dead sockets are
/// reaped on a failed write; SIGPIPE is ignored process-wide.
final class MirrorServer {
    private let log = Logger(subsystem: BroadcastMirror.subsystem, category: "tcp")
    private let port: UInt16
    /// Shared secret required from every non-loopback client. Empty ⇒ LAN clients
    /// are refused outright (fail-closed: never expose an unauthenticated stream).
    private let authToken: String
    /// When false, bind loopback-only (`127.0.0.1`) — the pre-v0.3.0 USB-only
    /// posture, remotely selectable via the App Group `mirror-config.json` without
    /// a rebuild (a reversible kill-switch for the WiFi surface).
    private let wifiEnabled: Bool
    /// Seconds a LAN client has to complete the `AUTH <token>\n` handshake.
    private let authTimeoutSeconds: Int

    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    private let lock = NSLock()
    private var config: Data?
    private(set) var acceptedTotal = 0
    private(set) var rejectedTotal = 0

    /// Fired (off the accept thread's critical section) when a client is admitted.
    var onClientConnected: (() -> Void)?

    init(port: UInt16, authToken: String, wifiEnabled: Bool = true, authTimeoutSeconds: Int = 3) {
        self.port = port
        self.authToken = authToken
        self.wifiEnabled = wifiEnabled
        self.authTimeoutSeconds = authTimeoutSeconds
    }

    func start() {
        signal(SIGPIPE, SIG_IGN)   // once: a dropped client must not kill us
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { log.error("socket() failed errno=\(errno)"); return }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // v0.3.0: bind all interfaces (WiFi + loopback) unless the WiFi surface is
        // disabled, in which case fall back to the loopback-only USB posture.
        addr.sin_addr.s_addr = wifiEnabled ? INADDR_ANY : inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { log.error("bind(:\(self.port)) failed errno=\(errno)"); close(listenFD); listenFD = -1; return }
        guard listen(listenFD, 8) == 0 else { log.error("listen failed errno=\(errno)"); close(listenFD); listenFD = -1; return }
        let iface = wifiEnabled ? "0.0.0.0" : "127.0.0.1"
        log.info("listening on \(iface):\(self.port) wifi=\(self.wifiEnabled) authGated=\(!self.authToken.isEmpty)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
            }
            if fd < 0 { if errno == EINTR { continue }; break }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            // 127.0.0.0/8 (host byte order high octet == 127) is the trusted USB path.
            let isLoopback = (UInt32(bigEndian: peer.sin_addr.s_addr) >> 24) == 127
            // Handshake off the accept thread so a stalled LAN peer can't block accept().
            Thread.detachNewThread { [weak self] in self?.admit(fd, isLoopback: isLoopback) }
        }
    }

    /// Gate a freshly-accepted socket: loopback is trusted; a LAN client must
    /// present `AUTH <token>\n` within `authTimeoutSeconds`.
    private func admit(_ fd: Int32, isLoopback: Bool) {
        if !isLoopback {
            guard !authToken.isEmpty, authenticate(fd) else {
                lock.lock(); rejectedTotal += 1; let n = rejectedTotal; lock.unlock()
                log.info("rejected LAN client fd=\(fd) (auth) rejectedTotal=\(n)")
                close(fd)
                return
            }
        }
        lock.lock()
        clients.append(fd)
        acceptedTotal += 1
        let cfg = config
        let total = acceptedTotal
        lock.unlock()
        log.info("client fd=\(fd) admitted (\(isLoopback ? "loopback" : "wifi")) total=\(total)")
        if let c = cfg { writeAll(fd, c) }   // prime with cached SPS/PPS
        onClientConnected?()                 // ask owner for a fresh IDR
    }

    /// Read `AUTH <token>\n` (bounded) and constant-time compare against `authToken`.
    private func authenticate(_ fd: Int32) -> Bool {
        var tv = timeval(tv_sec: authTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = [UInt8]()
        line.reserveCapacity(300)
        var byte: UInt8 = 0
        let maxLen = 512
        while line.count < maxLen {
            let n = recv(fd, &byte, 1, 0)
            if n <= 0 { return false }          // timeout / closed / error → refuse
            if byte == 0x0A { break }           // \n terminates the auth line
            if byte != 0x0D { line.append(byte) } // ignore \r
        }
        // Expect prefix "AUTH " then the token (no spaces in the token).
        let prefix: [UInt8] = Array("AUTH ".utf8)
        guard line.count > prefix.count, Array(line.prefix(prefix.count)) == prefix else { return false }
        let presented = Array(line.dropFirst(prefix.count))
        return constantTimeEqual(presented, Array(authToken.utf8))
    }

    private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = a.count ^ b.count
        let n = max(a.count, b.count)
        var i = 0
        while i < n {
            let av = i < a.count ? Int(a[i]) : 0
            let bv = i < b.count ? Int(b[i]) : 0
            diff |= (av ^ bv)
            i += 1
        }
        return diff == 0
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
