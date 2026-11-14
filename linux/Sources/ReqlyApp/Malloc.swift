import Foundation
import GtkBinding

/// glibc's malloc, through the functions it has, looked up as Reqly runs. Left alone, it makes up
/// to 8 arenas for each processor, one for each thread that finds the others busy, and keeps what
/// a thread frees in that thread's arena for later: after a session of 100,000 requests was
/// cleared, 96 of them held hundreds of megabytes Reqly no longer used.
enum Malloc {
    /// How many arenas Reqly's threads share. In the speed part, 8 kept about 50 MB less than
    /// glibc's 96 at 100,000 requests and after Clear, and half the growth over four fills and
    /// Clears, with the window waiting no longer; 4 kept 10 MB less again, but the window's
    /// longest waits grew by 10 to 15 ms.
    static let arenas: Int32 = 8

    /// Caps malloc's arenas at ``arenas``, as `MALLOC_ARENA_MAX` does, unless that's set. Before
    /// Reqly's threads start, as they each take one.
    static func limitArenas() {
        typealias Option = @convention(c) (Int32, Int32) -> Int32
        guard ProcessInfo.processInfo.environment["MALLOC_ARENA_MAX"] == nil,
            let mallopt = Newer.lookup("mallopt", as: Option.self)
        else { return }
        // M_ARENA_MAX, from malloc.h.
        _ = mallopt(-8, arenas)
    }

    /// Gives malloc's free memory back to the system, as `malloc_trim(0)` does, and says whether
    /// it could.
    @discardableResult
    static func trim() -> Bool {
        typealias Trim = @convention(c) (Int) -> Int32
        guard let trim = Newer.lookup("malloc_trim", as: Trim.self) else { return false }
        _ = trim(0)
        return true
    }
}
