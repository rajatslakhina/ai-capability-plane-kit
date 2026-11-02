import XCTest
@testable import CapabilityPlane

final class PolicyEngineTests: XCTestCase {

    private func ids(_ d: Decision) -> [String] { d.chain.map(\.id) }
    private func reasons(_ d: Decision, _ id: String) -> [RejectionReason] {
        d.rejections.first(where: { $0.providerID == id })?.reasons ?? []
    }

    func testUSPersonalPrefersOnDeviceThenUSCloud() {
        let d = engineDecision(Fleet.context("US"))
        XCTAssertEqual(ids(d), ["apple.ondevice", "claude.us"])
        XCTAssertTrue(reasons(d, "regional.eu").contains(.notOffered(in: .unitedStates)))
        XCTAssertTrue(reasons(d, "regional.eu").contains(
            .residency(location: .hostedIn(.europeanUnion), dataClass: .personal, in: .unitedStates)))
    }

    func testChinaBefore27_3UsesRegionalCloudOnly() {
        let d = engineDecision(Fleet.context("CN", os: OSVersion(27, 2)))
        XCTAssertEqual(ids(d), ["regional.cn"])
        XCTAssertTrue(reasons(d, "apple.ondevice").contains(
            .osTooOld(required: OSVersion(27, 3), actual: OSVersion(27, 2), in: .china)))
        let claude = reasons(d, "claude.us")
        XCTAssertTrue(claude.contains(.notOffered(in: .china)))
        XCTAssertTrue(claude.contains(.residency(location: .hostedIn(.unitedStates), dataClass: .personal, in: .china)))
    }

    func testChinaOn27_3PrefersOnDeviceWithRegionalFailover() {
        let d = engineDecision(Fleet.context("CN", os: OSVersion(27, 3)))
        XCTAssertEqual(ids(d), ["apple.ondevice", "regional.cn"])
    }

    func testChinaAssistantHasNoEligibleProvider() {
        let d = engineDecision(Fleet.context("CN", os: OSVersion(27, 3)), Fleet.request(.assistant))
        XCTAssertTrue(d.chain.isEmpty)
        XCTAssertTrue(reasons(d, "apple.ondevice").contains(.capabilityUnsupported(in: .china)))
        XCTAssertTrue(reasons(d, "regional.cn").contains(.capabilityUnsupported(in: .china)))
    }

    func testStorefrontAndRegionDisagreeStrictestWins() {
        // US account, device in China, iOS 27.2: every provider fails at least one jurisdiction.
        let traveller = Fleet.context("US", "CN", os: OSVersion(27, 2))
        XCTAssertEqual(Fleet.map.bindingJurisdictions(for: traveller), [.china, .unitedStates])
        let d = engineDecision(traveller)
        XCTAssertTrue(d.chain.isEmpty, "got \(ids(d))")
        XCTAssertTrue(reasons(d, "regional.cn").contains(.notOffered(in: .unitedStates)))
        // On 27.3 only on-device satisfies both rule sets.
        XCTAssertEqual(ids(engineDecision(Fleet.context("US", "CN", os: OSVersion(27, 3)))), ["apple.ondevice"])
    }

    func testSensitiveDataNeverLeavesDevice() {
        // Exact, not allSatisfy: an empty chain would satisfy "all on-device" vacuously.
        for store in ["US", "DE", "CN", "BR"] {
            let d = engineDecision(Fleet.context(store, os: OSVersion(27, 3)), Fleet.request(.summarize, .sensitive))
            XCTAssertEqual(ids(d), ["apple.ondevice"], store)
        }
    }

    func testUnknownCountryFallsBackToRestOfWorldRules() {
        let d = engineDecision(Fleet.context("BR"))
        XCTAssertEqual(d.jurisdictions, [.restOfWorld])
        XCTAssertEqual(ids(d), ["apple.ondevice", "claude.us"])
    }

    func testMissingResidencyRuleFailsClosed() {
        let bare = PlaneConfig(version: 1, residency: ResidencyPolicy(rules: [:]))
        let d = engineDecision(Fleet.context("US"), Fleet.request(.summarize, .publicContent), config: bare)
        XCTAssertEqual(ids(d), ["apple.ondevice"])
    }

    func testEUPublicCanUseEitherCloudButPersonalStaysInEU() {
        XCTAssertEqual(ids(engineDecision(Fleet.context("DE"), Fleet.request(.summarize, .publicContent))),
                       ["apple.ondevice", "regional.eu", "claude.us"])
        XCTAssertEqual(ids(engineDecision(Fleet.context("DE"))), ["apple.ondevice", "regional.eu"])
    }

