import XCTest
@testable import LaunchBudgetCore

/// Phase-ordering validation and critical-path computation.
final class StartupScheduleTests: XCTestCase {

    private func item(
        _ id: String,
        _ phase: LaunchPhase,
        _ duration: Double,
        deps: [WorkItemID] = [],
        owner: ModuleID = "Owner"
    ) -> StartupWorkItem {
        StartupWorkItem(
            id: WorkItemID(id),
            owner: owner,
            phase: phase,
            durationMilliseconds: duration,
            dependencies: deps
        )
    }

    // MARK: Validation

    func testEmptyScheduleIsValidAndHasZeroCriticalPath() throws {
        // An app with no declared startup work is unusual but not invalid, and the
        // analysis must degrade to zeros rather than trapping on an empty collection.
        let schedule = try StartupSchedule(items: [])
        let analysis = schedule.criticalPath()
        XCTAssertEqual(schedule.count, 0)
        XCTAssertTrue(analysis.path.isEmpty)
        XCTAssertEqual(analysis.durationMilliseconds, 0)
        XCTAssertEqual(analysis.serialMilliseconds, 0)
        XCTAssertEqual(analysis.deferredMilliseconds, 0)
        XCTAssertNil(analysis.heaviestOwner)
        XCTAssertEqual(analysis.concurrencyHeadroomMilliseconds, 0)
    }

    func testDuplicateWorkItemThrows() {
        XCTAssertThrowsError(try StartupSchedule(items: [
            item("a", .preFirstFrame, 1),
            item("a", .preFirstFrame, 2)
        ])) { error in
            XCTAssertEqual(error as? StartupScheduleError, .duplicateWorkItem("a"))
        }
    }

    func testDanglingDependencyThrows() {
        XCTAssertThrowsError(try StartupSchedule(items: [
            item("a", .preFirstFrame, 1, deps: ["ghost"])
        ])) { error in
            XCTAssertEqual(error as? StartupScheduleError, .unknownDependency(item: "a", missing: "ghost"))
        }
    }

    func testCycleThrows() {
        XCTAssertThrowsError(try StartupSchedule(items: [
            item("a", .preFirstFrame, 1, deps: ["b"]),
            item("b", .preFirstFrame, 1, deps: ["a"])
        ])) { error in
            guard case .cycle? = error as? StartupScheduleError else {
                return XCTFail("expected a cycle, got \(error)")
            }
        }
    }

    // MARK: Phase inversion — the headline invariant

    func testCriticalPathItemDependingOnDeferredWorkIsRejected() {
        // The bug this library exists to make impossible: something on the critical
        // path reads state produced by work that was moved past the first frame.
        XCTAssertThrowsError(try StartupSchedule(items: [
            item("analytics.init", .postFirstFrame, 5),
            item("session.restore", .preFirstFrame, 3, deps: ["analytics.init"])
        ])) { error in
            XCTAssertEqual(
                error as? StartupScheduleError,
                .phaseInversion(
                    item: "session.restore",
                    itemPhase: .preFirstFrame,
                    dependency: "analytics.init",
                    dependencyPhase: .postFirstFrame
                )
            )
        }
    }

    func testPreMainItemDependingOnPostMainWorkIsRejected() {
        XCTAssertThrowsError(try StartupSchedule(items: [
            item("late", .preFirstFrame, 1),
            item("early", .preMain, 1, deps: ["late"])
        ]))
    }

    func testSamePhaseDependencyIsAllowed() throws {
        let schedule = try StartupSchedule(items: [
            item("a", .preFirstFrame, 1),
            item("b", .preFirstFrame, 1, deps: ["a"])
        ])
        XCTAssertEqual(schedule.count, 2)
    }

    func testLaterPhaseDependingOnEarlierPhaseIsAllowed() throws {
        let schedule = try StartupSchedule(items: [
            item("early", .preMain, 1),
            item("late", .postFirstFrame, 1, deps: ["early"])
        ])
        XCTAssertEqual(schedule.count, 2)
    }

    // MARK: Critical path

