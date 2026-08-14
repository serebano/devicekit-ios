import FlyingFox
import Foundation
import os

extension String {
    /// Converts the string to a UInt16 port number.
    /// - Returns: The port number if conversion succeeds, `nil` otherwise.
    func toUInt16() -> UInt16? {
        return UInt16(self)
    }
}

// MARK: - Readiness cache (busymate-devtools #1603 FIX-1)

/// A thread-safe readiness cache so `GET /ready` answers INSTANTLY WITHOUT hopping onto the
/// @MainActor. `device.info` runs `springboard.frame` — a SYNCHRONOUS testmanagerd call with no
/// suspension point — so when testmanagerd is slow to wire the FIRST probe HANGS, holds the
/// @MainActor, and (before this fix) serialised every subsequent `/ready`/`/rpc`/`/ws` request
/// behind it (the BMDEV1 wedge). A single-flight background prober refreshes this cache with a
/// hard timeout; `/ready` reads a SNAPSHOT (non-isolated, no lock contention with the prober's
/// @MainActor hop), so a stuck testmanagerd degrades the cache to `{ready:false, reason}` after
/// the timeout instead of hanging every request. `@unchecked Sendable`: all mutable state is
/// guarded by the lock (Swift 5.9 language mode).
final class ReadinessCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _ready = false
    private var _reason = "device.info not yet probed"
    /// A probe is in flight. Set by `beginProbeIfIdle`, cleared ONLY when a probe genuinely
    /// SETTLES (`settle`) — a timeout does NOT clear it, because a stuck `springboard.frame` is
    /// uncancellable + still holds the @MainActor, so a new probe would just queue behind it.
    private var _probing = false

    func snapshot() -> (ready: Bool, reason: String) {
        lock.lock(); defer { lock.unlock() }
        return (_ready, _reason)
    }

    /// A real device.info answer settled the probe — record it + free the single-flight slot.
    func settle(ready: Bool, reason: String) {
        lock.lock(); defer { lock.unlock() }
        _ready = ready
        _reason = reason
        _probing = false
    }

    /// The timeout fired while the probe is STILL stuck — degrade to not-ready but keep the
    /// single-flight slot HELD (do not spawn a second probe onto the occupied @MainActor). A
    /// no-op if the probe already settled (raced the timeout), so a successful answer wins.
    func markTimedOutIfStillProbing(reason: String) {
        lock.lock(); defer { lock.unlock() }
        if _probing {
            _ready = false
            _reason = reason
        }
    }

    /// Claim the single-flight probe slot; false if one is already in flight.
    func beginProbeIfIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _probing { return false }
        _probing = true
        return true
    }
}

// MARK: - WebSocket HTTP & JSON-RPC Server

