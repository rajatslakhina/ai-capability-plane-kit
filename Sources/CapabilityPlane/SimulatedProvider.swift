import Foundation

/// A thread-safe on/off switch shared between a simulated adapter and whoever
/// drives it (a test, or the demo's "simulate outage" toggle).
public final class FailureSwitch: @unchecked Sendable {
    // @unchecked: `on` is only read or written while holding `lock`.
    private let lock = NSLock()
    private var on: Bool

    public init(isOn: Bool = false) { on = isOn }

    public var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); defer { lock.unlock() }; on = newValue }
    }
}

/// Deterministic stand-in for a real provider. Used by the tests and the demo app;
/// production adapters wrap Foundation Models, a regional SDK, or an HTTP client.
public struct SimulatedProviderAdapter: ProviderAdapter {
    public let descriptor: ProviderDescriptor
    public let failure: FailureSwitch
    public let latency: Duration

    public init(descriptor: ProviderDescriptor, failure: FailureSwitch = FailureSwitch(), latency: Duration = .zero) {
        self.descriptor = descriptor
        self.failure = failure
        self.latency = latency
    }

    public func execute(_ request: CapabilityRequest) async throws -> String {
        if latency > .zero { try await Task.sleep(for: latency) }
        if failure.isOn { throw ProviderError.unavailable(descriptor.id) }
        let preview = request.input.prefix(48)
        return "[\(descriptor.displayName)] \(request.capability.rawValue): \(preview)"
    }
}
