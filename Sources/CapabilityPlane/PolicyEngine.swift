// Resolution: turn (request, context, config, health, parity) into a ranked chain.

/// Why a provider was not eligible. A provider collects *every* reason that applies,
/// so the decision trace explains the whole picture, not just the first check that failed.
public enum RejectionReason: Sendable, Hashable, CustomStringConvertible {
    case notOffered(in: Jurisdiction)
    case capabilityUnsupported(in: Jurisdiction)
    case osTooOld(required: OSVersion, actual: OSVersion, in: Jurisdiction)
    case residency(location: ProcessingLocation, dataClass: DataClass, in: Jurisdiction)
    case offline
    case killSwitched(KillSwitch)
    case circuitOpen
    case belowParityFloor(score: Double, floor: Double, in: Jurisdiction)
    /// No jurisdiction was supplied. Fail closed rather than approve by default.
    case noBindingJurisdiction

    /// Hard constraints are legal/contractual. Soft ones are operational. The auditor
    /// re-checks every hard constraint independently of the resolver.
    public var isHard: Bool {
        switch self {
        case .notOffered, .capabilityUnsupported, .osTooOld, .residency, .killSwitched, .noBindingJurisdiction: return true
        case .offline, .circuitOpen, .belowParityFloor: return false
        }
    }

    public var description: String {
        switch self {
        case .notOffered(let j): return "not offered in \(j)"
        case .capabilityUnsupported(let j): return "capability unsupported in \(j)"
        case let .osTooOld(required, actual, j): return "needs iOS \(required) in \(j) (device: \(actual))"
        case let .residency(location, dataClass, j): return "\(dataClass) data may not go to \(location) under \(j) rules"
        case .offline: return "device offline"
        case .killSwitched(let k): return "\(k)"
        case .circuitOpen: return "circuit open"
        case .noBindingJurisdiction: return "no binding jurisdiction"
        case let .belowParityFloor(score, floor, j):
            return "eval \(Self.percent(score)) < floor \(Self.percent(floor)) in \(j)"
        }
    }

    /// Formats a 0...1 score. Public enum cases can be built with any Double, so
    /// non-finite input is handled here rather than trapping in `Int(_:)`.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "n/a" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

public struct Rejection: Sendable, Hashable {
    public let providerID: String
    public let reasons: [RejectionReason]

    public init(providerID: String, reasons: [RejectionReason]) {
        self.providerID = providerID
        self.reasons = reasons
    }
}

/// Everything a resolver needs, captured as one immutable snapshot. Resolvers are
/// pure functions of this value, which is what makes them testable and replayable.
public struct ResolutionInput: Sendable {
    public let request: CapabilityRequest
    public let context: RegionContext
    public let jurisdictions: [Jurisdiction]
    public let providers: [ProviderDescriptor]
    public let config: PlaneConfig
    public let parity: ParityLedger
    public let health: [String: HealthVerdict]

    /// Public so resolvers outside this module can be unit-tested without a plane.
    public init(request: CapabilityRequest, context: RegionContext, jurisdictions: [Jurisdiction],
                providers: [ProviderDescriptor], config: PlaneConfig, parity: ParityLedger,
                health: [String: HealthVerdict]) {
        self.request = request
        self.context = context
        self.jurisdictions = jurisdictions
        self.providers = providers
        self.config = config
        self.parity = parity
        self.health = health
    }
}

/// The output of a resolver: a ranked chain plus an explanation for everything left out.
public struct Decision: Sendable, Hashable {
    public let capability: Capability
    public let dataClass: DataClass
    public let jurisdictions: [Jurisdiction]
    public let chain: [ProviderDescriptor]
    public let rejections: [Rejection]
    public let configVersion: UInt64

    public init(capability: Capability, dataClass: DataClass, jurisdictions: [Jurisdiction],
                chain: [ProviderDescriptor], rejections: [Rejection], configVersion: UInt64) {
        self.capability = capability
        self.dataClass = dataClass
        self.jurisdictions = jurisdictions
        self.chain = chain
        self.rejections = rejections
        self.configVersion = configVersion
    }
}

/// Pluggable resolution strategy. The plane never trusts a resolver blindly: every
/// provider it returns is re-checked by `ResidencyAuditor` before dispatch.
public protocol CapabilityResolving: Sendable {
    func resolve(_ input: ResolutionInput) -> Decision
}

/// The hard-constraint checks, shared by the default resolver and the auditor.
public enum HardConstraints {
    public static func violations(
        of provider: ProviderDescriptor,
        request: CapabilityRequest,
        osVersion: OSVersion,
        jurisdictions: [Jurisdiction],
        config: PlaneConfig
    ) -> [RejectionReason] {
        // An empty jurisdiction list would otherwise approve everything (no loop iterations).
        guard !jurisdictions.isEmpty else { return [.noBindingJurisdiction] }
        var reasons: [RejectionReason] = []
        for jurisdiction in jurisdictions {
            if let offer = provider.offer(in: jurisdiction) {
                if !offer.capabilities.contains(request.capability) {
                    reasons.append(.capabilityUnsupported(in: jurisdiction))
                }
                if osVersion < offer.minimumOS {
                    reasons.append(.osTooOld(required: offer.minimumOS, actual: osVersion, in: jurisdiction))
                }
            } else {
                reasons.append(.notOffered(in: jurisdiction))
            }
            if !config.residency.permits(provider.processing, dataClass: request.dataClass, in: jurisdiction) {
                reasons.append(.residency(location: provider.processing, dataClass: request.dataClass, in: jurisdiction))
            }
            if let kill = config.killSwitch(for: jurisdiction, providerID: provider.id, capability: request.capability) {
                reasons.append(.killSwitched(kill))
            }
        }
        // A wildcard-jurisdiction kill switch matches once per binding jurisdiction;
        // report each distinct reason once, in first-seen order.
        var seen = Set<RejectionReason>()
        return reasons.filter { seen.insert($0).inserted }
    }
}

/// Default resolver: filter by hard constraints, then soft constraints, then rank.
///
/// Ranking (deterministic, total): preference index of kind → worst-jurisdiction
/// parity score, descending (unmeasured ranks below measured) → relative cost → id.
public struct PolicyEngine: CapabilityResolving {
    public init() {}

