import Foundation

// The plane: the only thing features talk to.

/// Why a request ended in the no-AI fallback instead of a provider.
public enum DegradeReason: Sendable, Hashable, CustomStringConvertible {
    /// No provider passed policy for this region/OS/data class.
    case noEligibleProvider
    /// Every eligible provider was tried and failed (or was discarded).
    case allProvidersFailed
    case cancelled

    public var description: String {
        switch self {
        case .noEligibleProvider: return "no eligible provider"
        case .allProvidersFailed: return "all eligible providers failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// One dispatch attempt, for the trace.
public struct Attempt: Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        case served
        case failed
        case missingAdapter
        /// The provider answered, but policy changed while the call was in flight and
        /// the provider is no longer allowed. The answer is dropped. (The payload has
        /// already left; the plane cannot un-send it, but it can refuse to use it.)
        case discardedAfterPolicyChange
        /// The request was cancelled while this provider call was in flight.
        case cancelled
    }
    public let providerID: String
    public let result: Result

    public init(providerID: String, result: Result) {
        self.providerID = providerID
        self.result = result
    }
}

public struct CapabilityOutcome: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case served(providerID: String, output: String)
        case degraded(output: String, reason: DegradeReason)
    }
    public let kind: Kind
    public let attempts: [Attempt]
    /// The decision made for the final attempt (or the only one, if nothing dispatched).
    /// Its chain holds the plane's *registered* descriptors, never a resolver's copies.
    public let decision: Decision
    /// Providers the resolver ranked but the plane refused to dispatch: hard-rule
    /// violations found by `ResidencyAuditor`, and providers skipped because their
    /// circuit was open (`.circuitOpen`, a soft reason, so `isHard` tells them apart).
    public let auditFindings: [ResidencyAuditor.Finding]

    public init(kind: Kind, attempts: [Attempt], decision: Decision, auditFindings: [ResidencyAuditor.Finding] = []) {
        self.kind = kind
        self.attempts = attempts
        self.decision = decision
        self.auditFindings = auditFindings
    }
}

/// One internally consistent view of the plane, read in a single actor hop. UIs should
/// render from this instead of reading several properties across several `await`s,
/// which can interleave with other updates and mix states.
public struct PlaneSnapshot: Sendable {
    public let context: RegionContext
    public let jurisdictions: [Jurisdiction]
    public let contextGeneration: UInt64
    public let providers: [ProviderDescriptor]
    public let decision: Decision
    public let config: PlaneConfig
    public let parity: ParityLedger
    /// Providers with a kill switch that applies in `jurisdictions`.
    public let killedProviderIDs: Set<String>
}

public enum ConfigError: Error, Sendable, Equatable {
    /// Configs are applied only if strictly newer. Replays and delayed deliveries are refused.
    case stale(offered: UInt64, current: UInt64)
}