    func testCriticalPathPicksTheLongestChainNotTheHeaviestItem() throws {
        // `fat` is the single heaviest item but sits alone; the real critical path is
        // the three-item chain. A naive "sum the biggest items" implementation gets
        // this wrong, which is why it is tested explicitly.
        let schedule = try StartupSchedule(items: [
            item("fat", .preFirstFrame, 20),
            item("a", .preFirstFrame, 9),
            item("b", .preFirstFrame, 9, deps: ["a"]),
            item("c", .preFirstFrame, 9, deps: ["b"])
        ])
        let analysis = schedule.criticalPath()
        XCTAssertEqual(analysis.path, ["a", "b", "c"])
        XCTAssertEqual(analysis.durationMilliseconds, 27, accuracy: 0.0001)
        XCTAssertEqual(analysis.serialMilliseconds, 47, accuracy: 0.0001)
        XCTAssertEqual(analysis.concurrencyHeadroomMilliseconds, 20, accuracy: 0.0001)
    }

    func testDiamondTakesTheLongerBranch() throws {
        let schedule = try StartupSchedule(items: [
            item("root", .preFirstFrame, 1),
            item("slow", .preFirstFrame, 10, deps: ["root"]),
            item("fast", .preFirstFrame, 2, deps: ["root"]),
            item("join", .preFirstFrame, 1, deps: ["slow", "fast"])
        ])
        let analysis = schedule.criticalPath()
        XCTAssertEqual(analysis.path, ["root", "slow", "join"])
        XCTAssertEqual(analysis.durationMilliseconds, 12, accuracy: 0.0001)
    }

    func testPostFirstFrameWorkIsExcludedFromTheCriticalPath() throws {
        let schedule = try StartupSchedule(items: [
            item("blocking", .preFirstFrame, 5),
            item("deferred", .postFirstFrame, 100, deps: ["blocking"])
        ])
        let analysis = schedule.criticalPath()
        XCTAssertEqual(analysis.durationMilliseconds, 5, accuracy: 0.0001)
        XCTAssertEqual(analysis.deferredMilliseconds, 100, accuracy: 0.0001)
        XCTAssertFalse(analysis.path.contains("deferred"))
    }

    func testExcludingPreMainChangesTheAnswer() throws {
        let schedule = try StartupSchedule(items: [
            item("images", .preMain, 14),
            item("main", .preFirstFrame, 2, deps: ["images"])
        ])
        XCTAssertEqual(schedule.criticalPath(includePreMain: true).durationMilliseconds, 16, accuracy: 0.0001)
        XCTAssertEqual(schedule.criticalPath(includePreMain: false).durationMilliseconds, 2, accuracy: 0.0001)
    }

    func testOwnerContributionsSumToTheCriticalPathDuration() throws {
        let schedule = try StartupSchedule(items: [
            item("a", .preFirstFrame, 4, owner: "Alpha"),
            item("b", .preFirstFrame, 6, deps: ["a"], owner: "Beta"),
            item("c", .preFirstFrame, 2, deps: ["b"], owner: "Alpha")
        ])
        let analysis = schedule.criticalPath()
        let summed = analysis.ownerContributions.values.reduce(0, +)
        XCTAssertEqual(summed, analysis.durationMilliseconds, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(analysis.ownerContributions[ModuleID("Alpha")]), 6, accuracy: 0.0001)
        XCTAssertEqual(analysis.heaviestOwner?.module, "Alpha")
    }

    func testHeaviestOwnerTieIsBrokenDeterministically() throws {
        let schedule = try StartupSchedule(items: [
            item("a", .preFirstFrame, 5, owner: "Zulu"),
            item("b", .preFirstFrame, 5, deps: ["a"], owner: "Alpha")
        ])
        for _ in 0..<20 {
            XCTAssertEqual(schedule.criticalPath().heaviestOwner?.module, "Alpha")
        }
    }

    // MARK: Duration sanitisation

    func testNaNDurationIsNeutralisedRatherThanPoisoningTheComparison() throws {
        // All comparisons against NaN are false, so an unsanitised NaN would make the
        // longest-path relaxation silently skip every update and report a wrong,
        // confident number.
        let schedule = try StartupSchedule(items: [
            item("bad", .preFirstFrame, Double.nan),
            item("good", .preFirstFrame, 5, deps: ["bad"])
        ])
        let analysis = schedule.criticalPath()
        XCTAssertTrue(analysis.durationMilliseconds.isFinite)
        XCTAssertEqual(analysis.durationMilliseconds, 5, accuracy: 0.0001)
    }

