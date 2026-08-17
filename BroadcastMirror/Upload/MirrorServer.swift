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
/// ── `broadcast-mirror-v0.3.1` (busymate-devtools #1763) — NON-BLOCKING FAN-OUT ──
/// v0.3.0's `broadcast()` wrote each frame to every client with a BLOCKING
/// `send()` on the SHARED fan-out path, so a slow/stalled WiFi client backpressured
/// EVERY client — including the concurrent USB (loopback) stream that the farm
/// relies on. That is unacceptable once WiFi is a live transport, so v0.3.1 gives
/// each admitted client its OWN bounded outbound queue drained by a DEDICATED
/// writer thread with a send TIMEOUT: `broadcast()` only ENQUEUEs (O(1), never
/// blocks), each client's writer isolates its own back-pressure, the queue sheds
/// its OLDEST frames when it exceeds a byte cap (a slow client degrades — choppy,
/// re-keys on the next IDR — but never stalls the others), and a client whose
/// socket makes ZERO progress for the stall window is DROPPED. A slow WiFi client
/// therefore CANNOT degrade the concurrent USB mirror (the key Phase-2 safety
/// proof). SIGPIPE is ignored process-wide; a writer is the SOLE owner of its fd
/// close.
///
/// After auth the wire is byte-identical to v0.2.0: a new client is primed with
/// the cached SPS/PPS config, then `onClientConnected` fires so the owner forces
/// an IDR — the client decodes from the very next keyframe.

/// One admitted client: a bounded outbound frame queue drained by a DEDICATED
/// writer thread. A slow/stalled client backpressures ONLY its own thread + queue
/// — never `broadcast()` (which just enqueues) or another client. On queue
/// overflow the OLDEST data frames are shed (the client keeps the freshest frames
/// and re-syncs at the next keyframe); a socket that makes zero progress for the
/// stall window is dropped so it stops holding a slot.
final class MirrorClient {
    let fd: Int32
    let isLoopback: Bool
    private let maxQueueBytes: Int
    private let maxSendStalls: Int
    /// Guards `queue` / `queuedBytes` / `stopping`; the writer waits on it.
    private let cond = NSCondition()
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var stopping = false
    private(set) var droppedFrames = 0

    /// Fired AT MOST ONCE when the writer exits on its OWN (a write error / a
    /// dropped-because-stalled socket) so the server reaps this client from its
    /// list. NOT fired on a server-initiated `stop()` (the server already owns
    /// the bookkeeping there).
    var onWriteError: (() -> Void)?

    init(fd: Int32, isLoopback: Bool, maxQueueBytes: Int, sendTimeoutMs: Int, maxSendStalls: Int) {
        self.fd = fd
        self.isLoopback = isLoopback
        self.maxQueueBytes = max(64 * 1024, maxQueueBytes)
        self.maxSendStalls = max(1, maxSendStalls)
        // A blocking send() must NEVER wait forever — bound it so a stalled peer is
        // detected as a series of EAGAIN/EWOULDBLOCK and dropped instead of pinning
        // this client's writer thread indefinitely.
        var tv = timeval(tv_sec: sendTimeoutMs / 1000, tv_usec: Int32((sendTimeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func start() { Thread.detachNewThread { [weak self] in self?.run() } }

    /// NON-BLOCKING enqueue (the fan-out path). A config frame (SPS/PPS) is never
    /// shed. A data frame is dropped OLDEST-first when the queue would exceed the
    /// byte cap — so a slow client degrades but NEVER backpressures `broadcast()`
    /// or another client.
    func enqueue(_ data: Data, isConfig: Bool) {
        cond.lock()
        if stopping { cond.unlock(); return }
        queue.append(data)
        queuedBytes += data.count
        if !isConfig {
            while queuedBytes > maxQueueBytes && queue.count > 1 {
                let old = queue.removeFirst()
                queuedBytes -= old.count
                droppedFrames += 1
            }
        }
        cond.signal()
        cond.unlock()
    }

    /// Server-initiated stop (global `MirrorServer.stop()` or a reap after a peer
    /// drops): drop the pending queue, wake the writer, and `shutdown()` the socket
    /// so a writer BLOCKED in `send()` on a stalled peer returns promptly. The
    /// writer is the sole closer of `fd`. Idempotent.
    func stop() {
        cond.lock()
        if stopping { cond.unlock(); return }
        stopping = true
        queue.removeAll()
        queuedBytes = 0
        cond.signal()
        cond.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    /// The number of frames queued (observability / test).
    var queueDepth: Int { cond.lock(); defer { cond.unlock() }; return queue.count }

    private func run() {
        // The writer thread is the SOLE owner of the fd close.
        defer { Darwin.close(fd) }
        while true {
            cond.lock()
            while queue.isEmpty && !stopping { cond.wait() }
            if stopping { cond.unlock(); return }
            let frame = queue.removeFirst()
            queuedBytes -= frame.count
            cond.unlock()
            if !writeAll(frame) {
                // A write error OR a persistently-stalled socket — reap this client.
                cond.lock()
                let alreadyStopping = stopping
                stopping = true
                cond.unlock()
                if !alreadyStopping { onWriteError?() }
                return
            }
        }
    }

    /// Blocking (send-timeout-bounded) write of a whole frame. A partial send
    /// resets the stall counter; `maxSendStalls` consecutive zero-progress timeouts
    /// (the socket buffer never drains) ⇒ the client is stalled → DROP (return
    /// false). A real error (EPIPE/ECONNRESET/0) also drops.
    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var remaining = raw.count
            var stalls = 0
            while remaining > 0 {
                let n = send(fd, p, remaining, 0)
                if n > 0 { p = p.advanced(by: n); remaining -= n; stalls = 0; continue }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        stalls += 1
                        if stalls >= maxSendStalls { return false }   // stalled peer → drop
                        continue
                    }
                    return false   // EPIPE / ECONNRESET / … → drop
                }
                return false        // n == 0 → peer closed
            }
            return true
        }
    }
}

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
    /// (v0.3.1) Per-client outbound queue byte cap — shed oldest data frames past it.
    private let maxClientQueueBytes: Int
    /// (v0.3.1) Per-client blocking-send timeout (ms) + the consecutive-timeout budget
    /// before a stalled client is dropped.
    private let sendTimeoutMs: Int
    private let maxSendStalls: Int

