// Providers: what each backend can do, where, and from which OS version.

/// Where a provider processes the payload. This is what residency rules govern.
public enum ProcessingLocation: Hashable, Sendable, CustomStringConvertible {
    /// Payload never leaves the device.
    case onDevice
    /// Payload is processed by servers inside the given jurisdiction.
    case hostedIn(Jurisdiction)

    public var description: String {
        switch self {
        case .onDevice: return "on-device"
        case .hostedIn(let j): return "cloud(\(j))"
        }
    }
}

/// Coarse provider class, used for preference ordering.
public enum ProviderKind: String, Sendable, Hashable, CaseIterable, Codable {
    case onDevice
    case regionalCloud
    case frontierCloud
}

/// What a provider offers inside one jurisdiction.
public struct ProviderOffer: Sendable, Hashable {
    public let capabilities: Set<Capability>
    public let minimumOS: OSVersion

    public init(capabilities: Set<Capability>, minimumOS: OSVersion = OSVersion(0)) {
        self.capabilities = capabilities
        self.minimumOS = minimumOS
    }
}

/// Static description of a provider. Availability is per jurisdiction because the
/// same vendor ships different feature sets in different markets (for example a
/// China launch with Writing Tools and translation but no assistant).
public struct ProviderDescriptor: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let kind: ProviderKind
    public let processing: ProcessingLocation
    /// Per-jurisdiction offer. A jurisdiction missing here uses `defaultOffer`;
    /// if that is nil too, the provider is not offered there.
    public let offers: [Jurisdiction: ProviderOffer]
    public let defaultOffer: ProviderOffer?
    /// Jurisdictions where the provider is never offered, whatever `defaultOffer` says.
    public let excluded: Set<Jurisdiction>
    public let requiresNetwork: Bool
    /// Relative cost used only as a ranking tie-breaker. Never multiplied.
    public let relativeCost: Int

    public init(
        id: String,
        displayName: String,
        kind: ProviderKind,
        processing: ProcessingLocation,
        offers: [Jurisdiction: ProviderOffer] = [:],
        defaultOffer: ProviderOffer?,
        excluded: Set<Jurisdiction> = [],
        requiresNetwork: Bool,
        relativeCost: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.processing = processing
        self.offers = offers
        self.defaultOffer = defaultOffer
        self.excluded = excluded
        self.requiresNetwork = requiresNetwork
        self.relativeCost = max(0, relativeCost)
    }

    public func offer(in jurisdiction: Jurisdiction) -> ProviderOffer? {
        guard !excluded.contains(jurisdiction) else { return nil }
        return offers[jurisdiction] ?? defaultOffer
    }
}

/// The execution side of a provider. Adapters are deliberately dumb: they never
/// see policy, so a policy bug cannot be "fixed" inside one adapter and forgotten
/// in the others.
public protocol ProviderAdapter: Sendable {
    var descriptor: ProviderDescriptor { get }
    func execute(_ request: CapabilityRequest) async throws -> String
}

/// Errors an adapter may throw.
public enum ProviderError: Error, Sendable, Equatable {
    case unavailable(String)
    case timedOut
}
