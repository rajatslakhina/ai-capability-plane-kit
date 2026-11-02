import Foundation

/// A monotonic clock in seconds. Injected so breaker timing is testable.
public protocol PlaneClock: Sendable {
    func now() -> Double
}

/// Production clock backed by `ProcessInfo.systemUptime` (monotonic, unaffected by wall-clock changes).
public struct SystemPlaneClock: PlaneClock {
    public init() {}
    public func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// A clock tests can advance by hand.
public final class ManualPlaneClock: PlaneClock, @unchecked Sendable {
    // @unchecked: all access to `current` goes through `lock`.
    private let lock = NSLock()
    private var current: Double

    public init(start: Double = 0) { current = start }

    public func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        current += seconds
    }
}

/// What the resolver may assume about a provider's health right now.
public enum HealthVerdict: Sendable, Hashable {
    case healthy
    /// Cooldown elapsed: exactly one probe request may go through.
    case probeAllowed
    case open
}

/// Consecutive-failure circuit breakers, one per provider.
///
/// closed --(threshold failures)--> open --(cooldown)--> half-open (one probe)
/// half-open --success--> closed;  half-open --failure--> open (cooldown restarts)
public struct HealthBoard: Sendable {
    fileprivate enum State: Sendable, Hashable {
        case closed(failures: Int)
        case open(since: Double)
        case halfOpen(probeInFlight: Bool)
    }

    public let failureThreshold: Int
    public let cooldown: Double
    private var states: [String: State] = [:]
    /// Bumped on every change of breaker *phase* (closed/open/half-open). A result that
    /// comes back from an `await` carries the epoch observed at dispatch; if the phase
    /// changed meanwhile, the result is stale and must not move the breaker.
    private var epochs: [String: UInt64] = [:]

    public init(failureThreshold: Int = 2, cooldown: Double = 30) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = cooldown.isFinite ? max(0, cooldown) : 30
    }

    public func verdict(for id: String, now: Double) -> HealthVerdict {
        switch states[id] ?? .closed(failures: 0) {
        case .closed: return .healthy
        case .open(let since): return now - since >= cooldown ? .probeAllowed : .open
        case .halfOpen(let inFlight): return inFlight ? .open : .probeAllowed
        }
    }

    public func epoch(for id: String) -> UInt64 { epochs[id] ?? 0 }

    private mutating func transition(_ id: String, to newState: State) {
        let old = states[id] ?? .closed(failures: 0)
        states[id] = newState
        if old.phase != newState.phase { epochs[id] = epoch(for: id).saturatingIncrement() }
    }

    /// Call before dispatching to a provider whose verdict was `.probeAllowed`.
    public mutating func beginProbe(_ id: String) {
        transition(id, to: .halfOpen(probeInFlight: true))
    }

    /// Records a success. With `ifEpoch`, the result is ignored when the breaker changed
    /// phase since dispatch (a late success must not skip an open breaker's cooldown).
    @discardableResult
    public mutating func recordSuccess(_ id: String, ifEpoch expected: UInt64? = nil) -> Bool {
        if let expected, expected != epoch(for: id) { return false }
        transition(id, to: .closed(failures: 0))
        return true
    }

    @discardableResult
    public mutating func recordFailure(_ id: String, now: Double, ifEpoch expected: UInt64? = nil) -> Bool {
        if let expected, expected != epoch(for: id) { return false }
        switch states[id] ?? .closed(failures: 0) {
        case .closed(let failures):
            let next = failures.saturatingAdd(1)
            transition(id, to: next >= failureThreshold ? .open(since: now) : .closed(failures: next))
        case .halfOpen, .open:
            transition(id, to: .open(since: now))
        }
        return true
    }

    /// Clears a probe that never completed (e.g. the request was cancelled), so the
    /// next request may probe immediately instead of waiting a full cooldown.
    public mutating func abandonProbe(_ id: String, now: Double) {
        if case .halfOpen(true) = states[id] { transition(id, to: .open(since: now - cooldown)) }
    }
}

private extension HealthBoard.State {
    var phase: Int {
        switch self {
        case .closed: return 0
        case .open: return 1
        case .halfOpen: return 2
        }
    }
}

extension Int {
    /// Addition that clamps at `Int.max` / `Int.min` instead of trapping.
    public func saturatingAdd(_ other: Int) -> Int {
        let (result, overflow) = addingReportingOverflow(other)
        if !overflow { return result }
        return other > 0 ? Int.max : Int.min
    }
}

extension UInt64 {
    public func saturatingIncrement() -> UInt64 {
        self == UInt64.max ? UInt64.max : self + 1
    }
}
