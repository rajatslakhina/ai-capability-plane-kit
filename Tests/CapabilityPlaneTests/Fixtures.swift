import Foundation
@testable import CapabilityPlane

func cc(_ s: String) -> CountryCode {
    guard let code = CountryCode(s) else { preconditionFailure("bad fixture country \(s)") }
    return code
}

enum Fleet {
    static let all: Set<Capability> = Set(Capability.allCases)

    static let apple = ProviderDescriptor(
        id: "apple.ondevice", displayName: "Apple on-device", kind: .onDevice, processing: .onDevice,
        offers: [.china: ProviderOffer(capabilities: [.summarize, .translate, .rewrite], minimumOS: OSVersion(27, 3))],
        defaultOffer: ProviderOffer(capabilities: all, minimumOS: OSVersion(27, 0)),
        requiresNetwork: false, relativeCost: 0)

    static let regionalCN = ProviderDescriptor(
        id: "regional.cn", displayName: "Regional cloud CN", kind: .regionalCloud, processing: .hostedIn(.china),
        offers: [.china: ProviderOffer(capabilities: [.summarize, .translate, .extract, .rewrite])],
        defaultOffer: nil, requiresNetwork: true, relativeCost: 2)

    static let regionalEU = ProviderDescriptor(
        id: "regional.eu", displayName: "Regional cloud EU", kind: .regionalCloud, processing: .hostedIn(.europeanUnion),
        offers: [.europeanUnion: ProviderOffer(capabilities: [.summarize, .translate, .extract, .rewrite])],
        defaultOffer: nil, requiresNetwork: true, relativeCost: 2)

    static let claude = ProviderDescriptor(
        id: "claude.us", displayName: "Claude", kind: .frontierCloud, processing: .hostedIn(.unitedStates),
        defaultOffer: ProviderOffer(capabilities: all), excluded: [.china],
        requiresNetwork: true, relativeCost: 5)

    static let descriptors = [apple, regionalCN, regionalEU, claude]

    static let map = JurisdictionMap(mapping: [
        cc("US"): .unitedStates, cc("CN"): .china, cc("DE"): .europeanUnion, cc("FR"): .europeanUnion,
    ])

    static let residency = ResidencyPolicy(rules: [
        .unitedStates: [.publicContent: [.hostedIn(.unitedStates), .hostedIn(.europeanUnion)],
                        .personal: [.hostedIn(.unitedStates)], .sensitive: []],
        .europeanUnion: [.publicContent: [.hostedIn(.europeanUnion), .hostedIn(.unitedStates)],
                         .personal: [.hostedIn(.europeanUnion)], .sensitive: []],
        .china: [.publicContent: [.hostedIn(.china)], .personal: [.hostedIn(.china)], .sensitive: []],
        .restOfWorld: [.publicContent: [.hostedIn(.unitedStates), .hostedIn(.europeanUnion)],
                       .personal: [.hostedIn(.unitedStates)], .sensitive: []],
    ])

    static func config(version: UInt64 = 1, kills: Set<KillSwitch> = [], floor: Double = 0, maxAttempts: Int = 3) -> PlaneConfig {
        PlaneConfig(version: version, residency: residency, killSwitches: kills, parityFloor: floor, maxAttempts: maxAttempts)
    }

    static func context(_ store: String, _ region: String? = nil, os: OSVersion = OSVersion(27, 2), online: Bool = true) -> RegionContext {
        RegionContext(storefront: cc(store), deviceRegion: cc(region ?? store), osVersion: os, isOnline: online)
    }

    static func request(_ capability: Capability = .summarize, _ dataClass: DataClass = .personal,
                        input: String = "Quarterly report. Revenue grew.") -> CapabilityRequest {
        CapabilityRequest(featureID: "test", capability: capability, dataClass: dataClass, input: input)
    }
}

/// Counts calls; optionally fails; optionally parks on a gate.
final class CountingAdapter: ProviderAdapter, @unchecked Sendable {
    // @unchecked: `count` is only touched while holding `lock`.
    let descriptor: ProviderDescriptor
    let failure: FailureSwitch
    let gate: Gate?
    private let lock = NSLock()
    private var count = 0

    init(_ descriptor: ProviderDescriptor, failing: Bool = false, gate: Gate? = nil) {
        self.descriptor = descriptor
        self.failure = FailureSwitch(isOn: failing)
        self.gate = gate
    }

