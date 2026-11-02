import XCTest
@testable import CapabilityPlane

final class ValueTypeTests: XCTestCase {

    func testCountryCodeValidation() {
        XCTAssertEqual(CountryCode("cn")?.rawValue, "CN")
        XCTAssertNil(CountryCode(""))
        XCTAssertNil(CountryCode("USA"))
        XCTAssertNil(CountryCode("1A"))
        XCTAssertNil(CountryCode("Ü1"))
        XCTAssertNil(CountryCode("ÜS"))
    }

    func testOSVersionParsingNeverTraps() {
        XCTAssertEqual(OSVersion(string: "27.3"), OSVersion(27, 3))
        XCTAssertEqual(OSVersion(string: "27"), OSVersion(27))
        XCTAssertEqual(OSVersion(string: "27.3.1"), OSVersion(27, 3, 1))
        for bad in ["", "a", "27.", ".3", "27.3.1.4", "-1", "27.-1", "99999999999999999999999"] {
            XCTAssertNil(OSVersion(string: bad), bad)
        }
        XCTAssertEqual(OSVersion(-4, -1, -9), OSVersion(0))
    }

    func testOSVersionOrdering() {
        XCTAssertLessThan(OSVersion(27, 2), OSVersion(27, 3))
        XCTAssertLessThan(OSVersion(27, 3), OSVersion(27, 3, 1))
        XCTAssertLessThan(OSVersion(26, 9, 9), OSVersion(27))
        XCTAssertEqual(OSVersion(27, 3).description, "27.3")
        XCTAssertEqual(OSVersion(27, 3, 1).description, "27.3.1")
    }

    func testParityLedgerRejectsNonFiniteAndOutOfRange() {
        var ledger = ParityLedger()
        XCTAssertFalse(ledger.record(.nan, jurisdiction: .china, capability: .summarize, providerID: "p"))
        XCTAssertFalse(ledger.record(.infinity, jurisdiction: .china, capability: .summarize, providerID: "p"))
        XCTAssertFalse(ledger.record(1.01, jurisdiction: .china, capability: .summarize, providerID: "p"))
        XCTAssertFalse(ledger.record(-0.01, jurisdiction: .china, capability: .summarize, providerID: "p"))
        XCTAssertTrue(ledger.scores.isEmpty)
        XCTAssertTrue(ledger.record(1, jurisdiction: .china, capability: .summarize, providerID: "p"))
    }

    func testParityGap() {
        var ledger = ParityLedger()
        ledger.record(0.91, jurisdiction: .unitedStates, capability: .summarize, providerID: "apple")
        XCTAssertNil(ledger.parityGap(for: .summarize), "one market is not a gap")
        ledger.record(0.62, jurisdiction: .china, capability: .summarize, providerID: "cn")
        ledger.record(0.78, jurisdiction: .china, capability: .summarize, providerID: "apple")
        ledger.record(0.50, jurisdiction: .china, capability: .translate, providerID: "cn")
        let gap = ledger.parityGap(for: .summarize)
        XCTAssertEqual(gap?.best, .unitedStates)
        XCTAssertEqual(gap?.worst, .china)
        XCTAssertEqual(gap?.worstScore, 0.78, "uses the best provider per market")
        XCTAssertEqual(gap?.spread ?? 0, 0.13, accuracy: 1e-9)
    }

    func testHealthBoardTransitions() {
        var board = HealthBoard(failureThreshold: 2, cooldown: 10)
        board.recordFailure("p", now: 0)
        XCTAssertEqual(board.verdict(for: "p", now: 0), .healthy)
        board.recordFailure("p", now: 1)
        XCTAssertEqual(board.verdict(for: "p", now: 5), .open)
        XCTAssertEqual(board.verdict(for: "p", now: 11), .probeAllowed)
        board.beginProbe("p")
        XCTAssertEqual(board.verdict(for: "p", now: 11), .open, "only one probe at a time")
        board.recordFailure("p", now: 12)
        XCTAssertEqual(board.verdict(for: "p", now: 21), .open, "cooldown restarts after a failed probe")
        XCTAssertEqual(board.verdict(for: "p", now: 22), .probeAllowed)
        board.beginProbe("p")
        board.recordSuccess("p")
        XCTAssertEqual(board.verdict(for: "p", now: 22), .healthy)
    }

    func testHealthBoardIgnoresResultsFromAnEarlierEpoch() {
        var board = HealthBoard(failureThreshold: 2, cooldown: 10)
        let atDispatch = board.epoch(for: "p")
        board.recordFailure("p", now: 0)
        XCTAssertEqual(board.epoch(for: "p"), atDispatch, "counting failures in closed is not a phase change")
        board.recordFailure("p", now: 0)
        XCTAssertFalse(board.recordSuccess("p", ifEpoch: atDispatch))
        XCTAssertEqual(board.verdict(for: "p", now: 1), .open)
        XCTAssertFalse(board.recordFailure("p", now: 5, ifEpoch: atDispatch))
        XCTAssertEqual(board.verdict(for: "p", now: 10), .probeAllowed, "stale failure did not restart the cooldown")
        XCTAssertTrue(board.recordSuccess("p", ifEpoch: board.epoch(for: "p")))
        XCTAssertEqual(board.verdict(for: "p", now: 10), .healthy)
    }

