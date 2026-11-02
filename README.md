# CapabilityPlane

**Your AI feature now has a geography.** This Swift package is a region-aware AI capability plane for iOS. A feature asks for a *capability* (`summarize`, `translate`, `extract`, `rewrite`, `assistant`), never for a model. The plane picks a provider for this storefront, this device region, this OS version and this kind of data. It can choose on-device Apple Intelligence, a cloud provider hosted in the region, a frontier cloud model, or a local fallback with no AI at all.

[![CI](https://github.com/rajatslakhina/ai-capability-plane-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/ai-capability-plane-kit/actions/workflows/ci.yml)

Demo app: (link added after the companion repo is pushed)

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
 │  ResidencyAuditor (independent re-check of every hard rule)             │
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
| Enforcement | `ResidencyAuditor`, `CapabilityPlane` | Re-checks every hard rule before any data is sent, and again after every `await`. |
| Providers | `ProviderDescriptor`, `ProviderOffer`, `ProviderAdapter`, `SimulatedProviderAdapter` | Each market's offer per provider. Adapters execute requests and never see policy. |
| Operations | `HealthBoard`, `PlaneClock`, `TelemetrySink`, `BoundedTelemetryBuffer` | Circuit breaking, injectable time, and bounded telemetry. |
| UI (`CapabilityPlaneUI`) | `CapabilityConsoleModel`, `CapabilityConsoleView` | A SwiftUI console that shows the decision trace. Compiled only where SwiftUI exists. |

## Design decisions and trade-offs

**1. When storefront and device region disagree, both rule sets apply ("strictest wins").** Take a US account on a device in China. A provider must satisfy US rules *and* Chinese rules. On iOS 27.2 nothing qualifies, so the feature falls back to the version with no AI. On 27.3, on-device processing qualifies.
*Rejected:* using only the storefront, which is simple but sends data across a border the device is physically inside. Also rejected: using only the device region, which changes with travel or a settings toggle and ignores the account's legal terms. The cost of this choice is more fallback with no AI for travellers. That cost shows up in the decision trace and can be traded off on purpose.

**2. Hard and soft constraints are kept separate, and hard ones are enforced twice.** Hard constraints are legal and contractual: offered here, capability supported, OS version, residency, kill switch. Soft constraints are operational: offline, circuit open, eval parity. `CapabilityResolving` is a protocol, so ranking can be A/B tested or driven from a server. Every chain it returns still passes through `ResidencyAuditor` before any data is sent. A broken resolver can make ranking worse but cannot break residency. `testAuditorBlocksABrokenResolverBeforeDispatch` checks this with a resolver that ignores every rule.
*Rejected:* trusting the resolver. That is one bug away from sending personal data to the wrong country.

**3. Missing residency rules mean on-device only.** A `(jurisdiction, data class)` pair with no rule allows only on-device processing. An empty jurisdiction list approves nothing (`.noBindingJurisdiction`). A new market or a typo in config makes features worse. It never makes them leak.
*Trade-off:* a forgotten rule shows up as a quality regression rather than an incident. That is the right way round.

**4. Configs apply only if their version is strictly newer.** Kill switches arrive inside a versioned `PlaneConfig`. If an old payload arrives late (CDN lag, retries, an offline queue), it is rejected with `ConfigError.stale`. It cannot bring back a provider that a newer config killed (`testReplayCannotResurrectAKilledProvider`).
*Rejected:* last-write-wins, which is how an emergency kill switch quietly turns itself off an hour later.

**5. Actor reentrancy: take a fresh snapshot for each attempt, and re-audit after every `await`.** While a provider call is in flight, the user can change region, or a kill switch can arrive. When the adapter returns, the plane re-audits that provider against the *current* context and config. If the provider is no longer allowed, the answer is thrown away (`.discardedAfterPolicyChange`) and the next eligible provider is tried. The payload has already left the device, so the plane cannot un-send it, but it can refuse to use the answer. Each failover attempt resolves against fresh state, so failover never uses a decision made before the context changed.
*Rejected:* resolving once per request, which uses a decision made before the last `await`, exactly the bug Swift actor reentrancy makes easy.

**6. Failover stays inside policy.** The failover chain is the list of eligible providers and nothing else. If Apple's on-device model fails in the US, the request fails over to the US-hosted cloud. It never fails over to the CN- or EU-hosted one (`testFailsOverWithinPolicyOnly`). When every eligible provider fails, the feature gets `NoAIFallback`: a deterministic local result. Summarize returns the first sentence. Translate and rewrite return the original text. It never "fails open" to a provider that policy rejected.

**7. Eval parity is part of policy.** `ParityLedger` stores eval scores per (jurisdiction, capability, provider). Providers below `parityFloor` in any binding jurisdiction are rejected, so a weak regional model gives way to the no-AI fallback instead of shipping bad answers. `parityGap(for:)` makes the quality gap between markets a number someone owns. NaN and out-of-range scores are rejected when recorded, because a NaN in a sort comparator breaks strict weak ordering.

**8. Circuit-breaker results are checked by epoch after every `await`.** A request sent while the breaker was closed can come back after other requests have opened it. Without a guard, that late success would close the breaker and skip the cooldown and probe. `HealthBoard` bumps a per-provider epoch on every phase change (closed, open, half-open). The plane records the epoch when it dispatches and drops results from an older epoch. The plane also checks the breaker itself before dispatching, so even a custom resolver that ignores `circuitOpen` cannot send to an open breaker. Only one probe runs at a time while the breaker is half-open. A probe cancelled mid-call is released immediately, so the breaker doesn't stay half-open waiting on a probe that will never finish (`testOnlyOneProbeAtATime`, `testLateSuccessDoesNotCloseABreakerThatOpenedMeanwhile`, `testCancellingAProbeMidCallReleasesIt`, `testLateFailureDoesNotRestartTheCooldown`, `testBreakerIsEnforcedEvenForAResolverThatIgnoresIt`).

**9. Bounded everything.** At most `maxAttempts` dispatches (clamped to 1...8). There is a hard limit on loop iterations, so a resolver that keeps inventing unregistered providers cannot make the plane spin (`testIterationCapStopsAResolverThatInventsProviders`). The telemetry buffer is a fixed-capacity ring (O(1) per event) and counts dropped events. `ParityLedger` caps its distinct keys (4096 by default). Counters use saturating arithmetic. No `Int(Double)` conversion can be reached with non-finite input.

**10. Telemetry never carries payload text.** Events carry feature ID, provider ID, jurisdictions and reasons. Telemetry that logs the input is a residency leak of its own (`testTelemetryNeverContainsPayload`).

**11. Kill-switch edits are an atomic read-modify-write inside the actor.** `updateKillSwitches { config in ... }` runs the change with no suspension point and applies it as version + 1. Two operators, or two quick taps, therefore combine their changes instead of the second one failing as stale (`testConcurrentKillSwitchUpdatesCompose`). A config delivered from outside still goes through `apply`, which accepts only strictly newer versions.

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
.package(url: "https://github.com/rajatslakhina/ai-capability-plane-kit.git", from: "1.0.0")
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

`plane.preview(request)` returns the full `Decision` without sending anything: the ranked chain, plus every rejected provider with *all* the reasons it was rejected. The demo console renders exactly this.

## Tests

**64 XCTest cases** in the core test target, which runs on Linux and macOS, plus **4 console-model tests**, which run where SwiftUI exists (macOS CI):

- **`PolicyEngineTests` (22).**
  - Every market scenario: US, EU, China before and after 27.3, the US-account traveller in China, sensitive data (exact chains, not `allSatisfy`), unknown countries, missing rules, kill-switch wildcards and de-duplication, offline, open circuits, the parity floor and ranking, the chain-length cap, and determinism under reordered input.
  - The **grid invariant**: across 360 cases (4 storefronts × 3 regions × 2 OS versions × 5 capabilities × 3 data classes), `PolicyEngine` never returns a provider that breaks a hard rule, *and* returns a non-empty chain in more than 100 of them.
- **`CapabilityPlaneTests` (26).**
  - Plane behavior: failover within policy, degradation, the dispatch bound, re-routing after a region change, the auditor blocking a broken resolver, missing adapters, and the iteration cap against a resolver that invents providers.
  - **Reentrancy**: a kill switch or region change while a provider call is parked on a gate, plus a control test where an unrelated change keeps the answer.
  - **Breaker concurrency**: one probe at a time, late successes and late failures checked by epoch, the breaker enforced even against a resolver that ignores it, the empty-jurisdiction fail-closed case, and a probe cancelled mid-call.
  - Configs and operations: cancellation, stale and replayed configs, atomic kill-switch updates that compose, circuit open → probe → close, telemetry without payload, and duplicate provider IDs.
- **`ValueTypeTests` (16).**
  - Parsing that never traps, e.g. `OSVersion(string: "99999999999999999999999")` returns nil.
  - Rejection descriptions built from NaN or infinite scores.
  - Parity scores: NaN, infinity, out-of-range values, the key cap, and gap tie-breaking.
  - Breaker transitions, clamps and epochs; saturating arithmetic; the ring-buffer telemetry sink under 8 concurrent writers; and the no-AI fallback.
- **`ConsoleModelTests` (4, macOS).** Rapid kill toggles that compose and match the plane, the "Killed" label following the current region, a run result dropped when the request changed mid-flight, and the default state showing a served outcome.

**Non-vacuous by construction.** Each property the README relies on has a test that fails against a deliberately broken implementation:

- The grid invariant is paired with `testInvariantCheckCatchesABrokenResolver`, which runs against a resolver that ignores every rule and must see more than 100 violations.
- `testGridGuardCatchesAnAlwaysEmptyResolver` shows that a resolver rejecting everything is caught by the non-empty assertion rather than passing silently.
- Mutation checks were run by hand on a scratch copy. Removing `beginProbe`, the breaker-epoch guard, or `abandonProbe` from `CapabilityPlane.perform` each fails exactly the test written for it.
- The reentrancy tests use a gate actor rather than sleeps, so the policy change provably happens *while* the provider call is suspended.

## Verification

What has actually been run, and where:

- **Linux (Swift 6.0.3), clean build:** `rm -rf .build && swift build -Xswiftc -warnings-as-errors` has 0 warnings, and `swift test -Xswiftc -warnings-as-errors` passes **64/64**.
- **macOS (Xcode 27.2, Apple silicon):**
  - `swift test -Xswiftc -warnings-as-errors` passes the core suite plus the 4 `ConsoleModelTests`.
  - `xcodebuild build -scheme CapabilityPlane-Package -destination 'generic/platform=iOS Simulator'` builds every product, including the SwiftUI target.
- **iOS Simulator:** the companion demo app was built, installed and launched on an iPhone Duo Simulator (iOS 27.2) in four scripted scenarios, and screenshotted with `simctl`. Those runs resolved this package from a **local checkout**, not from a GitHub tag. See the demo repo for details.
- **Independent review:** two rounds of review by a fresh reviewer with no build context. Round 1 found 10 issues and all were fixed. Round 2 passed. Its one recommended fix and its nits were then applied, and those last changes were not re-reviewed.
- **GitHub Actions CI:** the workflow in `.github/workflows/ci.yml` has two jobs. The Linux job runs build and test with warnings as errors. The macOS job runs `swift test` and the iOS Simulator build. **CI has not run yet**: this copy was prepared before the repository was published. This section will be updated with the first real run.

## Requirements

Swift 6.0 (Swift 6 language mode, typed throws). iOS 17+ and macOS 14+ for the Apple platforms. The core module also builds and tests on Linux. `CapabilityPlaneUI` compiles only where SwiftUI is available.

## License

MIT