/// WebSocket server with JSON-RPC 2.0 protocol for UI automation.
///
/// This server provides a WebSocket endpoint that accepts JSON-RPC requests
/// and returns JSON-RPC responses for programmatic device control.
///
/// ## Configuration
/// - **Host**: `127.0.0.1` (localhost only)
/// - **Port**: `12004` (configurable via `DEVICEKIT_LISTEN_PORT` environment variable)
/// - **Endpoint**: `ws://127.0.0.1:12004/ws`
///
/// ## Readiness contract (bmfarm consumes this — busymate-devtools #1570 Wave 1)
/// The XCUITest cold start legitimately takes 15-40s, and a blind poll of the
/// constant `GET /health` cannot tell a slow-but-healthy boot from a hang, and does
/// not prove that testmanagerd's control channel is actually wired (green-while-dead).
/// So this server:
///   - **RC1** prints a MACHINE-VISIBLE line to stderr — `DEVICEKIT_READY port=<p> udid=<u>
///     build=<v>` (and `DEVICEKIT_ERR <reason>` on a bind/run failure). `ios runtest` streams
///     the test process stderr, so bmfarm flips ready in ~1s + fails fast on a real error
///     instead of a blind 60s race. **#1603 FIX-2:** the line is emitted AFTER FlyingFox
///     reports `waitUntilListening()` (the socket is actually accepting), NOT before
///     `server.run()` — so a probe triggered by the line never races the not-yet-bound socket.
///   - **RC3/RC7** exposes `GET /ready` with a STRUCTURED body `{ ok, ready, port, udid, name,
///     build [, reason] }` that proves control works AND carries identity so a mis-mapped
///     `ios forward` is detectable. **#1603 FIX-1:** `/ready` reads a THREAD-SAFE cache
///     INSTANTLY (never hops onto the @MainActor), and a single-flight background prober
///     refreshes that cache from ONE `device.info` round-trip (the springboard frame, the
///     accessibility path taps use) with a HARD timeout. Because `springboard.frame` is a
///     synchronous testmanagerd call with no suspension point, a not-yet-wired testmanagerd
///     HANGS it + holds the @MainActor; the OLD `/ready` awaited it @MainActor-isolated, so
///     one stuck probe serialised every subsequent `/ready`/`/rpc`/`/ws` request (the ~13s
///     BMDEV1 hang). Now a stuck probe degrades the cache to `{ready:false, reason:"device.info
///     timed out — testmanagerd not wired yet"}` after the timeout — `/ready` stays fast +
///     honest, and bmfarm's #1603 FIX-3 reaps + respawns a fresh runtest to clear the wedge.
///     `/health` stays a constant `OK` for backward compatibility with older bmfarm builds.
///   - **RC5** wraps bind + run in a supervised catch/re-bind loop so a transient bind race
///     (`EADDRINUSE` — a stale runner still on the port) re-binds IN-PROCESS after a short
///     delay (the dying predecessor frees the port) instead of exiting and forcing a
///     30-40s host-side `ios runtest` relaunch; a genuine error propagates on the final try.
///   - **#1647 FIX-4** runs the FlyingFox accept loop DETACHED (`Task.detached`, not a bare
///     `Task {}` that would inherit this `@MainActor` class's executor). FIX-1 moved the
///     `/ready` PROBE off the MainActor, but the socket BIND (`server.run()` → `socket.bind()`)
///     was still on it, so it was starved whenever XCTest's session bootstrap held the main
///     thread with a synchronous, non-suspending accessibility call — the runner then emitted
///     NEITHER `DEVICEKIT_READY` NOR `DEVICEKIT_ERR` (a silent bind hang; LIVE on BMDEV8,
///     iOS 17.5.1: testmanagerd authorized:true, :12004 RST). Detached, the bind runs on the
///     global concurrent executor and completes regardless of the main thread.
@MainActor
final class XCTestServer {

    /// Default timeout for WebSocket operations.
    private let defaultTimeout: TimeInterval = 100

    /// Default port for the WebSocket server.
    private let defaultPort: UInt16 = 12004

