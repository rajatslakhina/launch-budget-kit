import XCTest
@testable import LaunchBudgetCore

/// Regression tests, each one pinned to a specific defect found in independent review
/// rather than to a feature.
///
/// They are kept together and named after the failure — not the API — because that is
/// the information a future reader needs. Every one of these bugs passed the original
/// 94-test suite, so the suite's shape is itself part of what was wrong: each fixture
/// happened to hold constant exactly the variable the bug depended on.
final class RegressionTests: XCTestCase {

    // MARK: Window mixing — post-first-frame work must not fail a launch gate

    /// The gate compares time-to-first-frame totals. It used to compare *whole-trace*
    /// per-module self time against them, so a module whose deliberately-deferred work
    /// got slower would fail the build even though launch never moved — the exact
    /// false positive that gets a launch gate switched off.
    func testPostFirstFrameRegressionAloneDoesNotFailTheGate() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)

        // Identical to the baseline except that post-first-frame search prewarming
        // takes three times as long.
        let candidate = SampleWorkspace.trace(label: "deferred-work-slower", specs: [
            .init([SampleWorkspace.Modules.dyld], phase: .preMain, count: 14),
            .init([SampleWorkspace.Modules.dyld, SampleWorkspace.Modules.analytics], phase: .preMain, count: 3),
            .init([SampleWorkspace.Modules.dyld, SampleWorkspace.Modules.telemetry], phase: .preMain, count: 2),
            .init([SampleWorkspace.Modules.dyld, SampleWorkspace.Modules.networking], phase: .preMain, count: 2),

            .init([SampleWorkspace.Modules.appHost], phase: .preFirstFrame, count: 1),
            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.persistence], phase: .preFirstFrame, count: 8),
            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.designSystem,
                   SampleWorkspace.Modules.iconography], phase: .preFirstFrame, count: 4),
            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.featureFlags,
                   SampleWorkspace.Modules.persistence], phase: .preFirstFrame, count: 2),
            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.homeFeature], phase: .preFirstFrame, count: 5),
            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.homeFeature,
                   SampleWorkspace.Modules.designSystem], phase: .preFirstFrame, count: 4),

            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.networking], phase: .postFirstFrame, count: 6),
            // 9 → 40. A 31 ms regression, entirely after the first frame.
            .init([SampleWorkspace.Modules.appHost, SampleWorkspace.Modules.searchFeature], phase: .postFirstFrame, count: 40)
        ])

        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace, candidate: candidate, graph: graph
        )

        XCTAssertEqual(report.deltaMilliseconds, 0, accuracy: 0.0001, "time-to-first-frame must be unchanged")
        XCTAssertFalse(report.findings.contains { finding in
            if case .moduleRegression(let module, _, _, _) = finding.kind {
                return module == SampleWorkspace.Modules.searchFeature
            }
            return false
        }, "a purely post-first-frame regression must not be reported against the module")
        XCTAssertFalse(report.findings.contains { finding in
            if case .totalRegression = finding.kind { return true }
            return false
        })
    }

    /// The same window-mixing bug also corrupted the unattributed-regression maths:
    /// out-of-window deltas inflated `attributedDelta`, which could exceed the real
    /// total delta, drive `unexplained` negative, and silently suppress a finding the
    /// gate advertises as first-class.
    func testAttributedDeltaNeverExceedsTheTotalRegression() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(
                id: "Known", declaredLinkage: .staticLibrary,
                budget: LaunchBudget(preMainMilliseconds: 100, firstFrameMilliseconds: 100),
                participatesInFirstFrame: true
            )
        ])
        let baseline = SampleWorkspace.trace(label: "base", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 40),
            .init(["Known"], phase: .postFirstFrame, count: 5)
        ])
        let candidate = SampleWorkspace.trace(label: "cand", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 45),
            // A large out-of-window increase that must not be allowed to "explain"
            // the in-window one.
            .init(["Known"], phase: .postFirstFrame, count: 200)
        ])
        let report = BudgetGate(policy: .default).evaluate(baseline: baseline, candidate: candidate, graph: graph)

        XCTAssertEqual(report.deltaMilliseconds, 5, accuracy: 0.0001)
        for finding in report.findings {
            if case .unattributedRegression(let total, let attributed, let unexplained) = finding.kind {
                XCTAssertLessThanOrEqual(attributed, total + 0.0001, "attributed cannot exceed the total")
                XCTAssertGreaterThanOrEqual(unexplained, -0.0001, "unexplained must never go negative")
            }
        }
    }

    /// An undeclared module that only appears after the first frame is outside the
    /// budget's scope and must not fail a build.
    func testUndeclaredModuleWithNoLaunchWindowCostIsNotAFailure() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(
                id: "Known", declaredLinkage: .staticLibrary,
                budget: LaunchBudget(preMainMilliseconds: 100, firstFrameMilliseconds: 100),
                participatesInFirstFrame: true
            )
        ])
        let trace = SampleWorkspace.trace(label: "t", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 20),
            .init(["LateArrivingSDK"], phase: .postFirstFrame, count: 50)
        ])
        let report = BudgetGate(policy: .default).evaluate(baseline: trace, candidate: trace, graph: graph)
        XCTAssertFalse(report.findings.contains { finding in
            if case .undeclaredModule = finding.kind { return true }
            return false
        })
        XCTAssertTrue(report.passed)
    }

    // MARK: Decoding must not bypass sanitisation

    /// `Codable` synthesis assigns stored properties directly, skipping the clamping
    /// in the memberwise initialiser. Since decoding a trace from JSON is the
    /// *documented* way to run the gate in CI, that bypass was on the primary path:
    /// a zero interval made every duration zero and the gate passed everything.
    func testDecodingAZeroSampleIntervalStillClamps() throws {
        let json = Data(#"{"label":"hand-written","sampleIntervalNanos":0,"samples":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(LaunchTrace.self, from: json)
        XCTAssertEqual(decoded.sampleIntervalNanos, 1, "the clamp must survive decoding")
    }

    func testDecodingANegativeBudgetStillClamps() throws {
        let json = Data(#"{"preMainMilliseconds":-40,"firstFrameMilliseconds":-1}"#.utf8)
        let decoded = try JSONDecoder().decode(LaunchBudget.self, from: json)
        XCTAssertEqual(decoded.preMainMilliseconds, 0)
        XCTAssertEqual(decoded.firstFrameMilliseconds, 0)
    }

    func testDecodedTraceProducesTheSameDurationsAsTheMemberwiseOne() throws {
        let original = SampleWorkspace.baselineTrace
        let decoded = try JSONDecoder().decode(LaunchTrace.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.timeToFirstFrameMilliseconds, original.timeToFirstFrameMilliseconds, accuracy: 0.0001)
    }

    // MARK: Linkage is an image-level property, not an edge-level one

    /// `Icons(mergeable) ← Utils(static) ← Feature(dynamic)`.
    ///
    /// `Icons` has exactly one direct dependent and it is static, so an edge-level
    /// check concluded no dynamic image links `Icons` and let it merge. But static
    /// code is copied into whatever links it, so `Feature.framework` physically
    /// contains `Icons` and the merge is denied in reality.
    func testMergeDenialPropagatesThroughAStaticIntermediary() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(id: "Icons", declaredLinkage: .mergeable, budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Utils", declaredLinkage: .staticLibrary, dependencies: ["Icons"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Feature", declaredLinkage: .dynamicFramework, dependencies: ["Utils"],
                             budget: .zero, participatesInFirstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Icons"), .dynamicFramework,
                       "a dynamic image reached through a static intermediary still blocks the merge")
        XCTAssertTrue(plan.overriddenModules.contains("Icons"))
    }

    /// The mirror image of the above: the same transitivity has to apply to static
    /// duplication, or the two passes disagree about what "static" means.
    /// `Shared(static) ← Middle(static) ← {A,B,C}(dynamic)` is three physical copies.
    func testStaticDuplicationIsCountedThroughAStaticIntermediary() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(id: "Shared", declaredLinkage: .staticLibrary, budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Middle", declaredLinkage: .staticLibrary, dependencies: ["Shared"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "A", declaredLinkage: .dynamicFramework, dependencies: ["Middle"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "B", declaredLinkage: .dynamicFramework, dependencies: ["Middle"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "C", declaredLinkage: .dynamicFramework, dependencies: ["Middle"],
                             budget: .zero, participatesInFirstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertTrue(plan.diagnostics.contains { diagnostic in
            if case .staticDuplication(let copies, _) = diagnostic.kind {
                return diagnostic.module == "Shared" && copies == 3
            }
            return false
        }, "Shared is copied into all three dynamic images, not zero")
    }

    /// A dynamic module is a real linkage boundary — the walk must stop there rather
    /// than treating everything upstream as one image.
    func testWalkStopsAtADynamicBoundary() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(id: "Icons", declaredLinkage: .mergeable, budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Middle", declaredLinkage: .staticLibrary, dependencies: ["Icons"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Host", declaredLinkage: .staticLibrary, dependencies: ["Middle"],
                             budget: .zero, participatesInFirstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Icons"), .staticLibrary, "nothing dynamic here, so the merge stands")
        XCTAssertEqual(plan.dynamicImageCount, 0)
    }

    /// The diamond that would make a naive reverse walk revisit shared ancestors.
    func testImageLevelWalkTerminatesOnADiamond() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(id: "Base", declaredLinkage: .mergeable, budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Left", declaredLinkage: .staticLibrary, dependencies: ["Base"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Right", declaredLinkage: .staticLibrary, dependencies: ["Base"],
                             budget: .zero, participatesInFirstFrame: true),
            ModuleDescriptor(id: "Top", declaredLinkage: .dynamicFramework, dependencies: ["Left", "Right"],
                             budget: .zero, participatesInFirstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Base"), .dynamicFramework)
    }

    // MARK: Critical path reconstruction

    /// `incumbent` starts at 0 and the relaxation used a bare `>`, so a predecessor
    /// whose accumulated length was exactly 0 — a zero-duration root, or a `NaN`
    /// normalised to 0 — never won and was dropped from the reconstructed path. The
    /// reported item count then disagreed with the reported duration.
    func testZeroDurationPredecessorStaysOnTheReconstructedPath() throws {
        let schedule = try StartupSchedule(items: [
            StartupWorkItem(id: "root", owner: "A", phase: .preFirstFrame, durationMilliseconds: 0),
            StartupWorkItem(id: "leaf", owner: "A", phase: .preFirstFrame, durationMilliseconds: 5,
                            dependencies: ["root"])
        ])
        let analysis = schedule.criticalPath()
        XCTAssertEqual(analysis.path, ["root", "leaf"], "a zero-cost root is still on the path")
        XCTAssertEqual(analysis.durationMilliseconds, 5, accuracy: 0.0001)
    }

    func testNaNNormalisedPredecessorStaysOnTheReconstructedPath() throws {
        let schedule = try StartupSchedule(items: [
            StartupWorkItem(id: "bad", owner: "A", phase: .preFirstFrame, durationMilliseconds: .nan),
            StartupWorkItem(id: "good", owner: "A", phase: .preFirstFrame, durationMilliseconds: 5,
                            dependencies: ["bad"])
        ])
        XCTAssertEqual(schedule.criticalPath().path, ["bad", "good"])
    }

    // MARK: Trace quality is checked on both traces

    /// Per-module deltas are a difference of two attributions, so an unsymbolicated
    /// *baseline* poisons every delta just as thoroughly as a bad candidate — and does
    /// it while looking like an improvement.
    func testUnsymbolicatedBaselineIsAlsoRejected() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let junkBaseline = SampleWorkspace.trace(label: "junk-base", specs: [
            .init([], phase: .preMain, count: 90),
            .init([SampleWorkspace.Modules.dyld], phase: .preMain, count: 10)
        ])
        let report = BudgetGate(policy: .default).evaluate(
            baseline: junkBaseline, candidate: SampleWorkspace.baselineTrace, graph: graph
        )
        XCTAssertTrue(report.findings.contains { finding in
            if case .lowTraceQuality = finding.kind { return true }
            return false
        })
    }

    /// A trace with no resolvable frames at all — the limiting case.
    func testFullyUnsymbolicatedTraceIsRejectedAndAttributesNothing() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let opaque = SampleWorkspace.trace(label: "opaque", specs: [
            .init([], phase: .preMain, count: 50),
            .init([], phase: .preFirstFrame, count: 50)
        ])
        XCTAssertTrue(opaque.attribution().isEmpty)
        XCTAssertEqual(opaque.unattributedSampleCount, 100)
        XCTAssertEqual(opaque.unattributedMilliseconds, opaque.durationMilliseconds, accuracy: 0.0001)

        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace, candidate: opaque, graph: graph
        )
        XCTAssertFalse(report.passed)
    }

    func testNegativeInfinityDurationIsClamped() {
        let item = StartupWorkItem(id: "x", owner: "A", phase: .preFirstFrame, durationMilliseconds: -.infinity)
        XCTAssertEqual(item.durationMilliseconds, 0)
    }

    // MARK: The cost model's composed ratio

    /// Pins the *composed* iOS 26 → iOS 27 improvement so the gap between it and the
    /// published ~21-23% end-to-end figure stays visible rather than drifting.
    ///
    /// This test is not asserting that ~50% is correct. It is asserting that the
    /// number is what the documented coefficients imply, so that changing a
    /// coefficient forces someone to look at the caveat in `DyldCostModel` again.
    func testComposedCostModelRatioIsPinnedAndDocumented() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let plan = LinkageResolver().resolve(graph)
        let before = DyldCostModel.iOS26.estimatePreMain(for: plan).totalMilliseconds
        let after = DyldCostModel.iOS27.estimatePreMain(for: plan).totalMilliseconds

        XCTAssertGreaterThan(before, after)
        let improvement = (before - after) / before
        XCTAssertEqual(improvement, 0.53, accuracy: 0.03,
                       "composed improvement is ~50%, far above the ~21-23% end-to-end figure "
                       + "the per-term ratios were sourced alongside — see the caveat in DyldCostModel")
    }

    // MARK: Report fidelity

    /// The library README quotes gate output. This pins the finding counts it quotes,
    /// so a doctored or stale README block fails CI instead of quietly misrepresenting
    /// the tool in the first thing a reader sees.
    func testSampleReportFindingCountsMatchWhatTheReadmeQuotes() throws {
        let report = try XCTUnwrap(SampleWorkspace.evaluate())
        let errors = report.findings.filter { $0.severity == .error }.count
        let warnings = report.findings.filter { $0.severity == .warning }.count
        let infos = report.findings.filter { $0.severity == .info }.count
        XCTAssertEqual(errors, 8, "README quotes 8 errors")
        XCTAssertEqual(warnings, 6, "README quotes 6 warnings")
        XCTAssertEqual(infos, 1, "README quotes 1 info")
        XCTAssertFalse(report.passed)
    }
}
