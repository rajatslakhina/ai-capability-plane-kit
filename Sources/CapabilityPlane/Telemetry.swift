import Foundation

/// Structured events. Payload text is never included: telemetry must not become
/// a residency leak of its own.
public enum PlaneEvent: Sendable, Hashable {
    case resolved(feature: String, capability: Capability, jurisdictions: [Jurisdiction], chain: [String], configVersion: UInt64)
    case auditBlocked(feature: String, providerID: String, reasons: [RejectionReason])
    case served(feature: String, providerID: String, attempt: Int)
    case providerFailed(feature: String, providerID: String)
    case discardedAfterPolicyChange(feature: String, providerID: String)
    case degraded(feature: String, capability: Capability, reason: DegradeReason)
    case contextChanged(generation: UInt64, jurisdictions: [Jurisdiction])
    case configApplied(version: UInt64)
    case configRejected(offered: UInt64, current: UInt64)
}

public protocol TelemetrySink: Sendable {
    func record(_ event: PlaneEvent)
}

public struct NullTelemetry: TelemetrySink {
    public init() {}
    public func record(_ event: PlaneEvent) {}
}

/// Bounded in-memory sink: keeps the newest `capacity` events and counts the rest.
/// Bounded on purpose; an unbounded telemetry buffer is a memory leak with a dashboard.
/// Implemented as a ring buffer so each `record` is O(1). Capacity is clamped to
/// `1...maxCapacity`, and storage grows on demand rather than being reserved up front.
/// A hostile capacity such as `Int.max` therefore cannot trap the allocator.
public final class BoundedTelemetryBuffer: TelemetrySink, @unchecked Sendable {
    // @unchecked: `storage`, `head` and `dropped` are only touched while holding `lock`.
    private let lock = NSLock()
    private var storage: [PlaneEvent] = []
    private var head = 0          // index of the oldest event once the ring is full
    private var dropped = 0
    public let capacity: Int
    public static let maxCapacity = 65_536

    public init(capacity: Int = 256) {
        self.capacity = min(max(1, capacity), Self.maxCapacity)
    }

    public func record(_ event: PlaneEvent) {
        lock.lock(); defer { lock.unlock() }
        if storage.count < capacity {
            storage.append(event)
            return
        }
        // Full: overwrite the oldest slot. `head` is always in 0..<capacity.
        storage[head] = event
        head = (head + 1) % capacity          // capacity >= 1, so no division by zero
        dropped = dropped.saturatingAdd(1)
    }

    /// Events oldest-first.
    public var events: [PlaneEvent] {
        lock.lock(); defer { lock.unlock() }
        guard storage.count == capacity, head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }
}
