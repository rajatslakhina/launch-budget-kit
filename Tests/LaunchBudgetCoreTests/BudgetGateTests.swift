import XCTest
@testable import LaunchBudgetCore

/// The CI gate, and the cost model it reports against.
///
/// The two properties that decide whether a gate like this survives in a real org are
/// both tested here explicitly: it must not fire on noise, and when it does fire it
/// must name an owner or admit that it cannot.
final class BudgetGateTests: XCTestCase {

    private func sampleGraph() throws -> ModuleGraph {
        try XCTUnwrap(SampleWorkspace.moduleGraph)
    }

    // MARK: Noise

    func testGateDoesNotFireOnRunToRunNoise() throws {
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.withinNoiseCandidateTrace,
            graph: try sampleGraph(),
            schedule: SampleWorkspace.startupSchedule
        )
        XCTAssertFalse(report.findings.contains { finding in
            if case .totalRegression = finding.kind { return true }
            return false
        }, "a 1 ms move must not be reported as a regression")
        XCTAssertFalse(report.findings.contains { finding in
            if case .moduleRegression = finding.kind { return true }
            return false
        })
    }

    func testIdenticalTracesProduceNoRegressionFindings() throws {
        let trace = SampleWorkspace.baselineTrace
        let report = BudgetGate(policy: .default).evaluate(
            baseline: trace, candidate: trace, graph: try sampleGraph()
        )
        XCTAssertEqual(report.deltaMilliseconds, 0, accuracy: 0.0001)
        XCTAssertFalse(report.findings.contains { finding in
            switch finding.kind {
            case .totalRegression, .moduleRegression, .unattributedRegression: return true
            default: return false
            }
        })
    }

    // MARK: Real regressions

    func testRegressedCandidateFailsTheGate() throws {
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.regressedCandidateTrace,
            graph: try sampleGraph(),
            schedule: SampleWorkspace.startupSchedule
        )
        XCTAssertFalse(report.passed)
        XCTAssertGreaterThan(report.deltaMilliseconds, 15)
    }

    func testRegressionIsAttributedToTheOffendingModules() throws {
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.regressedCandidateTrace,
            graph: try sampleGraph()
        )
        var regressedModules: Set<ModuleID> = []
        for finding in report.findings {
            if case .moduleRegression(let module, _, _, _) = finding.kind {
                regressedModules.insert(module)
            }
        }
        XCTAssertTrue(regressedModules.contains(SampleWorkspace.Modules.analytics))
        XCTAssertTrue(regressedModules.contains(SampleWorkspace.Modules.persistence))
    }

    func testUndeclaredModuleIsAHardFailure() throws {
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.regressedCandidateTrace,
            graph: try sampleGraph()
        )
        let undeclared = report.findings.contains { finding in
            if case .undeclaredModule(let module, _) = finding.kind {
                return module == SampleWorkspace.Modules.vendorSDK
            }
            return false
        }
        XCTAssertTrue(undeclared, "a module in the trace but not the manifest must fail the build")
    }

    func testUndeclaredModuleIsToleratedWhenPolicyAllowsIt() throws {
        let policy = GatePolicy(requireBudgetForEveryModule: false)
        let report = BudgetGate(policy: policy).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.regressedCandidateTrace,
            graph: try sampleGraph()
        )
        XCTAssertFalse(report.findings.contains { finding in
            if case .undeclaredModule = finding.kind { return true }
            return false
        })
    }

    func testBudgetBreachIsReportedPerPhase() throws {
        // Analytics declares a 1 ms pre-main budget and spends 11 ms in the candidate.
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.regressedCandidateTrace,
            graph: try sampleGraph()
        )
        let breach = report.findings.contains { finding in
            if case .budgetExceeded(let module, _, _, let phase) = finding.kind {
                return module == SampleWorkspace.Modules.analytics && phase == .preMain
            }
            return false
        }
        XCTAssertTrue(breach)
    }

    // MARK: Unattributed regression

    func testUnexplainedRegressionIsReportedRatherThanGuessedAt() throws {
        // The regression lives entirely in a module the manifest has never heard of,
        // and the policy tolerates undeclared modules — so nothing else can claim it.
        // The gate must still say the launch got slower and that it cannot pin it.
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(
                id: "Known", declaredLinkage: .staticLibrary,
                budget: LaunchBudget(preMainMilliseconds: 50, firstFrameMilliseconds: 50),
                participatesInFirstFrame: true
            )
        ])
        let baseline = SampleWorkspace.trace(label: "base", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 40)
        ])
        let candidate = SampleWorkspace.trace(label: "cand", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 40),
            .init(["MysteryFramework"], phase: .preMain, count: 25)
        ])
        let policy = GatePolicy(requireBudgetForEveryModule: false, failOnUnattributedRegression: true)
        let report = BudgetGate(policy: policy).evaluate(baseline: baseline, candidate: candidate, graph: graph)

        let unattributed = report.findings.first { finding in
            if case .unattributedRegression = finding.kind { return true }
            return false
        }
        XCTAssertNotNil(unattributed)
        XCTAssertEqual(unattributed?.severity, .error)
        XCTAssertFalse(report.passed)
    }

    func testUnattributedRegressionCanBeDowngradedToAWarning() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(
                id: "Known", declaredLinkage: .staticLibrary,
                budget: LaunchBudget(preMainMilliseconds: 50, firstFrameMilliseconds: 50),
                participatesInFirstFrame: true
            )
        ])
        let baseline = SampleWorkspace.trace(label: "base", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 40)
        ])
        let candidate = SampleWorkspace.trace(label: "cand", specs: [
            .init(["Known"], phase: .preFirstFrame, count: 40),
            .init(["MysteryFramework"], phase: .preMain, count: 25)
        ])
        let policy = GatePolicy(requireBudgetForEveryModule: false, failOnUnattributedRegression: false)
        let report = BudgetGate(policy: policy).evaluate(baseline: baseline, candidate: candidate, graph: graph)
        let unattributed = report.findings.first { finding in
            if case .unattributedRegression = finding.kind { return true }
            return false
        }
        XCTAssertEqual(unattributed?.severity, .warning)
    }

    // MARK: Trace quality

    func testMostlyUnsymbolicatedTraceIsRejectedBeforeItsNumbersAreBelieved() throws {
        let graph = try sampleGraph()
        let junk = SampleWorkspace.trace(label: "junk", specs: [
            .init([], phase: .preMain, count: 80),
            .init([SampleWorkspace.Modules.dyld], phase: .preMain, count: 20)
        ])
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace, candidate: junk, graph: graph
        )
        XCTAssertTrue(report.findings.contains { finding in
            if case .lowTraceQuality = finding.kind { return true }
            return false
        })
        XCTAssertFalse(report.passed)
    }

    func testCleanTraceDoesNotRaiseAQualityFinding() throws {
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.baselineTrace,
            graph: try sampleGraph()
        )
        XCTAssertFalse(report.findings.contains { finding in
            if case .lowTraceQuality = finding.kind { return true }
            return false
        })
    }

    // MARK: Calibration gating

    func testUncalibratedModelSuppressesTheAbsolutePreMainCheck() throws {
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: SampleWorkspace.baselineTrace,
            graph: try sampleGraph(),
            costModel: .iOS27
        )
        let skipped = report.findings.first { finding in
            if case .absoluteCheckSkipped = finding.kind { return true }
            return false
        }
        XCTAssertNotNil(skipped, "an uncalibrated model must say so rather than silently gating on a guess")
        XCTAssertEqual(skipped?.severity, .info)
    }

    // MARK: Report rendering

    func testConsoleReportRendersWithoutCrashingAndStatesTheVerdict() throws {
        let report = try XCTUnwrap(SampleWorkspace.evaluate())
        let text = report.consoleReport()
        XCTAssertTrue(text.contains("Launch Budget Gate"))
        XCTAssertTrue(text.contains(report.passed ? "RESULT: PASS" : "RESULT: FAIL"))
        XCTAssertTrue(text.contains("predicted pre-main"))
        XCTAssertFalse(text.contains("(null)"), "portable formatting must not leak a %@ placeholder")
    }

    func testFindingOrderIsDeterministic() throws {
        let first = try XCTUnwrap(SampleWorkspace.evaluate()).findings.map(\.message)
        let second = try XCTUnwrap(SampleWorkspace.evaluate()).findings.map(\.message)
        XCTAssertEqual(first, second)
    }

    func testDeltaPercentDoesNotDivideByZeroOnAnEmptyBaseline() throws {
        let graph = try sampleGraph()
        let empty = LaunchTrace(label: "empty", sampleIntervalNanos: 1_000_000, samples: [])
        let report = BudgetGate(policy: .default).evaluate(
            baseline: empty, candidate: empty, graph: graph
        )
        XCTAssertEqual(report.deltaPercent, 0)
        XCTAssertTrue(report.deltaPercent.isFinite)
    }
}

