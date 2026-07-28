import XCTest
@testable import LaunchBudgetCore

/// Trace attribution — including the re-entrancy case that silently inflates every
/// naive implementation's numbers.
final class TraceAttributionTests: XCTestCase {

    private func trace(_ specs: [SampleWorkspace.SampleSpec], interval: UInt64 = 1_000_000) -> LaunchTrace {
        SampleWorkspace.trace(label: "test", specs: specs, sampleIntervalNanos: interval)
    }

    // MARK: Empty and degenerate

    func testEmptyTraceProducesNoAttributionAndNoDivisionByZero() {
        let empty = LaunchTrace(label: "empty", sampleIntervalNanos: 1_000_000, samples: [])
        XCTAssertTrue(empty.attribution().isEmpty)
        XCTAssertTrue(empty.rankedAttribution().isEmpty)
        XCTAssertEqual(empty.durationMilliseconds, 0)
        XCTAssertEqual(empty.timeToFirstFrameMilliseconds, 0)
        XCTAssertEqual(empty.unattributedSampleCount, 0)
        XCTAssertNil(empty.rankedAttribution(at: 0))
    }

    func testZeroSampleIntervalIsClampedRatherThanMakingEveryDurationZero() {
        let degenerate = LaunchTrace(
            label: "bad",
            sampleIntervalNanos: 0,
            samples: [LaunchSample(timestampNanos: 0, stack: ["A"], phase: .preMain)]
        )
        XCTAssertEqual(degenerate.sampleIntervalNanos, 1)
        XCTAssertGreaterThan(degenerate.durationMilliseconds, 0)
    }

    func testEmptyStacksAreCountedAsUnattributedNotChargedToAnyone() {
        let subject = LaunchTrace(
            label: "partial",
            sampleIntervalNanos: 1_000_000,
            samples: [
                LaunchSample(timestampNanos: 0, stack: [], phase: .preMain),
                LaunchSample(timestampNanos: 1_000_000, stack: [], phase: .preMain),
                LaunchSample(timestampNanos: 2_000_000, stack: ["A"], phase: .preMain)
            ]
        )
        XCTAssertEqual(subject.unattributedSampleCount, 2)
        XCTAssertEqual(subject.unattributedMilliseconds, 2, accuracy: 0.0001)
        XCTAssertEqual(subject.attribution().count, 1)
        XCTAssertEqual(subject.attribution()[ModuleID("A")]?.selfMilliseconds, 1)
    }

    // MARK: Index safety

    func testRankedAttributionAtOutOfRangeIndexReturnsNilRatherThanTrapping() {
        let subject = trace([.init(["A"], phase: .preMain, count: 3)])
        XCTAssertNotNil(subject.rankedAttribution(at: 0))
        XCTAssertNil(subject.rankedAttribution(at: 1))
        XCTAssertNil(subject.rankedAttribution(at: 99))
        XCTAssertNil(subject.rankedAttribution(at: -1))
        XCTAssertNil(subject.rankedAttribution(at: Int.min))
        XCTAssertNil(subject.rankedAttribution(at: Int.max))
    }

    // MARK: Self vs total

    func testSelfTimeIsChargedToTheLeafOnly() {
        let subject = trace([.init(["App", "Feature", "Networking"], phase: .preFirstFrame, count: 10)])
        let attribution = subject.attribution()
        XCTAssertEqual(attribution[ModuleID("Networking")]?.selfMilliseconds, 10)
        XCTAssertEqual(attribution[ModuleID("Feature")]?.selfMilliseconds, 0)
        XCTAssertEqual(attribution[ModuleID("App")]?.selfMilliseconds, 0)
    }

    func testTotalTimeIsChargedToEveryFrame() {
        let subject = trace([.init(["App", "Feature", "Networking"], phase: .preFirstFrame, count: 10)])
        let attribution = subject.attribution()
        XCTAssertEqual(attribution[ModuleID("App")]?.totalMilliseconds, 10)
        XCTAssertEqual(attribution[ModuleID("Feature")]?.totalMilliseconds, 10)
        XCTAssertEqual(attribution[ModuleID("Networking")]?.totalMilliseconds, 10)
    }

