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
///   - **RC1** prints a MACHINE-VISIBLE line to stderr the instant it is listening —
///     `DEVICEKIT_READY port=<p> udid=<u> build=<v>` (and `DEVICEKIT_ERR <reason>` on a
///     bind/run failure). `ios runtest` streams the test process stderr, so bmfarm flips
///     ready in ~1s + fails fast on a real error instead of a blind 60s race.
///   - **RC3/RC7** exposes `GET /ready` which lazily runs ONE real testmanagerd round-trip
///     (`device.info` → the springboard frame, the same accessibility path taps use) and
///     returns a STRUCTURED body `{ ok, ready, port, udid, name, build }` only when that
///     round-trip succeeds — a probe that proves control works AND carries identity so a
///     mis-mapped `ios forward` is detectable. `/health` stays a constant `OK` for
///     backward compatibility with older bmfarm builds.
///   - **RC5** wraps bind + run in a supervised catch/re-bind loop so a transient bind race
///     (`EADDRINUSE` — a stale runner still on the port) re-binds IN-PROCESS after a short
///     delay (the dying predecessor frees the port) instead of exiting and forcing a
///     30-40s host-side `ios runtest` relaunch; a genuine error propagates on the final try.
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

        // RC3/RC7: readiness endpoint that PROVES control works + carries identity.
        // Runs ONE real testmanagerd round-trip (device.info) and returns a structured
        // body only when it succeeds. bmfarm probes this instead of /health.
        let dispatcher = self.dispatcher
        await server.appendRoute("GET /ready") { _ in
            await Self.readinessResponse(dispatcher: dispatcher, port: port)
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
        // RC1: the machine-visible ready line — printed the instant routes are up + we are
        // about to accept. bmfarm watches the runtest child stderr for this to trigger an
        // immediate /ready probe (it does NOT blindly trust the line — the probe is the truth).
        Self.emitReadyLine("DEVICEKIT_READY port=\(port) udid=\(Self.deviceUdid()) build=\(Self.runnerBuild())")
        try await server.run()
    }

    // MARK: - Readiness (RC3/RC7)

    /// Build the `/ready` response: one real `device.info` round-trip (the springboard
    /// frame via XCUITest → testmanagerd) then a structured `{ ok, ready, port, udid,
    /// name, build }` body, HTTP 200 only when the round-trip succeeded (503 otherwise).
    @MainActor
    private static func readinessResponse(dispatcher: JSONRPCDispatcher, port: UInt16) async -> HTTPResponse {
        let probe = #"{"jsonrpc":"2.0","method":"device.info","params":{},"id":1}"#
        let raw = await dispatcher.dispatch(probe)
        let ok = raw.contains("\"result\"") && raw.contains("screenSize")
        var body: [String: Any] = [
            "ok": ok,
            "ready": ok,
            "port": Int(port),
            "udid": deviceUdid(),
            "name": deviceName(),
            "build": runnerBuild(),
        ]
        if !ok { body["error"] = raw }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{\"ok\":false,\"ready\":false}".utf8)
        // Always HTTP 200 — the READINESS is carried by the body's `ready` field (bmfarm reads that,
        // not the status), so we never depend on a specific FlyingFox status-code case.
        return HTTPResponse(statusCode: .ok, body: data)
    }

    // MARK: - Identity + build (RC1/RC7)

    /// The device UDID — the HARDWARE udid go-ios uses, which the host passes via the
    /// `DEVICEKIT_UDID` env when launching runtest (UIDevice.identifierForVendor is a
    /// DIFFERENT per-app UUID that would never match, so it is NOT used). Empty when the
    /// host did not set the env → bmfarm skips the identity assertion (RC7) and trusts the
    /// `ready` flag; when set, bmfarm rejects a mis-mapped `ios forward` by construction.
    private static func deviceUdid() -> String {
        return ProcessInfo.processInfo.environment["DEVICEKIT_UDID"] ?? ""
    }

    /// A friendly device name for logs (host may pass `DEVICEKIT_NAME`; else the OS hostname).
    private static func deviceName() -> String {
        if let n = ProcessInfo.processInfo.environment["DEVICEKIT_NAME"], !n.isEmpty { return n }
        return ProcessInfo.processInfo.hostName
    }

    /// The runner BUILD id — stamped into the app's `CFBundleShortVersionString` by the
    /// Makefile from the release tag (busymate-devtools #1570 pin). bmfarm reports this
    /// LIVE (the version-everywhere rule) so a fleet-wide runner drift is visible.
    private static func runnerBuild() -> String {
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    // MARK: - RC1 emit + RC5 helpers

    /// Emit a machine-visible line to stderr (stdout is buffered/interleaved by xcbeautify;
    /// stderr is what `ios runtest` streams first). Never throws.
    private static func emitReadyLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

}
