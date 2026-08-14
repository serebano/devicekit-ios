import Foundation
import Dispatch
import os

/// Sheds load when the extension nears the ReplayKit ~50 MB ceiling.
///
/// A broadcast upload extension is jetsam-killed the instant it breaches its
/// memory limit, tearing down the stream. This guard listens for the system
/// memory-pressure signal and decimates the encode rate before that happens:
/// normal = encode everything, warning = drop ~half, critical = drop ~three of
/// four. It degrades the mirror's frame rate instead of losing the whole session.
final class MemoryPressureGuard {
    enum Level: Int { case normal = 0, warning = 1, critical = 2 }

    private let log = Logger(subsystem: BroadcastMirror.subsystem, category: "mem")
    private var source: DispatchSourceMemoryPressure?
    private let lock = NSLock()
    private var _level: Level = .normal
    private var counter = 0

    var level: Level { lock.lock(); defer { lock.unlock() }; return _level }

    func start() {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                        queue: DispatchQueue.global(qos: .utility))
        s.setEventHandler { [weak self] in
            guard let self, let src = self.source else { return }
            let data = src.data
            let newLevel: Level = data.contains(.critical) ? .critical
                                 : data.contains(.warning) ? .warning : .normal
            self.lock.lock(); self._level = newLevel; self.lock.unlock()
            self.log.info("memory pressure -> \(newLevel.rawValue)")
        }
        source = s
        s.resume()
    }

    /// Call once per incoming frame. Returns `true` to KEEP (encode) the frame,
    /// `false` to DROP it. Under pressure, frames are dropped in a fixed pattern
    /// so pacing stays even (drop the 2nd of every 2 under warning, 3 of every 4
    /// under critical).
    func shouldEncode() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch _level {
        case .normal:
            return true
        case .warning:
            counter += 1; return counter % 2 == 1        // keep 1 of 2
        case .critical:
            counter += 1; return counter % 4 == 1        // keep 1 of 4
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
