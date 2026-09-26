import Foundation

/// Opaque handle for a scheduled callback.
public struct ScheduledToken: Hashable {
    let id: Int
}

/// Clock + timer source. Injected everywhere timing matters (autosave
/// throttle, session debounce, watcher TTLs) so tests are deterministic.
@MainActor
public protocol AppScheduler: AnyObject {
    /// Milliseconds on a monotonic-ish clock (`Date.now()` equivalent).
    var nowMs: Double { get }
    @discardableResult
    func schedule(afterMs delay: Double, _ action: @escaping @MainActor () -> Void) -> ScheduledToken
    func cancel(_ token: ScheduledToken)
}

/// Real scheduler: wall clock + main-queue timers.
@MainActor
public final class MainQueueScheduler: AppScheduler {
    private var nextId = 0
    private var cancelled = Set<Int>()
    public init() {}

    public var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    @discardableResult
    public func schedule(afterMs delay: Double, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        nextId += 1
        let id = nextId
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay) / 1000) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if self.cancelled.remove(id) != nil { return }
                action()
            }
        }
        return ScheduledToken(id: id)
    }

    public func cancel(_ token: ScheduledToken) { cancelled.insert(token.id) }
}

/// Deterministic scheduler for tests: time only moves on `advance`.
@MainActor
public final class ManualScheduler: AppScheduler {
    private struct Job { let id: Int; let due: Double; let seq: Int; let action: @MainActor () -> Void }
    private var jobs: [Job] = []
    private var nextId = 0
    private var seq = 0
    public private(set) var nowMs: Double

    public init(startMs: Double = 1_000_000) { nowMs = startMs }

    @discardableResult
    public func schedule(afterMs delay: Double, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        nextId += 1
        seq += 1
        jobs.append(Job(id: nextId, due: nowMs + max(0, delay), seq: seq, action: action))
        return ScheduledToken(id: nextId)
    }

    public func cancel(_ token: ScheduledToken) { jobs.removeAll { $0.id == token.id } }

    public var pendingCount: Int { jobs.count }

    /// Advance the clock, running due jobs in (due, insertion) order. Jobs
    /// scheduled while advancing run too if they fall due within the window.
    public func advance(byMs delta: Double) {
        let target = nowMs + delta
        while true {
            let due = jobs.filter { $0.due <= target }.min { ($0.due, $0.seq) < ($1.due, $1.seq) }
            guard let job = due else { break }
            jobs.removeAll { $0.id == job.id }
            nowMs = max(nowMs, job.due)
            job.action()
        }
        nowMs = target
    }

    /// Run everything pending (like `vi.runOnlyPendingTimers`).
    public func runAll() {
        guard let latest = jobs.map({ $0.due }).max() else { return }
        advance(byMs: max(0, latest - nowMs))
    }
}
