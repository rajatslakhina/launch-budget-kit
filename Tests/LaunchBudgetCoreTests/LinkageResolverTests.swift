import XCTest
@testable import LaunchBudgetCore

/// The graph-level linkage rules — including the cascade, which is the one an
/// implementation gets wrong by iterating in the wrong direction.
final class LinkageResolverTests: XCTestCase {

    private func module(
        _ name: String,
        _ linkage: LinkagePolicy,
        deps: [ModuleID] = [],
        loads: Int = 0,
        staticInit: Bool = false,
        firstFrame: Bool = true
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            id: ModuleID(name),
            declaredLinkage: linkage,
            dependencies: deps,
            budget: .zero,
            hasStaticInitializers: staticInit,
            objcLoadCount: loads,
            participatesInFirstFrame: firstFrame
        )
    }

    // MARK: Merge eligibility

    func testMergeableWithNoDynamicDependentsMerges() throws {
        let graph = try ModuleGraph(modules: [module("Widgets", .mergeable)])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Widgets"), .staticLibrary)
        XCTAssertEqual(plan.dynamicImageCount, 0)
        XCTAssertTrue(plan.overriddenModules.isEmpty)
    }

    func testMergeableLinkedByDynamicFrameworkFallsBackToDynamic() throws {
        let graph = try ModuleGraph(modules: [
            module("Widgets", .mergeable),
            module("Feature", .dynamicFramework, deps: ["Widgets"])
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Widgets"), .dynamicFramework)
        XCTAssertTrue(plan.overriddenModules.contains("Widgets"))
        XCTAssertTrue(plan.diagnostics.contains { diagnostic in
            if case .mergeDenied(let blockers) = diagnostic.kind {
                return diagnostic.module == "Widgets" && blockers == ["Feature"]
            }
            return false
        })
    }

    func testMergeDenialCascadesToTransitiveMergeables() throws {
        // Icons ← Design ← Feature(dynamic).
        //
        // Design is denied its merge because Feature is dynamic. Icons is only linked
        // by Design — so whether Icons can merge depends on the *result* of resolving
        // Design, not on Design's declared value. Resolving dependents-first is what
        // makes this land in one pass; a dependencies-first pass would leave Icons
        // incorrectly merged.
        let graph = try ModuleGraph(modules: [
            module("Icons", .mergeable),
            module("Design", .mergeable, deps: ["Icons"]),
            module("Feature", .dynamicFramework, deps: ["Design"])
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Design"), .dynamicFramework)
        XCTAssertEqual(plan.linkage(for: "Icons"), .dynamicFramework, "merge denial must cascade to Icons")
        XCTAssertEqual(plan.dynamicImageCount, 3)
    }

    func testMergeableLinkedOnlyByOtherMergeablesStillMerges() throws {
        // The negative of the cascade test: nothing here forces a dynamic image, so
        // both mergeables must actually merge.
        let graph = try ModuleGraph(modules: [
            module("Icons", .mergeable),
            module("Design", .mergeable, deps: ["Icons"]),
            module("App", .staticLibrary, deps: ["Design"])
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.linkage(for: "Icons"), .staticLibrary)
        XCTAssertEqual(plan.linkage(for: "Design"), .staticLibrary)
        XCTAssertEqual(plan.dynamicImageCount, 0)
        XCTAssertTrue(plan.diagnostics.isEmpty)
    }

    func testMergeDenialSeverityFollowsPolicy() throws {
        let modules = [
            module("Widgets", .mergeable),
            module("Feature", .dynamicFramework, deps: ["Widgets"])
        ]
        let graph = try ModuleGraph(modules: modules)

        let lenient = LinkageResolver(rules: LinkagePolicyRules(treatMergeDenialAsError: false)).resolve(graph)
        XCTAssertFalse(lenient.hasErrors)

        let strict = LinkageResolver(rules: LinkagePolicyRules(treatMergeDenialAsError: true)).resolve(graph)
        XCTAssertTrue(strict.hasErrors)
    }

    // MARK: Static duplication

    func testStaticModuleLinkedByManyDynamicImagesIsReportedAsDuplicated() throws {
        let graph = try ModuleGraph(modules: [
            module("Shared", .staticLibrary),
            module("A", .dynamicFramework, deps: ["Shared"]),
            module("B", .dynamicFramework, deps: ["Shared"]),
            module("C", .dynamicFramework, deps: ["Shared"])
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertTrue(plan.diagnostics.contains { diagnostic in
            if case .staticDuplication(let copies, _) = diagnostic.kind {
                return diagnostic.module == "Shared" && copies == 3
            }
            return false
        })
    }

    func testStaticDuplicationBelowThresholdIsNotReported() throws {
        let graph = try ModuleGraph(modules: [
            module("Shared", .staticLibrary),
            module("A", .dynamicFramework, deps: ["Shared"]),
            module("B", .dynamicFramework, deps: ["Shared"])
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertFalse(plan.diagnostics.contains { diagnostic in
            if case .staticDuplication = diagnostic.kind { return true }
            return false
        })
    }

    // MARK: Unconditional work

    func testDeferredModuleWithObjcLoadIsFlagged() throws {
        let graph = try ModuleGraph(modules: [
            module("Analytics", .dynamicFramework, loads: 3, firstFrame: false)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertTrue(plan.diagnostics.contains { diagnostic in
            if case .unconditionalWorkInDeferredModule(let loads, _) = diagnostic.kind {
                return diagnostic.module == "Analytics" && loads == 3
            }
            return false
        })
    }

    func testDeferredModuleWithNoUnconditionalWorkIsNotFlagged() throws {
        let graph = try ModuleGraph(modules: [
            module("Settings", .dynamicFramework, firstFrame: false)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertFalse(plan.diagnostics.contains { diagnostic in
            if case .unconditionalWorkInDeferredModule = diagnostic.kind { return true }
            return false
        })
    }

    func testFirstFrameModuleWithLoadIsNotFlaggedAsDeferredViolation() throws {
        // A module that *is* on the launch path and has `+load` is expensive but not
        // dishonest, so it must not raise the deferred-module diagnostic.
        let graph = try ModuleGraph(modules: [
            module("Bootstrap", .staticLibrary, loads: 2, firstFrame: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertFalse(plan.diagnostics.contains { diagnostic in
            if case .unconditionalWorkInDeferredModule = diagnostic.kind { return true }
            return false
        })
    }

    // MARK: Ceiling

    func testImageCeilingIsAnError() throws {
        var modules: [ModuleDescriptor] = []
        for index in 0..<8 {
            modules.append(module("F\(index)", .dynamicFramework))
        }
        let graph = try ModuleGraph(modules: modules)
        let plan = LinkageResolver(rules: LinkagePolicyRules(dynamicImageCeiling: 6)).resolve(graph)
        XCTAssertTrue(plan.hasErrors)
        XCTAssertTrue(plan.diagnostics.contains { diagnostic in
            if case .imageCountCeilingExceeded(let count, let ceiling) = diagnostic.kind {
                return count == 8 && ceiling == 6
            }
            return false
        })
    }

    func testExactlyAtCeilingIsNotAnError() throws {
        var modules: [ModuleDescriptor] = []
        for index in 0..<6 {
            modules.append(module("F\(index)", .dynamicFramework))
        }
        let graph = try ModuleGraph(modules: modules)
        let plan = LinkageResolver(rules: LinkagePolicyRules(dynamicImageCeiling: 6)).resolve(graph)
        XCTAssertFalse(plan.hasErrors, "the ceiling is inclusive; being exactly at it must not fail the build")
    }

    // MARK: Counts and determinism

    func testCountsAreAggregatedAcrossTheGraph() throws {
        let graph = try ModuleGraph(modules: [
            module("A", .dynamicFramework, loads: 2, staticInit: true),
            module("B", .staticLibrary, loads: 1),
            module("C", .staticLibrary, staticInit: true)
        ])
        let plan = LinkageResolver().resolve(graph)
        XCTAssertEqual(plan.objcLoadCount, 3)
        XCTAssertEqual(plan.staticInitializerModuleCount, 2)
        XCTAssertEqual(plan.dynamicImageCount, 1)
    }

    func testDiagnosticsAreOrderedErrorsFirstAndDeterministically() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let first = LinkageResolver().resolve(graph).diagnostics
        let second = LinkageResolver().resolve(graph).diagnostics
        XCTAssertEqual(first, second, "identical inputs must produce an identically ordered report")
        let severities = first.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >), "errors must sort before warnings")
    }

    // MARK: Sample workspace behaviour

    func testSampleWorkspaceExercisesEveryDiagnosticKind() throws {
        // The bundled manifest is the reference a team copies; it is only useful if it
        // actually demonstrates each rule.
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        let plan = LinkageResolver().resolve(graph)

        var sawMergeDenied = false
        var sawDuplication = false
        var sawUnconditionalWork = false
        var sawCeiling = false
        for diagnostic in plan.diagnostics {
            switch diagnostic.kind {
            case .mergeDenied: sawMergeDenied = true
            case .staticDuplication: sawDuplication = true
            case .unconditionalWorkInDeferredModule: sawUnconditionalWork = true
            case .imageCountCeilingExceeded: sawCeiling = true
            }
        }
        XCTAssertTrue(sawMergeDenied)
        XCTAssertTrue(sawDuplication)
        XCTAssertTrue(sawUnconditionalWork)
        XCTAssertTrue(sawCeiling)
    }
}