/// The cost model in isolation.
final class DyldCostModelTests: XCTestCase {

    func testIOS27ProfileIsCheaperThanIOS26OnEveryDiscountedTerm() {
        XCTAssertLessThan(DyldCostModel.iOS27.fixedOverheadMilliseconds, DyldCostModel.iOS26.fixedOverheadMilliseconds)
        XCTAssertLessThan(DyldCostModel.iOS27.perDynamicImageMilliseconds, DyldCostModel.iOS26.perDynamicImageMilliseconds)
        XCTAssertLessThan(
            DyldCostModel.iOS27.perStaticInitializerModuleMilliseconds,
            DyldCostModel.iOS26.perStaticInitializerModuleMilliseconds
        )
    }

    func testObjcLoadCostIsNotDiscountedByTheNewerLoader() {
        // The asymmetry that keeps this whole library relevant on iOS 27: a faster
        // loader does not make your own `+load` body run faster.
        XCTAssertEqual(DyldCostModel.iOS27.perObjCLoadMilliseconds, DyldCostModel.iOS26.perObjCLoadMilliseconds)
    }

    func testNegativeCoefficientsAreClamped() {
        let model = DyldCostModel(
            name: "broken",
            fixedOverheadMilliseconds: -1,
            perDynamicImageMilliseconds: -2,
            perStaticInitializerModuleMilliseconds: -3,
            perObjCLoadMilliseconds: -4,
            provenance: .published
        )
        XCTAssertEqual(model.fixedOverheadMilliseconds, 0)
        XCTAssertEqual(model.perDynamicImageMilliseconds, 0)
        XCTAssertEqual(model.perStaticInitializerModuleMilliseconds, 0)
        XCTAssertEqual(model.perObjCLoadMilliseconds, 0)
    }