    private func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func execute(_ request: CapabilityRequest) async throws -> String {
        increment()
        if let gate { await gate.wait() }
        if failure.isOn { throw ProviderError.unavailable(descriptor.id) }
        return "\(descriptor.id):\(request.capability.rawValue)"
    }
}

/// Parks a caller until `open()` is called. Lets a test act deterministically
/// while a provider call is suspended inside the plane.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen: Bool
    private(set) var arrivals = 0

    init(open: Bool = false) { isOpen = open }

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Plays a script, one step per call: park on the gate (then honour cancellation),
/// fail, or succeed. After the script runs out, every call succeeds.
final class ScriptedAdapter: ProviderAdapter, @unchecked Sendable {
    // @unchecked: `script` and `count` are only touched while holding `lock`.
    enum Step { case park, parkThenFail, fail, succeed }
    let descriptor: ProviderDescriptor
    let gate: Gate
    private let lock = NSLock()
    private var script: [Step]
    private var count = 0

    init(_ descriptor: ProviderDescriptor, gate: Gate, script: [Step]) {
        self.descriptor = descriptor
        self.gate = gate
        self.script = script
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    private func nextStep() -> Step {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return script.isEmpty ? .succeed : script.removeFirst()
    }

    func execute(_ request: CapabilityRequest) async throws -> String {
        switch nextStep() {
        case .park:
            await gate.wait()
            try Task.checkCancellation()
        case .parkThenFail:
            await gate.wait()
            throw ProviderError.unavailable(descriptor.id)
        case .fail:
            throw ProviderError.unavailable(descriptor.id)
        case .succeed:
            break
        }
        return "\(descriptor.id):\(request.capability.rawValue)"
    }
}

/// A resolver that invents a brand-new, unregistered provider on every call.
final class InventingResolver: CapabilityResolving, @unchecked Sendable {
    // @unchecked: `counter` is only touched while holding `lock`.
    private let lock = NSLock()
    private var counter = 0

    private func nextID() -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "ghost-\(counter)"
    }

    func resolve(_ input: ResolutionInput) -> Decision {
        let ghost = ProviderDescriptor(id: nextID(), displayName: "Ghost", kind: .onDevice, processing: .onDevice,
                                       defaultOffer: ProviderOffer(capabilities: Fleet.all), requiresNetwork: false)
        return Decision(capability: input.request.capability, dataClass: input.request.dataClass,
                        jurisdictions: input.jurisdictions, chain: [ghost] + input.providers,
                        rejections: [], configVersion: input.config.version)
    }
}

/// Deliberately broken resolver: ignores every hard constraint and returns all
/// providers. Used to prove the auditor, not the resolver, enforces residency.
struct IgnoresPolicyResolver: CapabilityResolving {
    var extra: [ProviderDescriptor] = []
    func resolve(_ input: ResolutionInput) -> Decision {
        Decision(capability: input.request.capability, dataClass: input.request.dataClass,
                 jurisdictions: input.jurisdictions, chain: extra + input.providers.sorted { $0.relativeCost > $1.relativeCost },
                 rejections: [], configVersion: input.config.version)
    }
}

func makePlane(
    _ adapters: [any ProviderAdapter],
    context: RegionContext = Fleet.context("US"),
    config: PlaneConfig = Fleet.config(),
    resolver: any CapabilityResolving = PolicyEngine(),
    clock: any PlaneClock = ManualPlaneClock(),
    telemetry: any TelemetrySink = NullTelemetry(),
    parity: ParityLedger = ParityLedger()
) -> CapabilityPlane {
    CapabilityPlane(adapters: adapters, config: config, context: context, jurisdictionMap: Fleet.map,
                    parity: parity, resolver: resolver, clock: clock, telemetry: telemetry)
}

func engineDecision(_ context: RegionContext, _ request: CapabilityRequest = Fleet.request(),
                    config: PlaneConfig = Fleet.config(), parity: ParityLedger = ParityLedger(),
                    health: [String: HealthVerdict] = [:], resolver: any CapabilityResolving = PolicyEngine()) -> Decision {
    resolver.resolve(ResolutionInput(request: request, context: context,
                                     jurisdictions: Fleet.map.bindingJurisdictions(for: context),
                                     providers: Fleet.descriptors, config: config, parity: parity, health: health))
}