/// A region-aware AI capability plane.
///
/// Concurrency contract (actor reentrancy): every attempt takes a **fresh** snapshot
/// of context, config and health *after* any previous `await`. Nothing computed
/// before a suspension point is trusted after it. When an adapter returns, the plane
/// re-audits that provider against the *current* context and config before using
/// the answer.
///
/// Trust boundary: a resolver only *chooses and orders* providers. The auditor always
/// checks the descriptor registered with the plane for each id, so a resolver that
/// returns an altered copy (say, a US-hosted provider relabelled as on-device) cannot
/// change what gets checked.
///
/// Deadlines: the plane imposes no per-attempt timeout. Structured concurrency cannot
/// abandon a child task that ignores cancellation, so a plane-side timer would either
/// still wait for a hung adapter or leak it. Adapters own their deadlines (for example
/// `URLRequest.timeoutInterval`) and throw `ProviderError.timedOut`, which the plane
/// treats as a failure: breaker and failover engage. Cancelling the caller's task
/// still ends the request.
public actor CapabilityPlane {
    public private(set) var context: RegionContext
    public private(set) var config: PlaneConfig
    public private(set) var parity: ParityLedger
    /// Bumped whenever the binding jurisdictions, the OS version or connectivity change.
    /// In-flight answers are re-audited against hard rules when the generation moved.
    public private(set) var contextGeneration: UInt64 = 0

    private let jurisdictionMap: JurisdictionMap
    private let adapters: [String: any ProviderAdapter]
    private let descriptors: [ProviderDescriptor]
    /// The registered descriptor for each id: the only descriptors the auditor trusts.
    private let descriptorsByID: [String: ProviderDescriptor]
    private let resolver: any CapabilityResolving
    private let clock: any PlaneClock
    private let telemetry: any TelemetrySink
    private var health: HealthBoard

    public init(
        adapters: [any ProviderAdapter],
        config: PlaneConfig,
        context: RegionContext,
        jurisdictionMap: JurisdictionMap,
        parity: ParityLedger = ParityLedger(),
        health: HealthBoard = HealthBoard(),
        resolver: any CapabilityResolving = PolicyEngine(),
        clock: any PlaneClock = SystemPlaneClock(),
        telemetry: any TelemetrySink = NullTelemetry()
    ) {
        var byID: [String: any ProviderAdapter] = [:]
        var ordered: [ProviderDescriptor] = []
        for adapter in adapters where byID[adapter.descriptor.id] == nil {   // first registration wins
            byID[adapter.descriptor.id] = adapter
            ordered.append(adapter.descriptor)
        }
        self.adapters = byID
        self.descriptors = ordered
        self.descriptorsByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })   // ids unique by construction
        self.config = config
        self.context = context
        self.jurisdictionMap = jurisdictionMap
        self.parity = parity
        self.health = health
        self.resolver = resolver
        self.clock = clock
        self.telemetry = telemetry
    }

    public var jurisdictions: [Jurisdiction] { jurisdictionMap.bindingJurisdictions(for: context) }
    public var providers: [ProviderDescriptor] { descriptors }

    // MARK: Inputs that change at runtime

    /// Updates the region context. Returns true if anything policy-relevant changed
    /// (binding jurisdictions, OS version or connectivity), in which case the
    /// generation is bumped and in-flight answers will be re-audited on return.
    @discardableResult
    public func updateContext(_ newContext: RegionContext) -> Bool {
        let before = (jurisdictionMap.bindingJurisdictions(for: context), context.osVersion, context.isOnline)
        context = newContext
        let after = (jurisdictionMap.bindingJurisdictions(for: newContext), newContext.osVersion, newContext.isOnline)
        guard before != after else { return false }
        contextGeneration = contextGeneration.saturatingIncrement()
        telemetry.record(.contextChanged(generation: contextGeneration, jurisdictions: after.0))
        return true
    }

    /// Applies a remote config if, and only if, it is strictly newer.
    ///
    /// Versions are meant to be counters far below `UInt64.max`. A config at
    /// `UInt64.max` can never be superseded (and `updateKillSwitches` becomes a no-op),
    /// so a publisher must never emit one; treat it as an operational error upstream.
    public func apply(_ newConfig: PlaneConfig) throws(ConfigError) {
        guard newConfig.version > config.version else {
            telemetry.record(.configRejected(offered: newConfig.version, current: config.version))
            throw .stale(offered: newConfig.version, current: config.version)
        }
        config = newConfig
        telemetry.record(.configApplied(version: newConfig.version))
    }

    /// Atomic read-modify-write of the kill-switch set: the transform runs inside the
    /// actor with no suspension point, and the result is applied as version + 1. Two
    /// concurrent callers therefore compose instead of the second failing as stale.
    @discardableResult
    public func updateKillSwitches(_ transform: @Sendable (PlaneConfig) -> Set<KillSwitch>) -> UInt64 {
        let next = config.with(version: config.version.saturatingIncrement(), killSwitches: transform(config))
        // Cannot be stale (strictly newer by construction) unless version is saturated.
        guard next.version > config.version else { return config.version }
        config = next
        telemetry.record(.configApplied(version: next.version))
        return next.version
    }

    /// Flips a provider's kill switch for the jurisdictions binding *at this instant*,
    /// in one atomic step: the scope and the update cannot interleave with a context
    /// change. Returns the new config version.
    @discardableResult
    public func toggleProviderKill(_ providerID: String) -> UInt64 {
        let scope = jurisdictions
        return updateKillSwitches { $0.togglingKill(providerID, in: scope) }
    }

    @discardableResult
    public func recordParity(_ score: Double, jurisdiction: Jurisdiction, capability: Capability, providerID: String) -> Bool {
        parity.record(score, jurisdiction: jurisdiction, capability: capability, providerID: providerID)
    }

    public func healthVerdict(for providerID: String) -> HealthVerdict {
        health.verdict(for: providerID, now: clock.now())
    }

    // MARK: Resolution

    /// What would happen for this request right now, without dispatching anything.
    public func preview(_ request: CapabilityRequest) -> Decision {
        snapshotDecision(for: request, excluding: []).decision
    }

    /// Everything a UI needs, read atomically (one actor hop, no suspension point).
    public func snapshot(for request: CapabilityRequest) -> PlaneSnapshot {
        let binding = jurisdictions
        return PlaneSnapshot(
            context: context, jurisdictions: binding, contextGeneration: contextGeneration,
            providers: descriptors, decision: preview(request), config: config, parity: parity,
            killedProviderIDs: Set(descriptors.map(\.id).filter { config.isProviderKilled($0, in: binding) }))
    }

    private func snapshotDecision(for request: CapabilityRequest, excluding tried: Set<String>)
        -> (decision: Decision, approved: [ProviderDescriptor], findings: [ResidencyAuditor.Finding]) {
        let now = clock.now()
        let binding = jurisdictions
        var verdicts: [String: HealthVerdict] = [:]
        for d in descriptors { verdicts[d.id] = health.verdict(for: d.id, now: now) }
        let input = ResolutionInput(
            request: request, context: context, jurisdictions: binding,
            providers: descriptors.filter { !tried.contains($0.id) },
            config: config, parity: parity, health: verdicts)
        let proposed = resolver.resolve(input)
        // Trust boundary: audit, report and dispatch the *registered* descriptor for each id,
        // never the resolver's copy. Unknown ids keep the resolver's descriptor; they have no
        // adapter, so they can only ever end as `.missingAdapter`.
        let chain = proposed.chain.map { descriptorsByID[$0.id] ?? $0 }
        let decision = Decision(capability: proposed.capability, dataClass: proposed.dataClass,
                                jurisdictions: proposed.jurisdictions, chain: chain,
                                rejections: proposed.rejections, configVersion: proposed.configVersion)
        let audit = ResidencyAuditor.audit(chain: chain, request: request, context: context,
                                           jurisdictions: binding, config: config)
        return (decision, audit.approved, audit.findings)
    }

    // MARK: Dispatch

    public func perform(_ request: CapabilityRequest) async -> CapabilityOutcome {
        var attempts: [Attempt] = []
        var tried = Set<String>()
        var allFindings: [ResidencyAuditor.Finding] = []
        var lastDecision = preview(request)
        var dispatched = false

        // Bounded twice over: at most `maxAttempts` dispatches, and a hard iteration cap
        // so a resolver that keeps inventing unregistered providers cannot spin us forever.
        var budget = config.maxAttempts
        var iterations = 0
        let iterationCap = descriptors.count.saturatingAdd(budget).saturatingAdd(1)
        while budget > 0 && iterations < iterationCap {
            iterations += 1
            if Task.isCancelled {
                return finishDegraded(request, .cancelled, attempts, lastDecision, allFindings)
            }

            // Fresh snapshot every iteration: never reuse state from before an `await`.
            let snapshot = snapshotDecision(for: request, excluding: tried)
            lastDecision = snapshot.decision
            for finding in snapshot.findings where !allFindings.contains(finding) {
                allFindings.append(finding)
                telemetry.record(.auditBlocked(feature: request.featureID, providerID: finding.providerID, reasons: finding.reasons))
            }
            telemetry.record(.resolved(feature: request.featureID, capability: request.capability,
                                       jurisdictions: snapshot.decision.jurisdictions,
                                       chain: snapshot.approved.map(\.id), configVersion: snapshot.decision.configVersion))

            // Filter `tried` here too: a custom resolver may ignore the exclusion list. The
            // breaker is enforced here as well, so a resolver that ignores `circuitOpen`
            // still cannot dispatch to an open breaker or alongside an in-flight probe.
            // Skipped providers are reported, not silently dropped.
            let now = clock.now()
            var picked: ProviderDescriptor?
            for candidate in snapshot.approved where !tried.contains(candidate.id) {
                if health.verdict(for: candidate.id, now: now) == .open {
                    let skipped = ResidencyAuditor.Finding(providerID: candidate.id, reasons: [.circuitOpen])
                    if !allFindings.contains(skipped) {
                        allFindings.append(skipped)
                        telemetry.record(.auditBlocked(feature: request.featureID, providerID: candidate.id, reasons: [.circuitOpen]))
                    }
                    continue
                }
                picked = candidate
                break
            }
            guard let next = picked else { break }
            tried.insert(next.id)

            guard let adapter = adapters[next.id] else {
                attempts.append(Attempt(providerID: next.id, result: .missingAdapter))
                continue   // does not consume dispatch budget; bounded by `iterationCap`
            }

            budget -= 1
            dispatched = true
            let isProbe = health.verdict(for: next.id, now: clock.now()) == .probeAllowed
            if isProbe { health.beginProbe(next.id) }
            // Captured after beginProbe so the probe's own transition is not "a change".
            let breakerEpoch = health.epoch(for: next.id)

            let generationAtDispatch = contextGeneration
            let configAtDispatch = config.version

            do {
                let output = try await adapter.execute(request)
                // ---- suspension point: context, config and health may all have changed ----
                // Ignored if the breaker changed phase meanwhile (e.g. another request opened it).
                health.recordSuccess(next.id, ifEpoch: breakerEpoch)

                if contextGeneration != generationAtDispatch || config.version != configAtDispatch {
                    let recheck = ResidencyAuditor.audit(chain: [next], request: request, context: context,
                                                         jurisdictions: jurisdictions, config: config)
                    if recheck.approved.isEmpty {
                        attempts.append(Attempt(providerID: next.id, result: .discardedAfterPolicyChange))
                        telemetry.record(.discardedAfterPolicyChange(feature: request.featureID, providerID: next.id))
                        continue
                    }
                }

                attempts.append(Attempt(providerID: next.id, result: .served))
                telemetry.record(.served(feature: request.featureID, providerID: next.id, attempt: attempts.count))
                return CapabilityOutcome(kind: .served(providerID: next.id, output: output),
                                         attempts: attempts, decision: lastDecision, auditFindings: allFindings)
            } catch {
                if Task.isCancelled {
                    if isProbe && health.epoch(for: next.id) == breakerEpoch { health.abandonProbe(next.id, now: clock.now()) }
                    attempts.append(Attempt(providerID: next.id, result: .cancelled))
                    return finishDegraded(request, .cancelled, attempts, lastDecision, allFindings)
                }
                health.recordFailure(next.id, now: clock.now(), ifEpoch: breakerEpoch)
                attempts.append(Attempt(providerID: next.id, result: .failed))
                telemetry.record(.providerFailed(feature: request.featureID, providerID: next.id))
            }
        }

        return finishDegraded(request, dispatched ? .allProvidersFailed : .noEligibleProvider,
                              attempts, lastDecision, allFindings)
    }

    private func finishDegraded(_ request: CapabilityRequest, _ reason: DegradeReason, _ attempts: [Attempt],
                                _ decision: Decision, _ findings: [ResidencyAuditor.Finding]) -> CapabilityOutcome {
        telemetry.record(.degraded(feature: request.featureID, capability: request.capability, reason: reason))
        return CapabilityOutcome(kind: .degraded(output: NoAIFallback.render(request), reason: reason),
                                 attempts: attempts, decision: decision, auditFindings: findings)
    }
}

/// Deterministic, local, non-AI behaviour for every capability. A feature must still
/// work (worse) when no provider is allowed; it must never fail open to a provider
/// that policy rejected.
public enum NoAIFallback {
    public static let summaryCharacterLimit = 140

    public static func render(_ request: CapabilityRequest) -> String {
        switch request.capability {
        case .summarize:
            let firstSentence = request.input.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
            let trimmed = firstSentence.trimmingCharacters(in: .whitespaces)
            return trimmed.count > summaryCharacterLimit ? String(trimmed.prefix(summaryCharacterLimit)) + "…" : trimmed
        case .translate, .rewrite:
            return request.input   // show the original rather than nothing
        case .extract:
            return ""
        case .assistant:
            return "The assistant isn't available here yet."
        }
    }
}