    func testKillSwitchRemovesProviderAndWildcardsMatch() {
        let kill = KillSwitch(jurisdiction: .unitedStates, providerID: "apple.ondevice")
        let d = engineDecision(Fleet.context("US"), config: Fleet.config(kills: [kill]))
        XCTAssertEqual(ids(d), ["claude.us"])
        XCTAssertTrue(reasons(d, "apple.ondevice").contains(.killSwitched(kill)))

        let capabilityWide = KillSwitch(capability: .summarize)
        XCTAssertTrue(engineDecision(Fleet.context("DE"), config: Fleet.config(kills: [capabilityWide])).chain.isEmpty)
        XCTAssertTrue(capabilityWide.matches(jurisdiction: .china, providerID: "x", capability: .summarize))
        XCTAssertFalse(capabilityWide.matches(jurisdiction: .china, providerID: "x", capability: .translate))
        XCTAssertFalse(kill.matches(jurisdiction: .china, providerID: "apple.ondevice", capability: .summarize))
    }

    func testOfflineRejectsCloudOnly() {
        let d = engineDecision(Fleet.context("US", online: false))
        XCTAssertEqual(ids(d), ["apple.ondevice"])
        XCTAssertEqual(reasons(d, "claude.us"), [.offline])
    }

    func testOpenCircuitIsSoftRejection() {
        let d = engineDecision(Fleet.context("US"), health: ["apple.ondevice": .open])
        XCTAssertEqual(ids(d), ["claude.us"])
        XCTAssertEqual(reasons(d, "apple.ondevice"), [.circuitOpen])
        XCTAssertFalse(RejectionReason.circuitOpen.isHard)
        // probeAllowed is still eligible.
        XCTAssertEqual(ids(engineDecision(Fleet.context("US"), health: ["apple.ondevice": .probeAllowed])),
                       ["apple.ondevice", "claude.us"])
    }

    func testParityFloorRejectsLowQualityProvider() {
        var parity = ParityLedger()
        parity.record(0.55, jurisdiction: .china, capability: .summarize, providerID: "regional.cn")
        let d = engineDecision(Fleet.context("CN", os: OSVersion(27, 3)), config: Fleet.config(floor: 0.7), parity: parity)
        XCTAssertEqual(ids(d), ["apple.ondevice"])
        XCTAssertEqual(reasons(d, "regional.cn"), [.belowParityFloor(score: 0.55, floor: 0.7, in: .china)])
    }

    func testParityRanksWithinKindAndMeasuredBeatsUnmeasured() {
        // Two same-kind providers in EU public: rank by measured parity, not cost or id.
        let a = ProviderDescriptor(id: "a", displayName: "A", kind: .regionalCloud, processing: .hostedIn(.europeanUnion),
                                   defaultOffer: ProviderOffer(capabilities: Fleet.all), requiresNetwork: true, relativeCost: 1)
        let b = ProviderDescriptor(id: "b", displayName: "B", kind: .regionalCloud, processing: .hostedIn(.europeanUnion),
                                   defaultOffer: ProviderOffer(capabilities: Fleet.all), requiresNetwork: true, relativeCost: 9)
        var parity = ParityLedger()
        parity.record(0.9, jurisdiction: .europeanUnion, capability: .summarize, providerID: "b")
        let input = ResolutionInput(request: Fleet.request(.summarize, .publicContent), context: Fleet.context("DE"),
                                    jurisdictions: [.europeanUnion], providers: [a, b], config: Fleet.config(),
                                    parity: parity, health: [:])
        XCTAssertEqual(PolicyEngine().resolve(input).chain.map(\.id), ["b", "a"])
        // Without parity data, cost decides.
        let noParity = ResolutionInput(request: input.request, context: input.context, jurisdictions: input.jurisdictions,
                                       providers: [b, a], config: Fleet.config(), parity: ParityLedger(), health: [:])
        XCTAssertEqual(PolicyEngine().resolve(noParity).chain.map(\.id), ["a", "b"])
    }

    func testChainIsCappedAtMaxAttemptsAndDuplicatesIgnored() {
        let d = engineDecision(Fleet.context("DE"), Fleet.request(.summarize, .publicContent), config: Fleet.config(maxAttempts: 1))
        XCTAssertEqual(ids(d), ["apple.ondevice"])
        let dup = ResolutionInput(request: Fleet.request(), context: Fleet.context("US"), jurisdictions: [.unitedStates],
                                  providers: [Fleet.apple, Fleet.apple, Fleet.claude], config: Fleet.config(),
                                  parity: ParityLedger(), health: [:])
        XCTAssertEqual(PolicyEngine().resolve(dup).chain.map(\.id), ["apple.ondevice", "claude.us"])
    }

    func testResolutionIsDeterministicUnderInputOrder() {
        let forward = engineDecision(Fleet.context("DE"), Fleet.request(.summarize, .publicContent))
        let input = ResolutionInput(request: Fleet.request(.summarize, .publicContent), context: Fleet.context("DE"),
                                    jurisdictions: [.europeanUnion], providers: Fleet.descriptors.reversed(),
                                    config: Fleet.config(), parity: ParityLedger(), health: [:])
        let reversed = PolicyEngine().resolve(input)
        XCTAssertEqual(forward.chain, reversed.chain)
        XCTAssertEqual(forward.rejections, reversed.rejections)
    }