    public func resolve(_ input: ResolutionInput) -> Decision {
        var eligible: [(provider: ProviderDescriptor, parity: Double?)] = []
        var rejections: [Rejection] = []

        // Duplicate ids would make adapter lookup ambiguous; first registration wins.
        var seen = Set<String>()
        for provider in input.providers where seen.insert(provider.id).inserted {
            var reasons = HardConstraints.violations(
                of: provider, request: input.request, osVersion: input.context.osVersion,
                jurisdictions: input.jurisdictions, config: input.config)

            if provider.requiresNetwork && !input.context.isOnline { reasons.append(.offline) }
            if case .open = input.health[provider.id] ?? .healthy { reasons.append(.circuitOpen) }

            var worstScore: Double?
            for jurisdiction in input.jurisdictions {
                guard let score = input.parity.score(jurisdiction: jurisdiction, capability: input.request.capability,
                                                     providerID: provider.id) else { continue }
                worstScore = min(worstScore ?? score, score)
                if score < input.config.parityFloor {
                    reasons.append(.belowParityFloor(score: score, floor: input.config.parityFloor, in: jurisdiction))
                }
            }

            if reasons.isEmpty {
                eligible.append((provider, worstScore))
            } else {
                rejections.append(Rejection(providerID: provider.id, reasons: reasons))
            }
        }

        let preference = input.config.preference
        func rank(_ kind: ProviderKind) -> Int { preference.firstIndex(of: kind) ?? preference.count }

        let ranked = eligible.sorted { a, b in
            let ra = rank(a.provider.kind), rb = rank(b.provider.kind)
            if ra != rb { return ra < rb }
            // Measured beats unmeasured; higher score beats lower. Scores are finite (ledger invariant).
            let pa = a.parity ?? -1, pb = b.parity ?? -1
            if pa != pb { return pa > pb }
            if a.provider.relativeCost != b.provider.relativeCost { return a.provider.relativeCost < b.provider.relativeCost }
            return a.provider.id < b.provider.id
        }

        return Decision(
            capability: input.request.capability,
            dataClass: input.request.dataClass,
            jurisdictions: input.jurisdictions,
            chain: ranked.prefix(input.config.maxAttempts).map(\.provider),
            rejections: rejections.sorted { $0.providerID < $1.providerID },
            configVersion: input.config.version)
    }
}

/// Independent re-check of a resolver's chain against hard constraints.
///
/// Defense in depth: resolvers are pluggable (A/B ranking experiments, a server-driven
/// resolver, a vendor SDK), but residency and kill switches are not negotiable. The
/// plane runs every chain through this before it sends a byte anywhere.
///
/// The audit is only as good as the descriptors it is given: pass the descriptors you
/// *registered*, never ones a resolver returned. `CapabilityPlane` maps every id in a
/// resolver's chain back to its registered descriptor before calling this.
public enum ResidencyAuditor {
    public struct Finding: Sendable, Hashable {
        public let providerID: String
        public let reasons: [RejectionReason]

        public init(providerID: String, reasons: [RejectionReason]) {
            self.providerID = providerID
            self.reasons = reasons
        }
    }

    /// Splits `chain` into providers that pass every hard constraint (order preserved)
    /// and findings for those that do not.
    public static func audit(
        chain: [ProviderDescriptor],
        request: CapabilityRequest,
        context: RegionContext,
        jurisdictions: [Jurisdiction],
        config: PlaneConfig
    ) -> (approved: [ProviderDescriptor], findings: [Finding]) {
        var approved: [ProviderDescriptor] = []
        var findings: [Finding] = []
        for provider in chain {
            let reasons = HardConstraints.violations(
                of: provider, request: request, osVersion: context.osVersion,
                jurisdictions: jurisdictions, config: config)
            if reasons.isEmpty { approved.append(provider) } else { findings.append(Finding(providerID: provider.id, reasons: reasons)) }
        }
        return (approved, findings)
    }
}
