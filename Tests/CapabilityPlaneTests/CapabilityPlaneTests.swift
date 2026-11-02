import XCTest
@testable import CapabilityPlane

final class CapabilityPlaneTests: XCTestCase {

    func testServesFromPrimary() async {
        let apple = CountingAdapter(Fleet.apple), claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, claude])
        let outcome = await plane.perform(Fleet.request())
        XCTAssertEqual(outcome.kind, .served(providerID: "apple.ondevice", output: "apple.ondevice:summarize"))
        XCTAssertEqual(outcome.attempts, [Attempt(providerID: "apple.ondevice", result: .served)])
        XCTAssertEqual(claude.calls, 0)
    }

    func testFailsOverWithinPolicyOnly() async {
        let apple = CountingAdapter(Fleet.apple, failing: true)
        let claude = CountingAdapter(Fleet.claude), cn = CountingAdapter(Fleet.regionalCN), eu = CountingAdapter(Fleet.regionalEU)
        let plane = makePlane([apple, cn, eu, claude])
        let outcome = await plane.perform(Fleet.request())
        XCTAssertEqual(outcome.kind, .served(providerID: "claude.us", output: "claude.us:summarize"))
        XCTAssertEqual(outcome.attempts.map(\.result), [.failed, .served])
        XCTAssertEqual(cn.calls + eu.calls, 0, "failover must never cross a residency boundary")
    }

    func testAllFailDegradesToNoAIFallback() async {
        let plane = makePlane([CountingAdapter(Fleet.apple, failing: true), CountingAdapter(Fleet.claude, failing: true)])
        let outcome = await plane.perform(Fleet.request(input: "First sentence here. Second one."))
        XCTAssertEqual(outcome.kind, .degraded(output: "First sentence here", reason: .allProvidersFailed))
        XCTAssertEqual(outcome.attempts.count, 2)
    }

    func testNoEligibleProviderDegradesWithoutDispatch() async {
        let apple = CountingAdapter(Fleet.apple), cn = CountingAdapter(Fleet.regionalCN)
        let plane = makePlane([apple, cn], context: Fleet.context("CN", os: OSVersion(27, 3)))
        let outcome = await plane.perform(Fleet.request(.assistant))
        XCTAssertEqual(outcome.kind, .degraded(output: NoAIFallback.render(Fleet.request(.assistant)), reason: .noEligibleProvider))
        XCTAssertEqual(apple.calls + cn.calls, 0)
    }

    func testMaxAttemptsBoundsDispatches() async {
        let apple = CountingAdapter(Fleet.apple, failing: true), claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, claude], config: Fleet.config(maxAttempts: 1))
        let outcome = await plane.perform(Fleet.request())
        XCTAssertEqual(outcome.kind, .degraded(output: "Quarterly report", reason: .allProvidersFailed))
        XCTAssertEqual(claude.calls, 0)
    }

    func testRegionChangeReroutesNextRequest() async {
        let apple = CountingAdapter(Fleet.apple), cn = CountingAdapter(Fleet.regionalCN), claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, cn, claude])
        let changed = await plane.updateContext(Fleet.context("CN", os: OSVersion(27, 2)))
        XCTAssertTrue(changed)
        let outcome = await plane.perform(Fleet.request())
        XCTAssertEqual(outcome.kind, .served(providerID: "regional.cn", output: "regional.cn:summarize"))
        XCTAssertEqual(claude.calls + apple.calls, 0)
        // Same jurisdictions, same OS, same connectivity: not a policy-relevant change.
        let unchanged = await plane.updateContext(Fleet.context("CN", os: OSVersion(27, 2)))
        XCTAssertFalse(unchanged)
        let generation = await plane.contextGeneration
        XCTAssertEqual(generation, 1)
    }

    // MARK: Defense in depth

    func testAuditorBlocksABrokenResolverBeforeDispatch() async {
        let apple = CountingAdapter(Fleet.apple), claude = CountingAdapter(Fleet.claude)
        let cn = CountingAdapter(Fleet.regionalCN), eu = CountingAdapter(Fleet.regionalEU)
        let plane = makePlane([apple, cn, eu, claude], resolver: IgnoresPolicyResolver())
        // The broken resolver ranks Claude (most expensive) first, for sensitive data.
        let outcome = await plane.perform(Fleet.request(.summarize, .sensitive))
        XCTAssertEqual(outcome.kind, .served(providerID: "apple.ondevice", output: "apple.ondevice:summarize"))
        XCTAssertEqual(claude.calls + cn.calls + eu.calls, 0)
        XCTAssertEqual(Set(outcome.auditFindings.map(\.providerID)), ["claude.us", "regional.cn", "regional.eu"])
    }

    func testAuditorFlagsViolationsDirectly() {
        let result = ResidencyAuditor.audit(chain: [Fleet.claude, Fleet.apple], request: Fleet.request(.summarize, .sensitive),
                                            context: Fleet.context("US"), jurisdictions: [.unitedStates], config: Fleet.config())
        XCTAssertEqual(result.approved.map(\.id), ["apple.ondevice"])
        XCTAssertEqual(result.findings.first?.reasons,
                       [.residency(location: .hostedIn(.unitedStates), dataClass: .sensitive, in: .unitedStates)])
    }

    func testMissingAdapterIsSkippedNotFatal() async {
        let ghost = ProviderDescriptor(id: "ghost", displayName: "Ghost", kind: .onDevice, processing: .onDevice,
                                       defaultOffer: ProviderOffer(capabilities: Fleet.all), requiresNetwork: false)
        let apple = CountingAdapter(Fleet.apple)
        let plane = makePlane([apple], resolver: IgnoresPolicyResolver(extra: [ghost]))
        let outcome = await plane.perform(Fleet.request())
        XCTAssertEqual(outcome.attempts, [Attempt(providerID: "ghost", result: .missingAdapter),
                                          Attempt(providerID: "apple.ondevice", result: .served)])
    }

    // MARK: Actor reentrancy

    private func waitForArrival(_ gate: Gate, count: Int = 1) async {
        for _ in 0..<100_000 where await gate.arrivals < count { await Task.yield() }
    }

    func testAnswerIsDiscardedWhenKillSwitchFlipsMidFlight() async throws {
        let gate = Gate()
        let apple = CountingAdapter(Fleet.apple, gate: gate), claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, claude])
        let inFlight = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        let arrivals = await gate.arrivals
        XCTAssertEqual(arrivals, 1)

        try await plane.apply(Fleet.config(version: 2, kills: [KillSwitch(providerID: "apple.ondevice")]))
        await gate.open()

        let outcome = await inFlight.value
        XCTAssertEqual(outcome.attempts.map(\.result), [.discardedAfterPolicyChange, .served])
        XCTAssertEqual(outcome.kind, .served(providerID: "claude.us", output: "claude.us:summarize"))
    }

    func testAnswerIsDiscardedWhenRegionChangesMidFlight() async {
        let gate = Gate()
        let claude = CountingAdapter(Fleet.claude, gate: gate), cn = CountingAdapter(Fleet.regionalCN)
        let plane = makePlane([claude, cn])
        let inFlight = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        await plane.updateContext(Fleet.context("CN", os: OSVersion(27, 2)))
        await gate.open()
        let outcome = await inFlight.value
        XCTAssertEqual(outcome.attempts.map(\.providerID), ["claude.us", "regional.cn"])
        XCTAssertEqual(outcome.kind, .served(providerID: "regional.cn", output: "regional.cn:summarize"))
    }

    func testIrrelevantChangeMidFlightKeepsTheAnswer() async throws {
        // Control for the two tests above: a config bump that does not affect the
        // in-flight provider must not discard its answer.
        let gate = Gate()
        let apple = CountingAdapter(Fleet.apple, gate: gate)
        let plane = makePlane([apple, CountingAdapter(Fleet.claude)])
        let inFlight = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        try await plane.apply(Fleet.config(version: 2, kills: [KillSwitch(providerID: "claude.us")]))
        await gate.open()
        let outcome = await inFlight.value
        XCTAssertEqual(outcome.attempts, [Attempt(providerID: "apple.ondevice", result: .served)])
    }

    func testCancelledRequestDegrades() async {
        let plane = makePlane([CountingAdapter(Fleet.apple)])
        let task = Task { () -> CapabilityOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await plane.perform(Fleet.request())
        }
        let outcome = await task.value
        guard case .degraded(_, .cancelled) = outcome.kind else { return XCTFail("got \(outcome.kind)") }
    }

    // MARK: Config versioning

    func testStaleAndReplayedConfigsAreRejected() async throws {
        let plane = makePlane([CountingAdapter(Fleet.apple)], config: Fleet.config(version: 5))
        do { try await plane.apply(Fleet.config(version: 5)); XCTFail("equal version accepted") }
        catch { XCTAssertEqual(error, .stale(offered: 5, current: 5)) }
        do { try await plane.apply(Fleet.config(version: 3)); XCTFail("older version accepted") }
        catch { XCTAssertEqual(error, .stale(offered: 3, current: 5)) }
        try await plane.apply(Fleet.config(version: 6))
        let version = await plane.config.version
        XCTAssertEqual(version, 6)
    }

    func testReplayCannotResurrectAKilledProvider() async throws {
        let plane = makePlane([CountingAdapter(Fleet.apple), CountingAdapter(Fleet.claude)])
        try await plane.apply(Fleet.config(version: 2, kills: [KillSwitch(providerID: "apple.ondevice")]))
        try? await plane.apply(Fleet.config(version: 1))   // delayed delivery of the old config
        let chain = await plane.preview(Fleet.request()).chain.map(\.id)
        XCTAssertEqual(chain, ["claude.us"])
    }

    // MARK: Circuit breaking through the plane

    func testCircuitOpensThenProbesAfterCooldown() async {
        let clock = ManualPlaneClock()
        let apple = CountingAdapter(Fleet.apple, failing: true), claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, claude], clock: clock)
        _ = await plane.perform(Fleet.request())
        _ = await plane.perform(Fleet.request())
        let verdict = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(verdict, .open)
        _ = await plane.perform(Fleet.request())
        XCTAssertEqual(apple.calls, 2, "open circuit must not be called")

        clock.advance(by: 31)
        apple.failure.isOn = false
        let outcome = await plane.perform(Fleet.request())
        XCTAssertEqual(outcome.kind, .served(providerID: "apple.ondevice", output: "apple.ondevice:summarize"))
        let healed = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(healed, .healthy)
    }

    // MARK: Telemetry

    func testTelemetryNeverContainsPayload() async {
        let sink = BoundedTelemetryBuffer(capacity: 64)
        let secret = "patient-record-4471"
        let plane = makePlane([CountingAdapter(Fleet.apple, failing: true), CountingAdapter(Fleet.claude)], telemetry: sink)
        _ = await plane.perform(Fleet.request(input: secret))
        XCTAssertFalse(sink.events.isEmpty)
        XCTAssertFalse(String(describing: sink.events).contains(secret))
        XCTAssertTrue(sink.events.contains(.providerFailed(feature: "test", providerID: "apple.ondevice")))
    }

    func testDuplicateAdapterIDsFirstWins() async {
        let first = CountingAdapter(Fleet.apple), second = CountingAdapter(Fleet.apple)
        let plane = makePlane([first, second])
        _ = await plane.perform(Fleet.request())
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 0)
        let count = await plane.providers.count
        XCTAssertEqual(count, 1)
    }

    // MARK: Breaker under concurrency (round-1 review gaps)

    private func openAppleBreaker(_ plane: CapabilityPlane) async {
        _ = await plane.perform(Fleet.request())
        _ = await plane.perform(Fleet.request())
        let verdict = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(verdict, .open)
    }

    func testOnlyOneProbeAtATime() async {
        let clock = ManualPlaneClock()
        let gate = Gate()
        let apple = ScriptedAdapter(Fleet.apple, gate: gate, script: [.fail, .fail, .park])
        let claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, claude], clock: clock)
        await openAppleBreaker(plane)
        clock.advance(by: 31)

        let probe = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        // While the probe is parked, a second request must not also hit Apple.
        let second = await plane.perform(Fleet.request())
        XCTAssertEqual(second.kind, .served(providerID: "claude.us", output: "claude.us:summarize"))
        XCTAssertEqual(apple.calls, 3, "2 failures + exactly 1 probe")

        await gate.open()
        let probed = await probe.value
        XCTAssertEqual(probed.kind, .served(providerID: "apple.ondevice", output: "apple.ondevice:summarize"))
        let healed = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(healed, .healthy)
    }

    func testLateSuccessDoesNotCloseABreakerThatOpenedMeanwhile() async {
        let gate = Gate()
        // Call 1 parks; calls 2 and 3 fail and open the breaker while call 1 is in flight.
        let apple = ScriptedAdapter(Fleet.apple, gate: gate, script: [.park, .fail, .fail])
        let plane = makePlane([apple, CountingAdapter(Fleet.claude)])
        let slow = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        _ = await plane.perform(Fleet.request())
        _ = await plane.perform(Fleet.request())
        let opened = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(opened, .open)

        await gate.open()
        _ = await slow.value
        let after = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(after, .open, "a success from before the breaker opened must not skip its cooldown")
    }

    func testCancellingAProbeMidCallReleasesIt() async {
        let clock = ManualPlaneClock()
        let gate = Gate()
        let apple = ScriptedAdapter(Fleet.apple, gate: gate, script: [.fail, .fail, .park])
        let plane = makePlane([apple, CountingAdapter(Fleet.claude)], clock: clock)
        await openAppleBreaker(plane)
        clock.advance(by: 31)

        let probe = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        probe.cancel()
        await gate.open()
        let outcome = await probe.value
        guard case .degraded(_, .cancelled) = outcome.kind else { return XCTFail("got \(outcome.kind)") }
        XCTAssertEqual(outcome.attempts.last, Attempt(providerID: "apple.ondevice", result: .cancelled))
        // Without abandonProbe the breaker would stay half-open with a phantom probe (verdict .open).
        let verdict = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(verdict, .probeAllowed)
    }

    func testIterationCapStopsAResolverThatInventsProviders() async {
        let apple = CountingAdapter(Fleet.apple)
        let plane = makePlane([apple], resolver: InventingResolver())
        let outcome = await plane.perform(Fleet.request())
        // cap = providers (1) + maxAttempts (3) + 1
        XCTAssertEqual(outcome.attempts.count, 5)
        XCTAssertTrue(outcome.attempts.allSatisfy { $0.result == .missingAdapter })
        XCTAssertEqual(outcome.kind, .degraded(output: "Quarterly report", reason: .noEligibleProvider))
        XCTAssertEqual(apple.calls, 0)
    }

    func testConcurrentKillSwitchUpdatesCompose() async {
        let plane = makePlane([CountingAdapter(Fleet.apple), CountingAdapter(Fleet.claude)])
        async let a: UInt64 = plane.updateKillSwitches { $0.togglingKill("apple.ondevice", in: [.unitedStates]) }
        async let b: UInt64 = plane.updateKillSwitches { $0.togglingKill("claude.us", in: [.unitedStates]) }
        let versions = await [a, b].sorted()
        XCTAssertEqual(versions, [2, 3])
        let config = await plane.config
        XCTAssertTrue(config.isProviderKilled("apple.ondevice", in: [.unitedStates]))
        XCTAssertTrue(config.isProviderKilled("claude.us", in: [.unitedStates]))
        let chain = await plane.preview(Fleet.request()).chain
        XCTAssertTrue(chain.isEmpty)
    }

    func testLateFailureDoesNotRestartTheCooldown() async {
        let clock = ManualPlaneClock()
        let gate = Gate()
        let apple = ScriptedAdapter(Fleet.apple, gate: gate, script: [.parkThenFail, .fail, .fail])
        let plane = makePlane([apple, CountingAdapter(Fleet.claude)], clock: clock)
        let slow = Task { await plane.perform(Fleet.request()) }
        await waitForArrival(gate)
        await openAppleBreaker(plane)          // opens at t = 0
        clock.advance(by: 25)
        await gate.open()                      // the stale call fails at t = 25
        _ = await slow.value
        clock.advance(by: 6)                   // t = 31: cooldown from t = 0 has elapsed
        let verdict = await plane.healthVerdict(for: "apple.ondevice")
        XCTAssertEqual(verdict, .probeAllowed, "a failure from before the breaker opened must not restart its cooldown")
    }

    func testBreakerIsEnforcedEvenForAResolverThatIgnoresIt() async {
        let apple = CountingAdapter(Fleet.apple, failing: true), claude = CountingAdapter(Fleet.claude)
        let plane = makePlane([apple, claude], resolver: IgnoresPolicyResolver())
        // Sensitive data: the auditor blocks Claude, so every request reaches Apple, which fails.
        _ = await plane.perform(Fleet.request(.summarize, .sensitive))
        _ = await plane.perform(Fleet.request(.summarize, .sensitive))   // second failure opens the breaker
        XCTAssertEqual(apple.calls, 2)
        _ = await plane.perform(Fleet.request(.summarize, .sensitive))
        XCTAssertEqual(apple.calls, 2, "open breaker must not be dispatched to, whatever the resolver says")
        XCTAssertEqual(claude.calls, 0)
    }

    func testEmptyJurisdictionListFailsClosed() {
        let result = ResidencyAuditor.audit(chain: [Fleet.apple], request: Fleet.request(), context: Fleet.context("US"),
                                            jurisdictions: [], config: Fleet.config())
        XCTAssertTrue(result.approved.isEmpty)
        XCTAssertEqual(result.findings.first?.reasons, [.noBindingJurisdiction])
    }
}
