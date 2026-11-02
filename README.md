# CapabilityPlane

**Your AI feature now has a geography.** This Swift package is a region-aware AI capability plane for iOS. A feature asks for a *capability* (`summarize`, `translate`, `extract`, `rewrite`, `assistant`), never for a model. The plane picks a provider for this storefront, this device region, this OS version and this kind of data. It can choose on-device Apple Intelligence, a cloud provider hosted in the region, a frontier cloud model, or a local fallback with no AI at all.

[![CI](https://github.com/rajatslakhina/ai-capability-plane-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/ai-capability-plane-kit/actions/workflows/ci.yml)

**Demo app:** [ai-capability-plane-demo-app](https://github.com/rajatslakhina/ai-capability-plane-demo-app). It's an iOS console that shows the plane's decision trace live, with real Simulator screenshots.

---

## Why this matters

Apple has confirmed an iOS 27.3 beta that brings Apple Intelligence to China, with a public release planned for December. China gets a different stack: a regional model partner, Writing Tools and Live Translation, and no Siri AI at launch ([9to5Mac, 30 Oct 2026](https://9to5mac.com/2026/10/30/apple-confirms-ios-27-3-beta-is-coming-next-week-with-apple-intelligence-in-china/)). Once that ships, a single "Summarize" button can need a different model, provider and data-residency rule depending on:

- **the storefront** (which App Store account the user has, which decides which legal terms apply),
- **the device region** (where the hardware is, which affects which provider is offered and what may leave the device),
- **the OS version** (on-device features arrive in each market on their own schedule),
- **the data class** (public text, personal data, sensitive data).

Most apps handle this today with `if Locale.current.region == "CN"` checks scattered through feature code. Each check is a residency decision that nobody reviews, that no test covers, and that cannot be turned off remotely. This package moves all of those decisions into one place that can be tested, explained and switched off remotely.

## Architecture

```
 Feature code ── CapabilityRequest(capability, dataClass, input)
        │
        ▼
 ┌──────────────────────── CapabilityPlane (actor) ───────────────────────┐
 │  RegionContext ──► JurisdictionMap ──► binding jurisdictions (1 or 2)   │
 │                                                                         │
 │  ResolutionInput snapshot ──► CapabilityResolving (PolicyEngine)        │
 │      hard: offered? capability? OS? residency? kill switch?             │
 │      soft: online? circuit open? eval parity ≥ floor?                   │
 │      rank: kind preference → parity → cost → id                         │
 │                       │                                                 │
 │                       ▼                                                 │
 │  ResidencyAuditor (re-checks every hard rule on REGISTERED descriptors) │
 │                       │                                                 │
 │                       ▼                                                 │
 │  ProviderAdapter.execute ──await──► re-audit if context/config changed  │
 │        │ fail → HealthBoard (circuit breaker) → next in chain           │
 │        ▼                                                                │
 │  served │ degraded → NoAIFallback (deterministic, local)                │
 └───────────────────────────── TelemetrySink (no payload text) ──────────┘
```

| Layer | Types | Responsibility |
|---|---|---|
| Capability API | `Capability`, `DataClass`, `CapabilityRequest`, `CapabilityOutcome` | The only vocabulary feature code uses. |
| Context | `RegionContext`, `CountryCode`, `OSVersion`, `Jurisdiction`, `JurisdictionMap` | Turns "where is this device" into the set of jurisdictions whose rules apply. |
| Policy | `PlaneConfig`, `ResidencyPolicy`, `KillSwitch`, `ParityLedger` | One versioned, remotely deliverable policy object. |
| Resolution | `CapabilityResolving`, `PolicyEngine`, `Decision`, `RejectionReason`, `HardConstraints` | A pure function from a snapshot to a ranked chain plus the reason for every rejection. |
| Enforcement | `ResidencyAuditor`, `CapabilityPlane` | Re-checks every hard rule, against the descriptors registered with the plane (never a resolver's copies), before any data is sent and again after every `await`. |
| Providers | `ProviderDescriptor`, `ProviderOffer`, `ProviderAdapter`, `SimulatedProviderAdapter` | Each market's offer per provider. Adapters execute requests and never see policy. |
| Operations | `HealthBoard`, `PlaneClock`, `TelemetrySink`, `BoundedTelemetryBuffer` | Circuit breaking, injectable time, and bounded telemetry. |
| UI (`CapabilityPlaneUI`) | `CapabilityConsoleModel`, `CapabilityConsoleView`, `PlaneSnapshot` | A SwiftUI console that shows the decision trace, rendered from one atomic `snapshot(for:)` per refresh. The UI target compiles only where SwiftUI exists. |

## Design decisions and trade-offs

**1. When storefront and device region disagree, both rule sets apply ("strictest wins").** Take a US account on a device in China. A provider must satisfy US rules *and* Chinese rules. On iOS 27.2 nothing qualifies, so the feature falls back to the version with no AI. On 27.3, on-device processing qualifies.
*Rejected:* using only the storefront, which is simple but sends data across a border the device is physically inside. Also rejected: using only the device region, which changes with travel or a settings toggle and ignores the account's legal terms. The cost of this choice is more fallback with no AI for travellers. That cost shows up in the decision trace and can be traded off on purpose.

**2. Hard and soft constraints are kept separate, and hard ones are enforced twice.** Hard constraints are legal and contractual: offered here, capability supported, OS version, residency, kill switch. Soft constraints are operational: offline, circuit open, eval parity. `CapabilityResolving` is a protocol, so ranking can be A/B tested or driven from a server. Every chain it returns still passes through `ResidencyAuditor` before any data is sent.

The auditor checks the descriptor *registered with the plane* for each provider ID, never the copy the resolver returned. A resolver can choose and order providers, but it cannot redefine one. So a broken or malicious resolver can make ranking worse but cannot break residency. Two tests check this:

- `testAuditorBlocksABrokenResolverBeforeDispatch` uses a resolver that ignores every rule.
- `testAuditorChecksTheRegisteredDescriptorNotTheResolversCopy` uses a resolver that relabels the US-hosted provider as on-device.

v1.0.0 audited the resolver's copy. An independent review found the gap, and v1.1.0 closes it.

`ResolutionInput` and `Rejection` have public initializers, so a resolver written outside this module can be unit-tested without a plane.

*Rejected:* trusting the resolver, or the data it returns. Either is one bug away from sending personal data to the wrong country.

**3. Missing residency rules mean on-device only.** A `(jurisdiction, data class)` pair with no rule allows only on-device processing. An empty jurisdiction list approves nothing (`.noBindingJurisdiction`). A new market or a typo in config makes features worse. It never makes them leak.
*Trade-off:* a forgotten rule shows up as a quality regression rather than an incident. That is the right way round.

**4. Configs apply only if their version is strictly newer.** Kill switches arrive inside a versioned `PlaneConfig`. If an old payload arrives late (CDN lag, retries, an offline queue), it is rejected with `ConfigError.stale`. It cannot bring back a provider that a newer config killed (`testReplayCannotResurrectAKilledProvider`). Versions are counters. A publisher must never emit `UInt64.max`, because a config at that version could never be superseded.
*Rejected:* last-write-wins, which is how an emergency kill switch quietly turns itself off an hour later.

**5. Actor reentrancy: take a fresh snapshot for each attempt, and re-audit after every `await`.** While a provider call is in flight, the user can change region, or a kill switch can arrive. When the adapter returns, the plane re-audits that provider against the *current* context and config. If the provider is no longer allowed, the answer is thrown away (`.discardedAfterPolicyChange`) and the next eligible provider is tried. The payload has already left the device, so the plane cannot un-send it, but it can refuse to use the answer. Each failover attempt resolves against fresh state, so failover never uses a decision made before the context changed. A change counts as policy-relevant even when the jurisdictions stay the same: an OS-version change or a connectivity change bumps the generation too (`testOSVersionChangeMidFlightIsReaudited`).
*Rejected:* resolving once per request, which uses a decision made before the last `await`, exactly the bug Swift actor reentrancy makes easy.

**6. Failover stays inside policy.** The failover chain is the list of eligible providers and nothing else. If Apple's on-device model fails in the US, the request fails over to the US-hosted cloud. It never fails over to the CN- or EU-hosted one (`testFailsOverWithinPolicyOnly`). When every eligible provider fails, the feature gets `NoAIFallback`: a deterministic local result. Summarize returns the first sentence. Translate and rewrite return the original text. It never "fails open" to a provider that policy rejected.

**7. Eval parity is part of policy.** `ParityLedger` stores eval scores per (jurisdiction, capability, provider). Providers below `parityFloor` in any binding jurisdiction are rejected, so a weak regional model gives way to the no-AI fallback instead of shipping bad answers. `parityGap(for:)` makes the quality gap between markets a number someone owns. NaN and out-of-range scores are rejected when recorded, because a NaN in a sort comparator breaks strict weak ordering.

**8. Circuit-breaker results are checked by epoch after every `await`.** A request sent while the breaker was closed can come back after other requests have opened it. Without a guard, that late success would close the breaker and skip the cooldown and probe. `HealthBoard` bumps a per-provider epoch on every phase change (closed, open, half-open). The plane records the epoch when it dispatches and drops results from an older epoch. The plane also checks the breaker itself before dispatching, so even a custom resolver that ignores `circuitOpen` cannot send to an open breaker. Each skipped provider is reported in the outcome's findings as `.circuitOpen`, never dropped silently. Only one probe runs at a time while the breaker is half-open. A probe cancelled mid-call is released immediately, so the breaker doesn't stay half-open waiting on a probe that will never finish (`testOnlyOneProbeAtATime`, `testLateSuccessDoesNotCloseABreakerThatOpenedMeanwhile`, `testCancellingAProbeMidCallReleasesIt`, `testLateFailureDoesNotRestartTheCooldown`, `testBreakerIsEnforcedEvenForAResolverThatIgnoresIt`).

**9. Bounded everything.** At most `maxAttempts` dispatches (clamped to 1...8). There is a hard limit on loop iterations, so a resolver that keeps inventing unregistered providers cannot make the plane spin (`testIterationCapStopsAResolverThatInventsProviders`). The telemetry buffer is a fixed-capacity ring (O(1) per event) and counts dropped events. Its capacity is clamped to 1...65,536 and storage grows on demand, so a hostile `capacity: .max` cannot trap the allocator. `ParityLedger` caps its distinct keys (4096 by default). Counters use saturating arithmetic. No `Int(Double)` conversion can be reached with non-finite input.

**10. Telemetry never carries payload text.** Events carry feature ID, provider ID, jurisdictions and reasons. Telemetry that logs the input is a residency leak of its own (`testTelemetryNeverContainsPayload`).

**11. Kill-switch edits are an atomic read-modify-write inside the actor.** `updateKillSwitches { config in ... }` runs the change with no suspension point and applies it as version + 1. Two operators, or two quick taps, therefore combine their changes instead of the second one failing as stale (`testConcurrentKillSwitchUpdatesCompose`). `toggleProviderKill(_:)` goes one step further: it takes the kill's scope (the jurisdictions binding at that instant) inside the same atomic step, so a region change cannot slip in between reading the scope and writing the switch. A config delivered from outside still goes through `apply`, which accepts only strictly newer versions.

**12. UIs read one atomic snapshot, not several properties.** Reading `providers`, `jurisdictions`, `preview`, `parity` and `config` as five separate `await`s can interleave with other updates and mix states from different moments. `snapshot(for:)` returns all of them, plus the providers killed in the current scope, in a single actor hop. The console renders only from snapshots, and a refresh token makes sure only the newest one is published.

**13. Deadlines belong to adapters, not to the plane.** This is a known limit, by design. Structured concurrency cannot abandon a child task that ignores cancellation, so a plane-side timer would either still wait for a hung adapter or leak it. Adapters therefore own their deadlines (for example `URLRequest.timeoutInterval` or the model runtime's own timeout) and throw `ProviderError.timedOut`. The plane treats that like any other failure, so the breaker and failover engage. Cancelling the caller's task still ends the request.
*Rejected:* racing every call against `Task.sleep` in a task group. It looks like a timeout but blocks on exit until the hung child finishes, which is exactly the case it was meant to handle.

### Scaling and rollout (how this would be operated)

This package covers the client side. The fleet-scale parts it is designed to plug into are listed here, and **none of them is implemented in this repo**:

- **Config fan-out.** `PlaneConfig` is a small, versioned value. It is meant to be served from a CDN as a signed document per app version, and fetched on launch and on push. Because versions only move forward, CDN lag and retries are harmless: an old copy is rejected and never applied.
- **Staged rollout.** A new provider or ranking change ships behind a kill switch, already killed, and is then enabled one jurisdiction at a time. A jurisdiction-scoped `KillSwitch` is the rollback.
- **Telemetry volume.** Events are structured and contain no payload, and the in-process buffer is bounded. Sampling and aggregation belong in the uploader, so a regional incident can't turn into a flood of telemetry.
- **Parity measurement.** `ParityLedger` scores are expected to come from an offline eval job run per market and delivered with the config, not computed on the device.

### Alternatives considered

- **A server-side router for every request.** This gives central control, but it breaks on-device-only flows, adds a network round trip for capabilities that could run locally, and itself becomes a cross-border data flow. The plane is built so a server *delivers policy* and the device *enforces it*.
- **Per-feature provider choice.** This is what most apps do today. It works for one feature and one market, and becomes impossible to review at five features and four markets.
- **A vendor SDK's built-in routing.** It is convenient, but each vendor routes only to itself, and residency rules belong to the app, not the vendor.

## Usage

```swift
.package(url: "https://github.com/rajatslakhina/ai-capability-plane-kit.git", from: "1.1.0")
```

```swift
import CapabilityPlane

let plane = CapabilityPlane(
    adapters: [appleOnDevice, regionalCN, claudeUS],          // your ProviderAdapter types
    config: PlaneConfig(version: 1, residency: residency, parityFloor: 0.6),
    context: RegionContext(storefront: us, deviceRegion: us, osVersion: OSVersion(27, 2)),
    jurisdictionMap: JurisdictionMap(mapping: [us: .unitedStates, cn: .china]))

let outcome = await plane.perform(
    CapabilityRequest(featureID: "notes.summary", capability: .summarize,
                      dataClass: .personal, input: noteText))

switch outcome.kind {
case .served(let provider, let text): show(text, attribution: provider)
case .degraded(let fallback, _):      show(fallback)       // still useful, never wrong-region
}

// Remote config: strictly newer or rejected.
try await plane.apply(config.with(version: 2, killSwitches: [KillSwitch(jurisdiction: .china, capability: .assistant)]))
// Region/OS change: in-flight answers are re-audited when they return.
await plane.updateContext(newContext)
```

`plane.preview(request)` returns the full `Decision` without sending anything: the ranked chain, plus every rejected provider with *all* the reasons it was rejected. `plane.snapshot(for:)` returns that decision together with the context, config, parity and killed providers, all read atomically. The demo console renders exactly this.

Use **1.1.0 or later**. v1.0.0's auditor checked the descriptors a resolver returned rather than the registered ones. That only matters with a custom `CapabilityResolving`, but there is no reason to stay on it.

## Tests

**70 XCTest cases** in the core test target, which runs on Linux and macOS, plus **5 console-model tests**, which run where SwiftUI exists (macOS CI):

- **`PolicyEngineTests` (22).**
  - Every market scenario: US, EU, China before and after 27.3, the US-account traveller in China, sensitive data (exact chains, not `allSatisfy`), unknown countries, missing rules, kill-switch wildcards and de-duplication, offline, open circuits, the parity floor and ranking, the chain-length cap, and determinism under reordered input.
  - The **grid invariant**: across 360 cases (4 storefronts × 3 regions × 2 OS versions × 5 capabilities × 3 data classes), `PolicyEngine` never returns a provider that breaks a hard rule, *and* returns a non-empty chain in more than 100 of them.
- **`CapabilityPlaneTests` (32).**
  - Plane behavior: failover within policy, degradation, the dispatch bound, re-routing after a region change, missing adapters, and the iteration cap against a resolver that invents providers.
  - **Trust boundary**: the auditor blocking a resolver that ignores every rule, and one that forges a registered descriptor (contributed as a probe by the round-3 reviewer). It also covers a forged descriptor that still cannot dodge a kill switch, and an empty jurisdiction list failing closed.
  - **Reentrancy**: a kill switch, a region change or an OS-version change while a provider call is parked on a gate, plus a control test where an unrelated change keeps the answer.
  - **Breaker concurrency**: one probe at a time, late successes and late failures checked by epoch, the breaker enforced (and the skip reported) even against a resolver that ignores it, and a probe cancelled mid-call.
  - Configs and operations: cancellation, stale and replayed configs, atomic kill-switch updates that compose, the scope of `toggleProviderKill`, a consistent `snapshot(for:)`, the generation bumping on connectivity changes, circuit open → probe → close, telemetry without payload, and duplicate provider IDs.
- **`ValueTypeTests` (16).**
  - Parsing that never traps, e.g. `OSVersion(string: "99999999999999999999999")` returns nil.
  - Rejection descriptions built from NaN or infinite scores.
  - Parity scores: NaN, infinity, out-of-range values, the key cap, and gap tie-breaking.
  - Breaker transitions, clamps and epochs; saturating arithmetic; the ring-buffer telemetry sink (including hostile capacities) under 8 concurrent writers; and the no-AI fallback.
- **`ConsoleModelTests` (5, macOS).** Rapid kill toggles that compose and match the plane; a kill tapped right after a picker change, before any refresh, landing on the on-screen region; the "Killed" label following the current region; a run result dropped when the request changed mid-flight; and the default state showing a served outcome.

**Non-vacuous by construction.** Each property the README relies on has a test that fails against a deliberately broken implementation:

- The grid invariant is paired with `testInvariantCheckCatchesABrokenResolver`, which runs against a resolver that ignores every rule and must see more than 100 violations.
- `testGridGuardCatchesAnAlwaysEmptyResolver` shows that a resolver rejecting everything is caught by the non-empty assertion rather than passing silently.
- Mutation checks were run by hand on scratch copies. Each mutation fails the test written for it:
  - Removing `beginProbe`, the breaker-epoch guard, or `abandonProbe` from `CapabilityPlane.perform`.
  - For v1.1.0: auditing the resolver's copy again (the v1.0.0 behaviour); ignoring OS-only and connectivity-only context changes; demoting `.noBindingJurisdiction` to a soft reason; dropping the circuit-open skip report; removing the plane-side breaker guard; and scoping `toggleProviderKill` or the snapshot's killed set wrongly.
- The reentrancy tests use a gate actor rather than sleeps, so the policy change provably happens *while* the provider call is suspended.

## Verification

What has actually been run, and where:

- **v1.1.0:** _CI results are added here once the first runs for this version report._
- **v1.0.0 (history)** ([Actions tab](https://github.com/rajatslakhina/ai-capability-plane-kit/actions/workflows/ci.yml)):
  - **Linux** (`swift:6.0`): build with warnings as errors, then **64 tests, 0 failures**.
  - **macOS** (`macos-15`): **68 tests, 0 failures** (64 core plus 4 `ConsoleModelTests`), then an iOS Simulator build of every product.
  - The demo app, built against v1.0.0 resolved from GitHub, launched on an iPhone Duo Simulator (iOS 27.2) and served a request after a simulated on-device outage.
- **Independent review:** three rounds by fresh reviewers with no build context. Round 1 found 10 issues and all were fixed. Round 2 passed. Round 3 found two blocking issues in the published v1.0.0, both fixed in v1.1.0:
  - The auditor trusted the descriptors a resolver returned.
  - The telemetry buffer trapped on a huge capacity.

  Round 3 also raised several non-blocking gaps, all addressed in v1.1.0. Three rounds is this project's review ceiling, so **the v1.1.0 fixes have not been independently re-reviewed**. They are covered by the round-3 reviewer's own probe test, which now passes, and by the mutation checks above.

## Requirements

Swift 6.0 (Swift 6 language mode, typed throws). iOS 17+ and macOS 14+ for the Apple platforms. The core module also builds and tests on Linux. `CapabilityPlaneUI` compiles only where SwiftUI is available.

## License

MIT