    func testEstimateBreakdownSumsToTheTotal() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let plan = LinkageResolver().resolve(graph)
        let estimate = DyldCostModel.iOS27.estimatePreMain(for: plan)
        let summed = estimate.fixedOverheadMilliseconds
            + estimate.dynamicImageMilliseconds
            + estimate.staticInitializerMilliseconds
            + estimate.objcLoadMilliseconds
        XCTAssertEqual(summed, estimate.totalMilliseconds, accuracy: 0.0001)
        XCTAssertGreaterThan(estimate.linkageAttributableShare, 0)
        XCTAssertLessThanOrEqual(estimate.linkageAttributableShare, 1)
    }

    func testLinkageShareIsZeroForAnAllStaticGraph() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(id: "A", declaredLinkage: .staticLibrary, budget: .zero, participatesInFirstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        let estimate = DyldCostModel.iOS27.estimatePreMain(for: plan)
        XCTAssertEqual(estimate.dynamicImageCount, 0)
        XCTAssertEqual(estimate.linkageAttributableShare, 0)
    }

    // MARK: Calibration

    func testCalibrationFitsThePerImageTermAndFlipsProvenance() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let plan = LinkageResolver().resolve(graph)
        let base = DyldCostModel.iOS27
        let observed = base.estimatePreMain(for: plan).totalMilliseconds + 20

        let calibrated = try XCTUnwrap(base.calibrated(againstObservedPreMain: observed, plan: plan))
        XCTAssertEqual(calibrated.provenance, .calibrated)
        XCTAssertTrue(calibrated.provenance.isTrustworthyForAbsoluteThresholds)
        XCTAssertGreaterThan(calibrated.perDynamicImageMilliseconds, base.perDynamicImageMilliseconds)
        // Refitting should reproduce the observation it was fitted to.
        XCTAssertEqual(calibrated.estimatePreMain(for: plan).totalMilliseconds, observed, accuracy: 0.0001)
    }

    func testCalibrationRefusesWhenThereAreNoDynamicImagesToFit() throws {
        let graph = try ModuleGraph(modules: [
            ModuleDescriptor(id: "A", declaredLinkage: .staticLibrary, budget: .zero, participatesInFirstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertNil(DyldCostModel.iOS27.calibrated(againstObservedPreMain: 30, plan: plan))
    }

    func testCalibrationRefusesAnImpossiblyFastObservation() throws {
        // Observed pre-main below the model's fixed terms means the model's *shape* is
        // wrong for this app. Clamping to zero would hide that, so it must refuse.
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let plan = LinkageResolver().resolve(graph)
        XCTAssertNil(DyldCostModel.iOS27.calibrated(againstObservedPreMain: 0.01, plan: plan))
    }

    func testCalibrationRejectsNonFiniteObservations() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let plan = LinkageResolver().resolve(graph)
        XCTAssertNil(DyldCostModel.iOS27.calibrated(againstObservedPreMain: .nan, plan: plan))
        XCTAssertNil(DyldCostModel.iOS27.calibrated(againstObservedPreMain: .infinity, plan: plan))
        XCTAssertNil(DyldCostModel.iOS27.calibrated(againstObservedPreMain: -5, plan: plan))
    }

    // MARK: Formatting

    func testMillisecondFormattingHandlesNonFiniteValues() {
        XCTAssertEqual(Milliseconds.format(.nan), "—")
        XCTAssertEqual(Milliseconds.format(.infinity), "—")
        XCTAssertEqual(Milliseconds.format(12.34), "12.3")
        XCTAssertEqual(Milliseconds.signed(2.5), "+2.5")
        XCTAssertEqual(Milliseconds.percent(0.5), "50%")
        XCTAssertEqual(Milliseconds.percent(.nan), "—")
    }
}
