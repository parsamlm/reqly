import CGtk
import Foundation
import GtkBinding

/// How long the window's thread kept the main loop waiting, as Windows' ThreadWatch measures it: a
/// GLib timeout every 16 ms, at G_PRIORITY_DEFAULT, notes the time, and each tick's wait is the
/// time since the tick before, less 16 ms. GTK lays out and draws on the same thread, so slow
/// drawing counts too. It ticks from ``start()`` to ``stop()``, and keeps every tick, so a part can
/// read any step's waits, by its start and end in monotonic microseconds.
@MainActor
final class ThreadWatch {
    /// The waits of some ticks.
    struct Waits: CustomStringConvertible {
        /// The longest, in milliseconds.
        var longest: Double
        /// How many were over 100 ms, which you'd notice.
        var over100: Int
        /// How many ticks there were.
        var ticks: Int

        var description: String {
            String(format: "longest wait %.0f ms, %d over 100 ms, in %d ticks", longest, over100, ticks)
        }
    }

    private(set) var ticks: [Int] = []
    private var source: UInt32?

    /// Starts ticking, unless it is already.
    func start() {
        guard source == nil else { return }
        ticks.append(monotonicMicroseconds())
        source = timeout(16, priority: G_PRIORITY_DEFAULT) { [weak self] in
            self?.ticks.append(monotonicMicroseconds())
            return true
        }
    }

    func stop() {
        if let source {
            g_source_remove(source)
        }
        source = nil
    }

    isolated deinit {
        stop()
    }

    /// The waits of the ticks from `start` to `end`, each from the tick before it. The tick that
    /// ends a wait running past `end` counts too, since that wait was under way.
    func waits(from start: Int = 0, to end: Int = .max) -> Waits {
        var waits = Waits(longest: 0, over100: 0, ticks: 0)
        guard let first = ticks.firstIndex(where: { $0 > start }), first > 0 else { return waits }
        for index in first..<ticks.count {
            let wait = Double(ticks[index] - ticks[index - 1]) / 1000 - 16
            waits.longest = max(waits.longest, wait)
            waits.over100 += wait > 100 ? 1 : 0
            waits.ticks += 1
            if ticks[index] > end { break }
        }
        return waits
    }
}