    private var listenFD: Int32 = -1
    private var clients: [MirrorClient] = []
    private let lock = NSLock()
    private var config: Data?
    private(set) var acceptedTotal = 0
    private(set) var rejectedTotal = 0
    private(set) var droppedClientsTotal = 0

    /// Fired (off the accept thread's critical section) when a client is admitted.
    var onClientConnected: (() -> Void)?

    init(port: UInt16,
         authToken: String,
         wifiEnabled: Bool = true,
         authTimeoutSeconds: Int = 3,
         maxClientQueueBytes: Int = 4 * 1024 * 1024,
         sendTimeoutMs: Int = 250,
         maxSendStalls: Int = 8) {
        self.port = port
        self.authToken = authToken
        self.wifiEnabled = wifiEnabled
        self.authTimeoutSeconds = authTimeoutSeconds
        self.maxClientQueueBytes = maxClientQueueBytes
        self.sendTimeoutMs = sendTimeoutMs
        self.maxSendStalls = maxSendStalls
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
        log.info("listening on \(iface):\(self.port) wifi=\(self.wifiEnabled) authGated=\(!self.authToken.isEmpty) queueCap=\(self.maxClientQueueBytes)B")
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
    /// present `AUTH <token>\n` within `authTimeoutSeconds`. On success, wrap it in
    /// a `MirrorClient` (its own writer thread + bounded queue), prime it with the
    /// cached config, and fan out. NO blocking write happens on this admit thread —
    /// the config prime is ENQUEUED, so the fan-out never stalls on a new client.
    private func admit(_ fd: Int32, isLoopback: Bool) {
        if !isLoopback {
            guard !authToken.isEmpty, authenticate(fd) else {
                lock.lock(); rejectedTotal += 1; let n = rejectedTotal; lock.unlock()
                log.info("rejected LAN client fd=\(fd) (auth) rejectedTotal=\(n)")
                close(fd)
                return
            }
        }
        let client = MirrorClient(fd: fd,
                                  isLoopback: isLoopback,
                                  maxQueueBytes: maxClientQueueBytes,
                                  sendTimeoutMs: sendTimeoutMs,
                                  maxSendStalls: maxSendStalls)
        client.onWriteError = { [weak self, weak client] in
            guard let self, let client else { return }
            self.reap(client)
        }
        lock.lock()
        clients.append(client)
        acceptedTotal += 1
        let cfg = config
        let total = acceptedTotal
        lock.unlock()
        // Reset the LAN recv timeout so the send-side timeout owns the socket now.
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if let c = cfg { client.enqueue(c, isConfig: true) }   // prime with cached SPS/PPS (queued, non-blocking)
        client.start()
        log.info("client fd=\(fd) admitted (\(isLoopback ? "loopback" : "wifi")) total=\(total)")
        onClientConnected?()                                   // ask owner for a fresh IDR
    }

    /// Reap a client whose writer exited on its own (write error / stalled drop).
    private func reap(_ client: MirrorClient) {
        lock.lock()
        let before = clients.count
        clients.removeAll { $0 === client }
        if clients.count < before { droppedClientsTotal += 1 }
        let dropped = droppedClientsTotal
        lock.unlock()
        if clients.count < before {
            log.info("reaped a dropped client (\(client.isLoopback ? "loopback" : "wifi")) shed=\(client.droppedFrames) droppedTotal=\(dropped)")
        }
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

    /// Fan out a frame to every client — NON-BLOCKING (each client's own writer
    /// thread does the actual send). A slow/stalled client's back-pressure is
    /// contained to its own queue + thread; this never blocks, so the USB
    /// (loopback) client is never slowed by a slow WiFi client. `isConfig` marks a
    /// SPS/PPS frame so a client's queue never sheds it.
    func broadcast(_ data: Data, isConfig: Bool = false) {
        lock.lock(); let cs = clients; lock.unlock()
        guard !cs.isEmpty else { return }
        for c in cs { c.enqueue(data, isConfig: isConfig) }
    }

    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return clients.count }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        lock.lock(); let cs = clients; clients = []; config = nil; lock.unlock()
        cs.forEach { $0.stop() }
    }
}