    func testConfigClampsHostileValues() {
        let c = PlaneConfig(version: 1, residency: Fleet.residency, parityFloor: .nan, maxAttempts: -5)
        XCTAssertEqual(c.parityFloor, 0)
        XCTAssertEqual(c.maxAttempts, 1)
        XCTAssertEqual(PlaneConfig(version: 1, residency: Fleet.residency, parityFloor: 7, maxAttempts: .max).maxAttempts, 8)
        XCTAssertEqual(PlaneConfig(version: 1, residency: Fleet.residency, parityFloor: 7).parityFloor, 1)
    }

    // MARK: Invariant check, proven non-vacuous

    /// Counts every hard-constraint violation a resolver emits across a grid of
    /// regions, OS versions, capabilities and data classes.
    private func hardViolations(of resolver: any CapabilityResolving) -> Int {
        gridScan(resolver).violations
    }

    private func gridScan(_ resolver: any CapabilityResolving) -> (violations: Int, nonEmpty: Int, cases: Int) {
        var total = 0, nonEmpty = 0, cases = 0
        for store in ["US", "CN", "DE", "BR"] {
            for region in ["US", "CN", "DE"] {
                for os in [OSVersion(27, 2), OSVersion(27, 3)] {
                    for capability in Capability.allCases {
                        for dataClass in DataClass.allCases {
                            let context = Fleet.context(store, region, os: os)
                            let request = Fleet.request(capability, dataClass)
                            let decision = engineDecision(context, request, resolver: resolver)
                            cases += 1
                            if !decision.chain.isEmpty { nonEmpty += 1 }
                            for provider in decision.chain {
                                total += HardConstraints.violations(
                                    of: provider, request: request, osVersion: os,
                                    jurisdictions: Fleet.map.bindingJurisdictions(for: context),
                                    config: Fleet.config()).count
                            }
                        }
                    }
                }
            }
        }
        return (total, nonEmpty, cases)
    }

    func testPolicyEngineNeverEmitsAHardViolation() {
        let scan = gridScan(PolicyEngine())
        XCTAssertEqual(scan.cases, 360)
        XCTAssertEqual(scan.violations, 0)
        // Guards against the vacuous pass: a resolver that returns [] everywhere also has
        // zero violations. The engine must actually serve a substantial part of the grid.
        XCTAssertGreaterThan(scan.nonEmpty, 100)
    }

    func testGridGuardCatchesAnAlwaysEmptyResolver() {
        struct RejectsEverything: CapabilityResolving {
            func resolve(_ input: ResolutionInput) -> Decision {
                Decision(capability: input.request.capability, dataClass: input.request.dataClass,
                         jurisdictions: input.jurisdictions, chain: [], rejections: [], configVersion: 0)
            }
        }
        let scan = gridScan(RejectsEverything())
        XCTAssertEqual(scan.violations, 0)
        XCTAssertEqual(scan.nonEmpty, 0, "so the nonEmpty > 100 assertion above is what catches it")
    }

    func testWildcardKillSwitchIsReportedOnce() {
        let kill = KillSwitch(providerID: "apple.ondevice")
        let d = engineDecision(Fleet.context("US", "CN", os: OSVersion(27, 3)), config: Fleet.config(kills: [kill]))
        XCTAssertEqual(reasons(d, "apple.ondevice").filter { $0 == .killSwitched(kill) }.count, 1)
    }

    func testKillToggleHelpers() {
        let config = Fleet.config(kills: [KillSwitch(jurisdiction: .unitedStates, providerID: "apple.ondevice")])
        XCTAssertTrue(config.isProviderKilled("apple.ondevice", in: [.unitedStates]))
        XCTAssertFalse(config.isProviderKilled("apple.ondevice", in: [.europeanUnion]), "scoped switch does not follow region changes")
        XCTAssertTrue(Fleet.config(kills: [KillSwitch(providerID: "x")]).isProviderKilled("x", in: [.china]))
        // Toggle in EU: not killed there, so add an EU switch and keep the US one.
        XCTAssertEqual(config.togglingKill("apple.ondevice", in: [.europeanUnion]).count, 2)
        // Toggle in US: killed, so remove every switch for the provider, even other scopes.
        let twoScopes = Fleet.config(kills: [KillSwitch(jurisdiction: .unitedStates, providerID: "apple.ondevice"),
                                             KillSwitch(jurisdiction: .china, providerID: "apple.ondevice"),
                                             KillSwitch(providerID: "claude.us")])
        XCTAssertEqual(twoScopes.togglingKill("apple.ondevice", in: [.unitedStates]), [KillSwitch(providerID: "claude.us")])
    }

    func testInvariantCheckCatchesABrokenResolver() {
        // If this ever returns 0, the check above is vacuous.
        XCTAssertGreaterThan(hardViolations(of: IgnoresPolicyResolver()), 100)
    }
}
