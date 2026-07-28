import XCTest
@testable import LaunchBudgetCore

/// Graph validation and the crash-shaped edge cases around it.
///
/// Deliberately weighted toward the degenerate inputs — empty graphs, cycles,
/// self-edges, dangling edges, deep chains — rather than the happy path, because the
/// happy path is what the demo exercises every time it launches and these are what it
/// never will.
final class ModuleGraphTests: XCTestCase {

    private func module(
        _ name: String,
        linkage: LinkagePolicy = .staticLibrary,
        deps: [ModuleID] = [],
        budget: LaunchBudget = LaunchBudget(preMainMilliseconds: 1, firstFrameMilliseconds: 1)
    ) -> ModuleDescriptor {
        ModuleDescriptor(id: ModuleID(name), declaredLinkage: linkage, dependencies: deps, budget: budget)
    }

    // MARK: Empty / degenerate

    func testEmptyGraphThrows() {
        XCTAssertThrowsError(try ModuleGraph(modules: [])) { error in
            XCTAssertEqual(error as? ModuleGraphError, .emptyGraph)
        }
    }

    func testSingleModuleGraphIsValid() throws {
        let graph = try ModuleGraph(modules: [module("Solo")])
        XCTAssertEqual(graph.count, 1)
        XCTAssertEqual(graph.topologicalOrder, [ModuleID("Solo")])
        XCTAssertTrue(graph.transitiveDependencies(of: "Solo").isEmpty)
    }

    func testDuplicateModuleThrows() {
        XCTAssertThrowsError(try ModuleGraph(modules: [module("A"), module("A")])) { error in
            XCTAssertEqual(error as? ModuleGraphError, .duplicateModule(ModuleID("A")))
        }
    }

    func testDanglingDependencyThrows() {
        XCTAssertThrowsError(try ModuleGraph(modules: [module("A", deps: ["Ghost"])])) { error in
            XCTAssertEqual(error as? ModuleGraphError, .unknownDependency(module: "A", missing: "Ghost"))
        }
    }

    // MARK: Cycles

    func testTwoNodeCycleThrows() {
        let modules = [module("A", deps: ["B"]), module("B", deps: ["A"])]
        XCTAssertThrowsError(try ModuleGraph(modules: modules)) { error in
            guard case .dependencyCycle(let path)? = error as? ModuleGraphError else {
                return XCTFail("expected a dependencyCycle, got \(error)")
            }
            XCTAssertFalse(path.isEmpty, "a cycle error with no path is not actionable")
            XCTAssertTrue(path.contains("A") || path.contains("B"))
        }
    }

    func testSelfDependencyIsReportedAsCycle() {
        XCTAssertThrowsError(try ModuleGraph(modules: [module("A", deps: ["A"])])) { error in
            guard case .dependencyCycle? = error as? ModuleGraphError else {
                return XCTFail("a self-edge must be a cycle, got \(error)")
            }
        }
    }

