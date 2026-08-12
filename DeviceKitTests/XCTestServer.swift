import FlyingFox
import Foundation
import UIKit
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
///     (`EADDRINUSE` — a stale runner still on the port) re-binds in-process (best-effort
///     `POST /shutdown` to the squatter, then retry) instead of exiting and forcing a
///     30-40s host-side `ios runtest` relaunch.
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
    /// in-process rather than exiting the whole test process. Up to `maxAttempts` tries,
    /// each printing a parseable `DEVICEKIT_ERR` so bmfarm can fail fast on a real error.
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
                // On an address-in-use race, ask the squatter on this port to shut down,
                // then re-bind. Best-effort — a failure to reach it just falls through to
                // the retry delay (the predecessor exits and frees the port shortly).
                if Self.looksLikeAddressInUse(reason) {
                    await Self.requestShutdown(host: localhost, port: port)
                }
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
        return HTTPResponse(statusCode: ok ? .ok : .serviceUnavailable, body: data)
    }

    // MARK: - Identity + build (RC1/RC7)

    /// The device UDID (identifier for vendor is per-vendor, so prefer the udid the host
    /// passed via env when launching runtest; fall back to the vendor id). Lets bmfarm
    /// detect a mis-mapped `ios forward` by construction.
    private static func deviceUdid() -> String {
        if let u = ProcessInfo.processInfo.environment["DEVICEKIT_UDID"], !u.isEmpty { return u }
        return UIDevice.current.identifierForVendor?.uuidString ?? ""
    }

    private static func deviceName() -> String {
        return UIDevice.current.name
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

    private static func looksLikeAddressInUse(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("in use") || r.contains("eaddrinuse") || r.contains("address already")
    }

    /// Best-effort `POST /shutdown` to a stale server squatting the port (RC5). Any failure
    /// is swallowed — the retry delay covers a predecessor that exits on its own.
    private static func requestShutdown(host: String, port: UInt16) async {
        guard let url = URL(string: "http://\(host):\(port)/shutdown") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: req)
    }
}
