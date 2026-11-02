// Policy: residency rules, kill switches, preferences, all in one versioned config.

/// Which processing locations may receive a payload of a given class, per jurisdiction.
///
/// Fail-closed: a (jurisdiction, data class) pair with no rule allows **on-device only**.
/// On-device processing is always allowed, because no payload crosses a boundary.
public struct ResidencyPolicy: Sendable, Hashable {
    private let rules: [Jurisdiction: [DataClass: Set<ProcessingLocation>]]

    public init(rules: [Jurisdiction: [DataClass: Set<ProcessingLocation>]]) {
        self.rules = rules
    }

    public func permits(_ location: ProcessingLocation, dataClass: DataClass, in jurisdiction: Jurisdiction) -> Bool {
        if location == .onDevice { return true }
        guard let allowed = rules[jurisdiction]?[dataClass] else { return false }
        return allowed.contains(location)
    }
}

/// A remotely-flippable switch. Each nil field is a wildcard, so
/// `KillSwitch(jurisdiction: .china, providerID: nil, capability: .assistant)`
/// disables the assistant capability for every provider in China.
public struct KillSwitch: Sendable, Hashable, CustomStringConvertible {
    public let jurisdiction: Jurisdiction?
    public let providerID: String?
    public let capability: Capability?

    public init(jurisdiction: Jurisdiction? = nil, providerID: String? = nil, capability: Capability? = nil) {
        self.jurisdiction = jurisdiction
        self.providerID = providerID
        self.capability = capability
    }

    public func matches(jurisdiction j: Jurisdiction, providerID p: String, capability c: Capability) -> Bool {
        (jurisdiction.map { $0 == j } ?? true)
            && (providerID.map { $0 == p } ?? true)
            && (capability.map { $0 == c } ?? true)
    }

    public var description: String {
        "kill[\(jurisdiction?.rawValue ?? "*")/\(providerID ?? "*")/\(capability?.rawValue ?? "*")]"
    }
}

/// The complete remotely-delivered policy. Applied atomically and only if its
/// version is strictly newer than the current one, so a delayed or replayed
/// payload can never silently re-enable a provider that a newer config killed.
public struct PlaneConfig: Sendable, Hashable {
    public let version: UInt64
    public let residency: ResidencyPolicy
    public let killSwitches: Set<KillSwitch>
    /// Providers whose measured eval score in a binding jurisdiction is below this
    /// floor are rejected. Clamped to 0...1; NaN becomes 0.
    public let parityFloor: Double
    /// Ranking order by provider kind. Kinds not listed rank last.
    public let preference: [ProviderKind]
    /// Upper bound on providers tried for one request. Clamped to 1...8.
    public let maxAttempts: Int

    public init(
        version: UInt64,
        residency: ResidencyPolicy,
        killSwitches: Set<KillSwitch> = [],
        parityFloor: Double = 0,
        preference: [ProviderKind] = [.onDevice, .regionalCloud, .frontierCloud],
        maxAttempts: Int = 3
    ) {
        self.version = version
        self.residency = residency
        self.killSwitches = killSwitches
        self.parityFloor = parityFloor.isNaN ? 0 : min(1, max(0, parityFloor))
        self.preference = preference
        self.maxAttempts = min(8, max(1, maxAttempts))
    }

    public func killSwitch(for jurisdiction: Jurisdiction, providerID: String, capability: Capability) -> KillSwitch? {
        // Sorted so the reported switch is deterministic when several match.
        killSwitches
            .filter { $0.matches(jurisdiction: jurisdiction, providerID: providerID, capability: capability) }
            .sorted { $0.description < $1.description }
            .first
    }

    /// True if any kill switch for this provider applies in at least one of `jurisdictions`
    /// (a switch with a nil jurisdiction applies everywhere).
    public func isProviderKilled(_ providerID: String, in jurisdictions: [Jurisdiction]) -> Bool {
        killSwitches.contains { k in
            k.providerID == providerID && (k.jurisdiction.map(jurisdictions.contains) ?? true)
        }
    }

    /// The kill-switch set after toggling one provider for the given jurisdictions:
    /// if it is killed anywhere in them, every switch for that provider is removed
    /// (including switches scoped to jurisdictions that no longer bind); otherwise a
    /// provider-wide switch is added per jurisdiction.
    public func togglingKill(_ providerID: String, in jurisdictions: [Jurisdiction]) -> Set<KillSwitch> {
        if isProviderKilled(providerID, in: jurisdictions) {
            return killSwitches.filter { $0.providerID != providerID }
        }
        return killSwitches.union(jurisdictions.map { KillSwitch(jurisdiction: $0, providerID: providerID) })
    }

    /// Returns a copy with a new version and kill-switch set (the common remote update).
    public func with(version: UInt64, killSwitches: Set<KillSwitch>) -> PlaneConfig {
        PlaneConfig(version: version, residency: residency, killSwitches: killSwitches,
                    parityFloor: parityFloor, preference: preference, maxAttempts: maxAttempts)
    }
}

/// Per-region eval scores, so a quality gap between markets is a number someone
/// owns instead of an anecdote from a support ticket.
public struct ParityLedger: Sendable, Hashable {
    public struct Key: Hashable, Sendable {
        public let jurisdiction: Jurisdiction
        public let capability: Capability
        public let providerID: String
    }

    public private(set) var scores: [Key: Double] = [:]
    /// Hard cap on distinct keys. Updates to existing keys are always accepted; new keys
    /// beyond the cap are refused, so a caller feeding arbitrary IDs cannot grow it forever.
    public let maxEntries: Int

    public init(maxEntries: Int = 4096) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Records a score in 0...1. Non-finite or out-of-range values are rejected,
    /// because a NaN in a ranking comparator breaks strict weak ordering.
    @discardableResult
    public mutating func record(_ score: Double, jurisdiction: Jurisdiction, capability: Capability, providerID: String) -> Bool {
        guard score.isFinite, (0...1).contains(score) else { return false }
        let key = Key(jurisdiction: jurisdiction, capability: capability, providerID: providerID)
        guard scores[key] != nil || scores.count < maxEntries else { return false }
        scores[key] = score
        return true
    }

    public func score(jurisdiction: Jurisdiction, capability: Capability, providerID: String) -> Double? {
        scores[Key(jurisdiction: jurisdiction, capability: capability, providerID: providerID)]
    }

    /// For one capability: best score available in each jurisdiction, and the spread
    /// between the best and worst market. Nil when fewer than two jurisdictions are measured.
    public func parityGap(for capability: Capability) -> ParityGap? {
        var best: [Jurisdiction: Double] = [:]
        for (key, value) in scores where key.capability == capability {
            best[key.jurisdiction] = max(best[key.jurisdiction] ?? 0, value)
        }
        guard best.count >= 2,
              let top = best.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }),
              let bottom = best.min(by: { ($0.value, $0.key) < ($1.value, $1.key) })
        else { return nil }
        return ParityGap(capability: capability, best: top.key, bestScore: top.value,
                         worst: bottom.key, worstScore: bottom.value)
    }
}

public struct ParityGap: Sendable, Hashable {
    public let capability: Capability
    public let best: Jurisdiction
    public let bestScore: Double
    public let worst: Jurisdiction
    public let worstScore: Double
    public var spread: Double { bestScore - worstScore }
}