    func testInfiniteAndNegativeDurationsAreClamped() {
        XCTAssertEqual(item("a", .preFirstFrame, .infinity).durationMilliseconds, 0)
        XCTAssertEqual(item("a", .preFirstFrame, -12).durationMilliseconds, 0)
    }

    // MARK: Deferral

    func testDeferringALeafItemSucceedsAndShortensTheCriticalPath() throws {
        let schedule = try StartupSchedule(items: [
            item("a", .preFirstFrame, 4),
            item("b", .preFirstFrame, 6, deps: ["a"])
        ])
        let before = schedule.criticalPath().durationMilliseconds
        guard case .success(let updated) = schedule.moving("b", to: .postFirstFrame) else {
            return XCTFail("deferring a leaf must be legal")
        }
        XCTAssertEqual(before, 10, accuracy: 0.0001)
        XCTAssertEqual(updated.criticalPath().durationMilliseconds, 4, accuracy: 0.0001)
        XCTAssertEqual(updated.criticalPath().deferredMilliseconds, 6, accuracy: 0.0001)
    }

    func testDeferringAnItemSomethingOnThePathDependsOnFailsWithTheBlockingReason() throws {
        let schedule = try StartupSchedule(items: [
            item("store.open", .preFirstFrame, 8),
            item("flags.load", .preFirstFrame, 2, deps: ["store.open"])
        ])
        guard case .failure(let error) = schedule.moving("store.open", to: .postFirstFrame) else {
            return XCTFail("deferring a dependency of critical-path work must be refused")
        }
        XCTAssertEqual(
            error,
            .phaseInversion(
                item: "flags.load",
                itemPhase: .preFirstFrame,
                dependency: "store.open",
                dependencyPhase: .postFirstFrame
            )
        )
        XCTAssertTrue(error.description.contains("flags.load"), "the refusal must name the blocking item")
    }

    func testMovingAnUnknownItemFailsRatherThanCrashing() throws {
        let schedule = try StartupSchedule(items: [item("a", .preFirstFrame, 1)])
        guard case .failure = schedule.moving("nope", to: .postFirstFrame) else {
            return XCTFail("moving a non-existent item must fail, not trap")
        }
    }

    func testOriginalScheduleIsUnchangedByAFailedMove() throws {
        let schedule = try StartupSchedule(items: [
            item("a", .preFirstFrame, 8),
            item("b", .preFirstFrame, 2, deps: ["a"])
        ])
        _ = schedule.moving("a", to: .postFirstFrame)
        XCTAssertEqual(schedule.criticalPath().durationMilliseconds, 10, accuracy: 0.0001)
    }

    // MARK: Sample workspace

    func testBundledSampleScheduleIsValidAndHasAKnownCriticalPath() throws {
        let schedule = try XCTUnwrap(SampleWorkspace.startupSchedule)
        let analysis = schedule.criticalPath()
        XCTAssertEqual(
            analysis.path,
            [
                SampleWorkspace.Work.imageLoad,
                SampleWorkspace.Work.didFinishLaunching,
                SampleWorkspace.Work.openStore,
                SampleWorkspace.Work.loadCachedFlags,
                SampleWorkspace.Work.buildHomeViewModel,
                SampleWorkspace.Work.renderFirstFrame
            ]
        )
        XCTAssertEqual(analysis.durationMilliseconds, 35.4, accuracy: 0.0001)
        XCTAssertEqual(analysis.deferredMilliseconds, 19.5, accuracy: 0.0001)
        XCTAssertGreaterThan(analysis.concurrencyHeadroomMilliseconds, 0)
    }

    func testDeferringThePersistenceOpenInTheSampleIsRefused() throws {
        // The sample's most tempting "just defer it" target is also illegal, which is
        // the interaction the demo app is built around.
        let schedule = try XCTUnwrap(SampleWorkspace.startupSchedule)
        guard case .failure(let error) = schedule.moving(SampleWorkspace.Work.openStore, to: .postFirstFrame) else {
            return XCTFail("deferring the store open must be refused — cached flags depend on it")
        }
        XCTAssertTrue(error.description.contains(SampleWorkspace.Work.loadCachedFlags.rawValue))
    }
}