    /// Server binds to localhost only by default. Override with LISTEN_HOST env var.
    private let localhost = ProcessInfo.processInfo.environment["DEVICEKIT_LISTEN_HOST"] ?? "127.0.0.1"

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "XCTestServer"
    )

    /// JSON-RPC dispatcher for routing method calls.
    private let dispatcher: JSONRPCDispatcher

    /// (#1603 FIX-1) The readiness cache `GET /ready` reads instantly + the background prober fills.
    private let readiness = ReadinessCache()

    /// Initializes the WebSocket server.
    init() {
        self.dispatcher = JSONRPCDispatcher()
    }

    /// Starts the WebSocket server and blocks until shutdown.
    ///
    /// RC5 (busymate-devtools #1570): the bind + run is SUPERVISED — a transient bind
    /// failure (a stale runner still holding the port after a host recycle) re-binds
    /// IN-PROCESS after a short delay rather than exiting the whole test process (which
    /// would force a 30-40s host-side `ios runtest` relaunch). Up to `maxAttempts` tries,
    /// each printing a parseable `DEVICEKIT_ERR` so bmfarm can fail fast on a real error.
    /// The retry delay lets a dying predecessor free the port; on the final attempt the
    /// error propagates so the test process exits honestly.
    func start() async throws {
        let port = ProcessInfo.processInfo.environment["DEVICEKIT_LISTEN_PORT"]?.toUInt16() ?? defaultPort
        let maxAttempts = 5
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await runServer(on: port)
                return // server.stop() → run() returned cleanly.
            } catch {
                let reason = "\(error)"
                Self.emitReadyLine("DEVICEKIT_ERR attempt=\(attempt) port=\(port) reason=\(reason)")
                logger.error("server run failed (attempt \(attempt)/\(maxAttempts)): \(reason)")
                if attempt >= maxAttempts { throw error }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// One bind + run cycle. Builds the server, appends every route, prints the RC1 ready
    /// line the instant it is listening, then blocks on `server.run()`.
    private func runServer(on port: UInt16) async throws {
        let server = HTTPServer(
            address: try .inet(ip4: localhost, port: port),
            timeout: defaultTimeout
        )

        logger.info("Starting JSON-RPC server on \(self.localhost):\(port)")

        // WebSocket endpoint for JSON-RPC
        let messageHandler = JSONRPCMessageHandler(dispatcher: dispatcher)
        let frameHandler = MessageFrameWSHandler(handler: messageHandler)
        let wsHandler = WebSocketHTTPHandler(handler: frameHandler)
        await server.appendRoute("GET /ws", to: wsHandler)

        // HTTP POST endpoint for JSON-RPC
        let httpHandler = JSONRPCHTTPHandler(dispatcher: dispatcher)
        await server.appendRoute("POST /rpc", to: httpHandler)

        // Health check endpoint (HTTP) — constant OK the instant the socket binds.
        // Kept for backward compatibility; NOT a proof of control (use /ready).
        await server.appendRoute("GET /health") { _ in
            HTTPResponse(statusCode: .ok, body: Data("OK".utf8))
        }

        // RC3/RC7 + #1603 FIX-1: readiness endpoint that PROVES control works + carries identity.
        // Reads the THREAD-SAFE cache INSTANTLY (never hops onto the @MainActor), so a stuck
        // testmanagerd can NEVER make `/ready` (or `/rpc`/`/ws`) hang. The cache is filled by the
        // single-flight background prober started (post-listening) below.
        let readinessCache = self.readiness
        let readyPort = port
        await server.appendRoute("GET /ready") { _ in
            Self.readinessResponse(cache: readinessCache, port: readyPort)
        }

        // Shutdown endpoint — stops the server gracefully
        await server.appendRoute("POST /shutdown") { _ in
            Task { await server.stop() }
            return HTTPResponse(statusCode: .ok, body: Data("OK".utf8))
        }

        // MJPEG streaming endpoint
        let mjpegHandler = MJPEGHTTPHandler()
        await server.appendRoute("GET /mjpeg", to: mjpegHandler)

        logger.info("Server is ready (WebSocket: ws://\(self.localhost):\(port)/ws, HTTP: POST http://\(self.localhost):\(port)/rpc, MJPEG: http://\(self.localhost):\(port)/mjpeg)")

        // #1603 FIX-2: run the accept loop in a task, then wait for FlyingFox to report it is
        // ACTUALLY listening (the socket bound + accepting) BEFORE emitting the RC1 ready line —
        // the old code emitted it before `server.run()` bound, so a probe triggered by the line
        // could race the not-yet-open socket. `waitUntilListening` throws if the run task failed
        // to bind (surfaced as a `DEVICEKIT_ERR` by `start`'s supervised catch → RC5 re-bind).
        //
        // (#1647 FIX-4) `Task.detached` — NOT a bare `Task {}`. This class is `@MainActor`, so
        // `runServer` (and a non-detached child `Task {}` it creates) inherits the MainActor
        // executor. The FlyingFox `server.run()` performs the `socket.bind()` syscall at the START
        // of its accept loop; on the MainActor that bind is starved whenever XCTest's test-session
        // bootstrap holds the main thread with a SYNCHRONOUS, non-suspending accessibility call
        // (`springboard.frame` / `device.info` — no suspension point), so the socket NEVER binds,
        // `waitUntilListening`'s 30s-timeout continuation can't be scheduled onto the blocked
        // MainActor either, and the runner emits NEITHER `DEVICEKIT_READY` NOR `DEVICEKIT_ERR` —
        // it just hangs (LIVE-proven on BMDEV8, iOS 17.5.1: testmanagerd authorized:true, reboots
        // delivered, yet :12004 returns TCP RST and both machine lines are absent). Running the
        // accept loop DETACHED binds `:12004` on the global concurrent executor, immune to whatever
        // the main thread is doing — the bind (and `waitUntilListening`) complete regardless. Route
        // handlers that need XCUITest still hop to the main thread at REQUEST time; the detached
        // readiness prober below already proves an off-MainActor `device.info` works.
        let runTask = Task.detached { try await server.run() }
        try await server.waitUntilListening(timeout: 30)

        // RC1: the machine-visible ready line — now the socket is genuinely accepting. bmfarm
        // watches the runtest child stderr for this to trigger an immediate /ready probe (it does
        // NOT blindly trust the line — the /ready cache probe is the truth).
        Self.emitReadyLine("DEVICEKIT_READY port=\(port) udid=\(Self.deviceUdid()) build=\(Self.runnerBuild())")

        // #1603 FIX-1: start the single-flight background readiness prober now that we are
        // listening (it fills the cache `/ready` reads).
        Self.startReadinessLoop(dispatcher: self.dispatcher, cache: self.readiness)

        // Block until the server stops (POST /shutdown → server.stop() → run() returns).
        try await runTask.value
    }

    // MARK: - Readiness (RC3/RC7 + #1603 FIX-1)

    /// Build the `/ready` HTTP response from the CACHE — INSTANT, never hops onto the @MainActor
    /// (so a stuck testmanagerd never makes `/ready` hang). The readiness is carried by the
    /// body's `ready` field (bmfarm reads that, not the status), so it is always HTTP 200; a
    /// not-ready snapshot carries the `reason` (e.g. "device.info timed out — testmanagerd not
    /// wired yet"). `nonisolated` so the FlyingFox route closure can call it off the @MainActor.
    nonisolated private static func readinessResponse(cache: ReadinessCache, port: UInt16) -> HTTPResponse {
        let snap = cache.snapshot()
        var body: [String: Any] = [
            "ok": snap.ready,
            "ready": snap.ready,
            "port": Int(port),
            "udid": deviceUdid(),
            "name": deviceName(),
            "build": runnerBuild(),
        ]
        if !snap.ready { body["reason"] = snap.reason }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{\"ok\":false,\"ready\":false}".utf8)
        return HTTPResponse(statusCode: .ok, body: data)
    }

    /// #1603 FIX-1: the single-flight background readiness prober. DETACHED so it never hops
    /// onto a stuck @MainActor. Every ~1s, if no probe is in flight, run ONE `device.info`
    /// round-trip on the @MainActor RACED against a hard timeout on the cooperative pool. The
    /// dispatch is UNSTRUCTURED (its own `Task`) — `springboard.frame` has no suspension point so
    /// a stuck one is uncancellable + still holds the @MainActor; awaiting it structurally would
    /// wedge the loop, so we never await it. On a stuck probe the timeout marks the cache
    /// `{ready:false, reason}` and LEAVES the single-flight slot held (no second probe queues
    /// behind the occupied @MainActor); when the stuck dispatch EVENTUALLY completes (testmanagerd
    /// finally wired), `settle` records the real answer + frees the slot for the next cycle.
    nonisolated private static func startReadinessLoop(dispatcher: JSONRPCDispatcher, cache: ReadinessCache) {
        let timeoutMs = ProcessInfo.processInfo.environment["DEVICEKIT_READY_TIMEOUT_MS"].flatMap { Int($0) } ?? 3000
        Task.detached {
            while !Task.isCancelled {
                if cache.beginProbeIfIdle() {
                    // The dispatch (unstructured) — settles the cache + frees single-flight WHEN it finishes.
                    Task {
                        let probe = #"{"jsonrpc":"2.0","method":"device.info","params":{},"id":1}"#
                        let raw = await dispatcher.dispatch(probe)
                        let ok = raw.contains("\"result\"") && raw.contains("screenSize")
                        cache.settle(ready: ok, reason: ok ? "" : raw)
                    }
                    // The timeout (unstructured) — degrades the cache but keeps single-flight held.
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                        cache.markTimedOutIfStillProbing(reason: "device.info timed out — testmanagerd not wired yet")
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Identity + build (RC1/RC7)

    /// The device UDID — the HARDWARE udid go-ios uses, which the host passes via the
    /// `DEVICEKIT_UDID` env when launching runtest (UIDevice.identifierForVendor is a
    /// DIFFERENT per-app UUID that would never match, so it is NOT used). Empty when the
    /// host did not set the env → bmfarm skips the identity assertion (RC7) and trusts the
    /// `ready` flag; when set, bmfarm rejects a mis-mapped `ios forward` by construction.
    nonisolated private static func deviceUdid() -> String {
        return ProcessInfo.processInfo.environment["DEVICEKIT_UDID"] ?? ""
    }

    /// A friendly device name for logs (host may pass `DEVICEKIT_NAME`; else the OS hostname).
    nonisolated private static func deviceName() -> String {
        if let n = ProcessInfo.processInfo.environment["DEVICEKIT_NAME"], !n.isEmpty { return n }
        return ProcessInfo.processInfo.hostName
    }

    /// The runner BUILD id — stamped into the app's `CFBundleShortVersionString` by the
    /// Makefile from the release tag (busymate-devtools #1570 pin). bmfarm reports this
    /// LIVE (the version-everywhere rule) so a fleet-wide runner drift is visible.
    nonisolated private static func runnerBuild() -> String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    // MARK: - RC1 emit + RC5 helpers

    /// Emit a machine-visible line to stderr (stdout is buffered/interleaved by xcbeautify;
    /// stderr is what `ios runtest` streams first). Never throws.
    nonisolated private static func emitReadyLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

}
