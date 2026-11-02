#if canImport(SwiftUI)
import XCTest
import CapabilityPlane
@testable import CapabilityPlaneUI

private func code(_ s: String) -> CountryCode {
    guard let c = CountryCode(s) else { preconditionFailure(s) }
    return c
}

/// Parks every call until opened.
private actor Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct LatchedAdapter: ProviderAdapter {
    let descriptor: ProviderDescriptor
    let latch: Latch
    func execute(_ request: CapabilityRequest) async throws -> String {
        await latch.wait()
        return descriptor.id
    }
}

@MainActor
final class ConsoleModelTests: XCTestCase {
    private let us = code("US"), de = code("DE")
    private let onDevice = ProviderDescriptor(
        id: "device", displayName: "Device", kind: .onDevice, processing: .onDevice,
        defaultOffer: ProviderOffer(capabilities: Set(Capability.allCases)), requiresNetwork: false)
    private let cloud = ProviderDescriptor(
        id: "cloud", displayName: "Cloud", kind: .frontierCloud, processing: .hostedIn(.unitedStates),
        defaultOffer: ProviderOffer(capabilities: Set(Capability.allCases)), requiresNetwork: true)

    private func makeModel(adapters: [any ProviderAdapter]? = nil) -> CapabilityConsoleModel {
        let residency = ResidencyPolicy(rules: [.unitedStates: [.personal: [.hostedIn(.unitedStates)]]])
        let context = RegionContext(storefront: us, deviceRegion: us, osVersion: OSVersion(27, 2))
        let plane = CapabilityPlane(
            adapters: adapters ?? [SimulatedProviderAdapter(descriptor: onDevice), SimulatedProviderAdapter(descriptor: cloud)],
            config: PlaneConfig(version: 1, residency: residency), context: context,
            jurisdictionMap: JurisdictionMap(mapping: [us: .unitedStates, de: .europeanUnion]))
        return CapabilityConsoleModel(plane: plane, initialContext: context, countries: [us, de],
                                      osVersions: [OSVersion(27, 2)], outageSwitches: [:], sampleInput: "Hi. There.")
    }

    func testRapidKillTogglesComposeAndMatchThePlane() async {
        let model = makeModel()
        await model.refresh()
        async let a: Void = model.toggleKill("device")
        async let b: Void = model.toggleKill("cloud")
        _ = await (a, b)
        await model.refresh()
        XCTAssertEqual(model.killedProviders, ["device", "cloud"])
        let config = await model.plane.config
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(model.decision?.chain.isEmpty, true)
    }

    func testKilledLabelFollowsTheCurrentRegion() async {
        let model = makeModel()
        await model.refresh()
        await model.toggleKill("device")
        XCTAssertEqual(model.killedProviders, ["device"])
        model.storefront = de
        model.deviceRegion = de
        await model.refresh()
        XCTAssertEqual(model.killedProviders, [], "a US-scoped switch does not apply in the EU")
        XCTAssertEqual(model.decision?.chain.first?.id, "device")
    }

    func testToggleKillTargetsTheOnScreenRegionWithoutARefresh() async {
        // The pickers changed (US -> DE) but no refresh has published yet, so
        // `model.jurisdictions` is still [US]. The kill must land on the region on screen.
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.jurisdictions, [.unitedStates])
        model.storefront = de
        model.deviceRegion = de
        await model.toggleKill("device")
        let switches = await model.plane.config.killSwitches
        XCTAssertEqual(switches, [KillSwitch(jurisdiction: .europeanUnion, providerID: "device")])
        XCTAssertEqual(model.killedProviders, ["device"])
    }

    func testRunResultIsDroppedIfTheRequestChangedMidFlight() async {
        let latch = Latch()
        let model = makeModel(adapters: [LatchedAdapter(descriptor: onDevice, latch: latch)])
        await model.refresh()
        let running = Task { await model.run() }
        for _ in 0..<100_000 where await latch.arrivals == 0 { await Task.yield() }
        model.capability = .translate          // user changed the question while it ran
        await latch.open()
        await running.value
        XCTAssertNil(model.outcome, "an answer to the old question must not be shown under the new one")
    }

    func testRunPublishesOutcomeForTheDefaultState() async {
        let model = makeModel()
        await model.refresh()
        await model.run()
        guard case .served(let provider, _)? = model.outcome?.kind else { return XCTFail("no outcome") }
        XCTAssertEqual(provider, "device")
    }
}
#endif
