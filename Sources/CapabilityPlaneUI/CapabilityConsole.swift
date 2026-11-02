#if canImport(SwiftUI)
import SwiftUI
import CapabilityPlane

/// Drives the console: owns the user's scenario choices and talks to the plane.
@MainActor
public final class CapabilityConsoleModel: ObservableObject {
    public let plane: CapabilityPlane
    public let countries: [CountryCode]
    public let osVersions: [OSVersion]
    public let outageSwitches: [String: FailureSwitch]
    public let sampleInput: String
    /// When true, the console dispatches one real request right after its first
    /// refresh (used for UI tests and scripted screenshots via launch arguments).
    public let runOnAppear: Bool

    @Published public var storefront: CountryCode
    @Published public var deviceRegion: CountryCode
    @Published public var osVersion: OSVersion
    @Published public var isOnline: Bool = true
    @Published public var capability: Capability = .summarize
    @Published public var dataClass: DataClass = .personal
    @Published public private(set) var providers: [ProviderDescriptor] = []
    @Published public private(set) var jurisdictions: [Jurisdiction] = []
    @Published public private(set) var decision: Decision?
    @Published public private(set) var outcome: CapabilityOutcome?
    /// Providers with a kill switch that applies in the current binding jurisdictions.
    @Published public private(set) var killedProviders: Set<String> = []
    @Published public private(set) var outages: Set<String> = []
    @Published public private(set) var configVersion: UInt64 = 0
    @Published public private(set) var parityGaps: [ParityGap] = []
    @Published public private(set) var isRunning = false

    public init(plane: CapabilityPlane, initialContext: RegionContext, countries: [CountryCode],
                osVersions: [OSVersion], outageSwitches: [String: FailureSwitch], sampleInput: String,
                capability: Capability = .summarize, dataClass: DataClass = .personal, runOnAppear: Bool = false) {
        self.plane = plane
        self.countries = countries
        self.osVersions = osVersions
        self.outageSwitches = outageSwitches
        self.sampleInput = sampleInput
        self.storefront = initialContext.storefront
        self.deviceRegion = initialContext.deviceRegion
        self.osVersion = initialContext.osVersion
        self.isOnline = initialContext.isOnline
        self.capability = capability
        self.dataClass = dataClass
        self.runOnAppear = runOnAppear
        self.outages = Set(outageSwitches.filter { $0.value.isOn }.map(\.key))
    }

    private var request: CapabilityRequest {
        CapabilityRequest(featureID: "console", capability: capability, dataClass: dataClass, input: sampleInput)
    }

    private var refreshToken: UInt64 = 0

    /// Pushes the current scenario into the plane and re-previews the decision.
    /// Rapid picker changes start overlapping refreshes; a token makes sure only the
    /// newest one publishes, so a slow, stale preview can never overwrite a fresh one.
    /// Everything shown (including which providers read as "Killed") is derived from
    /// the plane's state, never kept as a separate local copy that could drift.
    public func refresh(keepOutcome: Bool = false) async {
        refreshToken = refreshToken.saturatingIncrement()
        let token = refreshToken
        let request = self.request
        await plane.updateContext(RegionContext(storefront: storefront, deviceRegion: deviceRegion,
                                                osVersion: osVersion, isOnline: isOnline))
        let newProviders = await plane.providers
        let newJurisdictions = await plane.jurisdictions
        let newDecision = await plane.preview(request)
        let parity = await plane.parity
        let config = await plane.config
        guard token == refreshToken else { return }
        providers = newProviders
        jurisdictions = newJurisdictions
        decision = newDecision
        parityGaps = Capability.allCases.compactMap { parity.parityGap(for: $0) }
        configVersion = config.version
        killedProviders = Set(newProviders.map(\.id).filter { config.isProviderKilled($0, in: newJurisdictions) })
        if !keepOutcome { outcome = nil }
    }

    /// Dispatches the request for real (through simulated adapters). The result is
    /// published only if the scenario the user is looking at is still the one that
    /// produced it; the pickers are disabled while running, and this guard covers the
    /// remaining paths (programmatic changes, a refresh racing the run).
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let request = self.request
        let context = RegionContext(storefront: storefront, deviceRegion: deviceRegion, osVersion: osVersion, isOnline: isOnline)
        let result = await plane.perform(request)
        let currentContext = RegionContext(storefront: storefront, deviceRegion: deviceRegion, osVersion: osVersion, isOnline: isOnline)
        guard request == self.request, context == currentContext else { return }
        outcome = result
        await refresh(keepOutcome: true)   // breaker state may have changed; token-guarded
    }

    /// Flips a provider kill switch for the currently-binding jurisdictions. The
    /// read-modify-write happens inside the plane actor, so rapid taps compose
    /// instead of racing, and the button state is re-derived from the result.
    public func toggleKill(_ providerID: String) async {
        // Push the scenario on screen first and take the scope from the plane, so a tap
        // right after a picker change targets the region the user is looking at.
        await plane.updateContext(RegionContext(storefront: storefront, deviceRegion: deviceRegion,
                                                osVersion: osVersion, isOnline: isOnline))
        let scope = await plane.jurisdictions
        await plane.updateKillSwitches { $0.togglingKill(providerID, in: scope) }
        await refresh()
    }

    public func toggleOutage(_ providerID: String) async {
        guard let failure = outageSwitches[providerID] else { return }
        failure.isOn.toggle()
        if failure.isOn { outages.insert(providerID) } else { outages.remove(providerID) }
        await refresh()
    }
}

/// The console screen: pick a region, OS and data class, then watch the plane decide.
public struct CapabilityConsoleView: View {
    @ObservedObject private var model: CapabilityConsoleModel