    func testLongCycleTerminatesAndReportsPath() {
        // A → B → C → D → A. The interesting property is that cycle extraction
        // terminates at all; an unbounded walk here would hang CI rather than fail it.
        let modules = [
            module("A", deps: ["B"]),
            module("B", deps: ["C"]),
            module("C", deps: ["D"]),
            module("D", deps: ["A"])
        ]
        XCTAssertThrowsError(try ModuleGraph(modules: modules)) { error in
            guard case .dependencyCycle(let path)? = error as? ModuleGraphError else {
                return XCTFail("expected a dependencyCycle, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(path.count, 2)
        }
    }

    func testCycleInOneComponentDoesNotHideValidRest() {
        // A valid island plus a cyclic island: the cycle must still be detected.
        let modules = [
            module("Valid"),
            module("A", deps: ["B"]),
            module("B", deps: ["A"])
        ]
        XCTAssertThrowsError(try ModuleGraph(modules: modules))
    }

    // MARK: Ordering

    func testTopologicalOrderPlacesDependenciesFirst() throws {
        let graph = try ModuleGraph(modules: [
            module("App", deps: ["Feature"]),
            module("Feature", deps: ["Core"]),
            module("Core")
        ])
        let order = graph.topologicalOrder
        guard let core = order.firstIndex(of: "Core"),
              let feature = order.firstIndex(of: "Feature"),
              let app = order.firstIndex(of: "App") else {
            return XCTFail("every module must appear in the topological order")
        }
        XCTAssertLessThan(core, feature)
        XCTAssertLessThan(feature, app)
    }

    func testTopologicalOrderIsDeterministic() throws {
        // Two independent roots: without the sorted seed, dictionary iteration order
        // would make this flap between runs, and a CI report that reorders itself is
        // one nobody diffs.
        let descriptors = [module("Zebra"), module("Alpha"), module("Mango")]
        let first = try ModuleGraph(modules: descriptors).topologicalOrder
        let second = try ModuleGraph(modules: descriptors.reversed()).topologicalOrder
        XCTAssertEqual(first, second)
    }

    func testDeepChainDoesNotOverflow() throws {
        // 2,000-deep chain. Both the sort and the transitive-closure walk are
        // iterative specifically so this passes rather than blowing the stack.
        var descriptors: [ModuleDescriptor] = [module("M0")]
        for index in 1..<2000 {
            descriptors.append(module("M\(index)", deps: [ModuleID("M\(index - 1)")]))
        }
        let graph = try ModuleGraph(modules: descriptors)
        XCTAssertEqual(graph.count, 2000)
        XCTAssertEqual(graph.transitiveDependencies(of: "M1999").count, 1999)
    }

    // MARK: Queries

    func testTransitiveDependenciesExcludeSelfAndDeduplicate() throws {
        // Diamond: App → (Left, Right) → Core. Core must be counted once.
        let graph = try ModuleGraph(modules: [
            module("App", deps: ["Left", "Right"]),
            module("Left", deps: ["Core"]),
            module("Right", deps: ["Core"]),
            module("Core")
        ])
        let transitive = graph.transitiveDependencies(of: "App")
        XCTAssertEqual(transitive, ["Left", "Right", "Core"])
        XCTAssertFalse(transitive.contains("App"))
    }

    func testTransitiveDependenciesOfUnknownModuleIsEmptyNotACrash() throws {
        let graph = try ModuleGraph(modules: [module("A")])
        XCTAssertTrue(graph.transitiveDependencies(of: "DoesNotExist").isEmpty)
        XCTAssertNil(graph.descriptor(for: "DoesNotExist"))
    }

    func testDependentsOfLeafIsEmpty() throws {
        let graph = try ModuleGraph(modules: [module("App", deps: ["Core"]), module("Core")])
        XCTAssertEqual(graph.dependents(of: "Core"), ["App"])
        XCTAssertTrue(graph.dependents(of: "App").isEmpty)
    }

    // MARK: Budget clamping

    func testNegativeBudgetIsClampedNotPropagated() {
        let budget = LaunchBudget(preMainMilliseconds: -50, firstFrameMilliseconds: -1)
        XCTAssertEqual(budget.preMainMilliseconds, 0)
        XCTAssertEqual(budget.firstFrameMilliseconds, 0)
        XCTAssertEqual(budget.totalMilliseconds, 0)
    }

    func testNegativeLoadCountIsClamped() {
        let descriptor = ModuleDescriptor(
            id: "A", declaredLinkage: .staticLibrary, budget: .zero, objcLoadCount: -7
        )
        XCTAssertEqual(descriptor.objcLoadCount, 0)
    }

    // MARK: Sample manifest

    func testBundledSampleManifestIsValid() throws {
        // The demo app renders this. If it ever stops validating, the demo shows an
        // error state instead of a dashboard — so it is worth a test of its own.
        XCTAssertNotNil(SampleWorkspace.moduleGraph, "the bundled sample manifest must validate")
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        XCTAssertEqual(graph.count, SampleWorkspace.moduleDescriptors.count)
    }
}