    func testRecursiveStackChargesTotalTimeOnce() {
        // A → B → A → B → A. Without the per-sample dedupe, A would be charged 3x and
        // B 2x for a single sample, and the module with the deepest re-entrancy would
        // always top the report regardless of its real cost.
        let subject = trace([.init(["A", "B", "A", "B", "A"], phase: .preMain, count: 4)])
        let attribution = subject.attribution()
        XCTAssertEqual(attribution[ModuleID("A")]?.totalMilliseconds, 4, "A must be charged once per sample")
        XCTAssertEqual(attribution[ModuleID("B")]?.totalMilliseconds, 4, "B must be charged once per sample")
        XCTAssertEqual(attribution[ModuleID("A")]?.selfMilliseconds, 4, "A is the leaf")
        XCTAssertEqual(attribution[ModuleID("B")]?.selfMilliseconds, 0)
    }

    func testSelfTimeSumsToAttributedTraceDuration() {
        let subject = trace([
            .init(["A"], phase: .preMain, count: 5),
            .init(["A", "B"], phase: .preFirstFrame, count: 7),
            .init(["C"], phase: .postFirstFrame, count: 3),
            .init([], phase: .postFirstFrame, count: 2)
        ])
        let summedSelf = subject.attribution().values.reduce(0) { $0 + $1.selfMilliseconds }
        XCTAssertEqual(summedSelf, subject.durationMilliseconds - subject.unattributedMilliseconds, accuracy: 0.0001)
    }

    func testSingleFrameStackChargesSelfAndTotalEqually() {
        let subject = trace([.init(["Solo"], phase: .preMain, count: 6)])
        let entry = subject.attribution()[ModuleID("Solo")]
        XCTAssertEqual(entry?.selfMilliseconds, entry?.totalMilliseconds)
        XCTAssertEqual(entry?.selfSampleCount, 6)
    }

    // MARK: Phase split

    func testSelfTimeIsSplitByPhase() {
        let subject = trace([
            .init(["A"], phase: .preMain, count: 4),
            .init(["A"], phase: .preFirstFrame, count: 6),
            .init(["A"], phase: .postFirstFrame, count: 10)
        ])
        let entry = try? XCTUnwrap(subject.attribution()[ModuleID("A")])
        XCTAssertEqual(entry?.selfMilliseconds(in: .preMain), 4)
        XCTAssertEqual(entry?.selfMilliseconds(in: .preFirstFrame), 6)
        XCTAssertEqual(entry?.selfMilliseconds(in: .postFirstFrame), 10)
        XCTAssertEqual(entry?.selfMilliseconds, 20)
    }

    func testTimeToFirstFrameExcludesPostFirstFrameWork() {
        let subject = trace([
            .init(["A"], phase: .preMain, count: 10),
            .init(["A"], phase: .preFirstFrame, count: 20),
            .init(["A"], phase: .postFirstFrame, count: 100)
        ])
        XCTAssertEqual(subject.timeToFirstFrameMilliseconds, 30, accuracy: 0.0001)
        XCTAssertEqual(subject.durationMilliseconds, 130, accuracy: 0.0001)
    }

    func testPhaseWithNoSamplesReportsZeroNotNil() {
        let subject = trace([.init(["A"], phase: .preMain, count: 3)])
        XCTAssertEqual(subject.durationMilliseconds(in: .postFirstFrame), 0)
        let entry = subject.attribution()[ModuleID("A")]
        XCTAssertEqual(entry?.selfMilliseconds(in: .postFirstFrame), 0)
    }

    // MARK: Ranking

    func testRankingIsBySelfTimeDescendingWithDeterministicTieBreak() {
        let subject = trace([
            .init(["Zulu"], phase: .preMain, count: 5),
            .init(["Alpha"], phase: .preMain, count: 5),
            .init(["Heavy"], phase: .preMain, count: 9)
        ])
        for _ in 0..<20 {
            XCTAssertEqual(subject.rankedAttribution().map(\.module), ["Heavy", "Alpha", "Zulu"])
        }
    }

    // MARK: Sample specs

    func testNegativeSampleCountIsClampedToZero() {
        let spec = SampleWorkspace.SampleSpec(["A"], phase: .preMain, count: -5)
        XCTAssertEqual(spec.count, 0)
        XCTAssertTrue(trace([spec]).samples.isEmpty)
    }

    // MARK: Codable round trip

    func testTraceSurvivesACodableRoundTrip() throws {
        // Traces are written by a capture step and read by the gate in a separate
        // process, so the encoding has to actually work end to end.
        let original = SampleWorkspace.baselineTrace
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LaunchTrace.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rankedAttribution().map(\.module), original.rankedAttribution().map(\.module))
    }
}