    public init(model: CapabilityConsoleModel) {
        self.model = model
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<CapabilityConsoleModel, T>) -> Binding<T> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { newValue in
                model[keyPath: keyPath] = newValue
                Task { await model.refresh() }
            })
    }

    public var body: some View {
        NavigationStack {
            Form {
                scenarioSection
                if let outcome = model.outcome { outcomeSection(outcome) }
                decisionSection
                requestSection
                operationsSection
                paritySection
            }
            .navigationTitle("Capability Plane")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.run() }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .disabled(model.isRunning)
                }
            }
            .task {
                // One sequential task, so the initial refresh can never land after
                // (and wipe) the scripted run's outcome.
                await model.refresh()
                if model.runOnAppear { await model.run() }
            }
        }
    }

    private var scenarioSection: some View {
        Section {
            Picker("Storefront", selection: binding(\.storefront)) {
                ForEach(model.countries, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isRunning)
            Picker("Device region", selection: binding(\.deviceRegion)) {
                ForEach(model.countries, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isRunning)
            Picker("iOS", selection: binding(\.osVersion)) {
                ForEach(model.osVersions, id: \.self) { Text($0.description).tag($0) }
            }
            .disabled(model.isRunning)
            Toggle("Online", isOn: binding(\.isOnline))
                .disabled(model.isRunning)
        } header: {
            Text("Where is this device?")
        } footer: {
            Text("Binding jurisdictions: " + model.jurisdictions.map(\.rawValue).joined(separator: " + "))
        }
    }

    private var requestSection: some View {
        Section("What does the feature ask for?") {
            Picker("Capability", selection: binding(\.capability)) {
                ForEach(Capability.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isRunning)
            Picker("Data", selection: binding(\.dataClass)) {
                Text("public").tag(DataClass.publicContent)
                Text("personal").tag(DataClass.personal)
                Text("sensitive").tag(DataClass.sensitive)
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            Button {
                Task { await model.run() }
            } label: {
                Label(model.isRunning ? "Running…" : "Run request", systemImage: "play.fill")
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("runButton")
        }
    }

    @ViewBuilder
    private var decisionSection: some View {
        Section("Decision (config v\(model.configVersion))") {
            if let decision = model.decision {
                if decision.chain.isEmpty {
                    Label("No eligible provider: no-AI fallback", systemImage: "nosign")
                        .foregroundStyle(.orange)
                }
                ForEach(Array(decision.chain.enumerated()), id: \.element.id) { index, provider in
                    HStack {
                        Image(systemName: index == 0 ? "checkmark.circle.fill" : "arrow.turn.down.right")
                            .foregroundStyle(index == 0 ? Color.green : Color.secondary)
                        VStack(alignment: .leading) {
                            Text(provider.displayName).font(.body.weight(index == 0 ? .semibold : .regular))
                            Text(index == 0 ? "primary · \(provider.processing.description)"
                                            : "failover #\(index) · \(provider.processing.description)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(Array(decision.rejections.enumerated()), id: \.offset) { _, rejection in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(name(for: rejection.providerID), systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                        ForEach(Array(rejection.reasons.enumerated()), id: \.offset) { _, reason in
                            Text("• \(reason.description)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Resolving…").foregroundStyle(.secondary)
            }
        }
    }

    private func outcomeSection(_ outcome: CapabilityOutcome) -> some View {
        Section("Last run") {
            switch outcome.kind {
            case let .served(providerID, output):
                Label("Served by \(name(for: providerID))", systemImage: "bolt.fill").foregroundStyle(.green)
                Text(output).font(.callout.monospaced())
            case let .degraded(output, reason):
                Label("Degraded: \(reason.description)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(output.isEmpty ? "(empty)" : output).font(.callout.monospaced())
            }
            ForEach(Array(outcome.attempts.enumerated()), id: \.offset) { _, attempt in
                Text("attempt: \(name(for: attempt.providerID)) → \(label(attempt.result))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var operationsSection: some View {
        Section {
            ForEach(model.providers) { provider in
                HStack {
                    Text(provider.displayName)
                    Spacer()
                    Button(model.killedProviders.contains(provider.id) ? "Killed" : "Kill") {
                        Task { await model.toggleKill(provider.id) }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.killedProviders.contains(provider.id) ? .red : .gray)
                    if model.outageSwitches[provider.id] != nil {
                        Button(model.outages.contains(provider.id) ? "Down" : "Up") {
                            Task { await model.toggleOutage(provider.id) }
                        }
                        .buttonStyle(.bordered)
                        .tint(model.outages.contains(provider.id) ? .orange : .green)
                    }
                }
            }
        } header: {
            Text("Operations")
        } footer: {
            Text("Kill applies to the jurisdictions binding right now, as a strictly newer config; \"Killed\" reflects the current region. Up/Down simulates a provider outage; two failures open its circuit.")
        }
    }

    private var paritySection: some View {
        Section("Eval parity across regions") {
            if model.parityGaps.isEmpty {
                Text("Fewer than two regions measured.").foregroundStyle(.secondary)
            }
            ForEach(model.parityGaps, id: \.capability) { gap in
                HStack {
                    Text(gap.capability.rawValue)
                    Spacer()
                    Text("\(gap.best.rawValue) \(percent(gap.bestScore)) · \(gap.worst.rawValue) \(percent(gap.worstScore))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(gap.spread > 0.1 ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private func name(for providerID: String) -> String {
        model.providers.first(where: { $0.id == providerID })?.displayName ?? providerID
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    private func label(_ result: Attempt.Result) -> String {
        switch result {
        case .served: return "served"
        case .failed: return "failed"
        case .missingAdapter: return "no adapter"
        case .discardedAfterPolicyChange: return "discarded (policy changed in flight)"
        case .cancelled: return "cancelled"
        }
    }
}
#endif