    func testHealthBoardClampsAndAbandonedProbe() {
        var board = HealthBoard(failureThreshold: 0, cooldown: .nan)
        XCTAssertEqual(board.failureThreshold, 1)
        XCTAssertEqual(board.cooldown, 30)
        board.recordFailure("p", now: 100)
        board.beginProbe("p")
        board.abandonProbe("p", now: 100)
        XCTAssertEqual(board.verdict(for: "p", now: 100), .probeAllowed)
    }

    func testRejectionDescriptionNeverTrapsOnHostileScores() {
        XCTAssertEqual(RejectionReason.belowParityFloor(score: .nan, floor: .infinity, in: .china).description,
                       "eval n/a < floor n/a in CN")
        XCTAssertEqual(RejectionReason.belowParityFloor(score: 0.555, floor: 7, in: .china).description,
                       "eval 56% < floor 100% in CN")
    }

    func testSaturatingArithmetic() {
        XCTAssertEqual(Int.max.saturatingAdd(1), Int.max)
        XCTAssertEqual(Int.min.saturatingAdd(-1), Int.min)
        XCTAssertEqual(2.saturatingAdd(3), 5)
        XCTAssertEqual(UInt64.max.saturatingIncrement(), UInt64.max)
        XCTAssertEqual(UInt64(4).saturatingIncrement(), 5)
    }

    func testBoundedTelemetryBuffer() {
        let buffer = BoundedTelemetryBuffer(capacity: 0)
        XCTAssertEqual(buffer.capacity, 1)
        buffer.record(.configApplied(version: 1))
        buffer.record(.configApplied(version: 2))
        XCTAssertEqual(buffer.events, [.configApplied(version: 2)])
        XCTAssertEqual(buffer.droppedCount, 1)

        let ring = BoundedTelemetryBuffer(capacity: 3)
        for v in 1...5 { ring.record(.configApplied(version: UInt64(v))) }
        XCTAssertEqual(ring.events, [3, 4, 5].map { PlaneEvent.configApplied(version: $0) }, "oldest-first after wrap")
        XCTAssertEqual(ring.droppedCount, 2)
    }

    func testParityLedgerIsBoundedAndGapTiesAreDistinct() {
        var ledger = ParityLedger(maxEntries: 2)
        XCTAssertTrue(ledger.record(0.8, jurisdiction: .china, capability: .summarize, providerID: "a"))
        XCTAssertTrue(ledger.record(0.8, jurisdiction: .unitedStates, capability: .summarize, providerID: "a"))
        XCTAssertFalse(ledger.record(0.5, jurisdiction: .europeanUnion, capability: .summarize, providerID: "a"))
        XCTAssertTrue(ledger.record(0.7, jurisdiction: .china, capability: .summarize, providerID: "a"), "updates always allowed")
        ledger.record(0.8, jurisdiction: .china, capability: .summarize, providerID: "a")
        let gap = ledger.parityGap(for: .summarize)
        XCTAssertNotEqual(gap?.best, gap?.worst)
        XCTAssertEqual(gap?.spread, 0)
    }

    func testBoundedTelemetryBufferUnderConcurrentWriters() async {
        let buffer = BoundedTelemetryBuffer(capacity: 50)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    for j in 0..<100 { buffer.record(.configApplied(version: UInt64(i * 1000 + j))) }
                }
            }
        }
        XCTAssertEqual(buffer.events.count, 50)
        XCTAssertEqual(buffer.droppedCount, 750)
    }

    func testNoAIFallback() {
        func render(_ c: Capability, _ input: String) -> String {
            NoAIFallback.render(CapabilityRequest(featureID: "f", capability: c, dataClass: .personal, input: input))
        }
        XCTAssertEqual(render(.summarize, "Hello there. More."), "Hello there")
        XCTAssertEqual(render(.summarize, ""), "")
        XCTAssertEqual(render(.summarize, "..."), "")
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(render(.summarize, long).count, NoAIFallback.summaryCharacterLimit + 1)
        XCTAssertEqual(render(.translate, "bonjour"), "bonjour")
        XCTAssertEqual(render(.extract, "x"), "")
        XCTAssertFalse(render(.assistant, "x").isEmpty)
    }

    func testJurisdictionBindingIsDeduplicatedAndSorted() {
        XCTAssertEqual(Fleet.map.bindingJurisdictions(for: Fleet.context("DE", "FR")), [.europeanUnion])
        XCTAssertEqual(Fleet.map.bindingJurisdictions(for: Fleet.context("US", "DE")), [.europeanUnion, .unitedStates])
    }

    func testSimulatedAdapterHonoursFailureSwitch() async throws {
        let failure = FailureSwitch()
        let adapter = SimulatedProviderAdapter(descriptor: Fleet.apple, failure: failure)
        let ok = try await adapter.execute(Fleet.request())
        XCTAssertTrue(ok.hasPrefix("[Apple on-device] summarize"))
        failure.isOn = true
        do { _ = try await adapter.execute(Fleet.request()); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ProviderError, .unavailable("apple.ondevice")) }
    }
}
