import XCTest
@testable import LaunchBudgetCore

/// Second batch of regression tests: resolver scale, the reverse-adjacency index that
/// makes it possible, trace-JSON shape, and launch-window ranking.
///
/// Kept separate from `RegressionTests` only because these all trace back to a single
/// later review round, and grouping them makes the history legible.
final class ResolverScaleAndEncodingTests: XCTestCase {

    // MARK: The resolver must not hang CI

    /// `LinkageResolver` walks dependents transitively — once per mergeable module in
    /// pass 2, once per static module in pass 3. When `ModuleGraph.dependents(of:)`
    /// was a full scan of the module table, that composition was Θ(V³): on the order
    /// of 4×10⁹ dictionary scans on a chain this size. `ModuleGraph` now builds a
    /// reverse-adjacency index once at construction, so the walk is linear in edges.
    ///
    /// The wall-clock bound is deliberately loose — 5 s against a real target of a few
    /// milliseconds. The job of this assertion is to fail on a return to cubic
    /// behaviour, not to flake on a slow shared runner.
    func testResolverHandlesATwoThousandModuleChainWithoutHangingCI() throws {
        var descriptors: [ModuleDescriptor] = [
            ModuleDescriptor(id: "M0", declaredLinkage: .mergeable, budget: .zero, participatesInFirstFrame: true)
        ]
        for index in 1..<2000 {
            descriptors.append(
                ModuleDescriptor(
                    id: ModuleID("M\(index)"),
                    // Alternating mergeable/static is the worst case for the transitive
                    // walk: every mergeable module has to look through the static ones
                    // above it before it can decide.
                    declaredLinkage: index % 2 == 0 ? .mergeable : .staticLibrary,
                    dependencies: [ModuleID("M\(index - 1)")],
                    budget: .zero,
                    participatesInFirstFrame: true
                )
            )
        }
        let graph = try ModuleGraph(modules: descriptors)

        let started = Date()
        let plan = LinkageResolver().resolve(graph)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5.0, "linkage resolution went super-linear again")
        // Nothing in this chain is dynamic, so every mergeable module must merge.
        XCTAssertEqual(plan.dynamicImageCount, 0)
        XCTAssertFalse(plan.hasErrors)
    }

    /// The index has to agree with the brute-force answer it replaced, or the speedup
    /// is just a faster wrong answer.
    func testDependentsIndexMatchesABruteForceScan() throws {
        let graph = try XCTUnwrap(SampleWorkspace.moduleGraph)
        for id in graph.topologicalOrder {
            var expected: Set<ModuleID> = []
            for descriptor in graph.orderedDescriptors where descriptor.dependencies.contains(id) {
                expected.insert(descriptor.id)
            }
            XCTAssertEqual(graph.dependents(of: id), expected, "index disagrees with a scan for \(id)")
        }
        XCTAssertTrue(graph.dependents(of: "NotAModule").isEmpty)
    }

    // MARK: Trace JSON has to be hand-writable

    /// Module and work-item identifiers encode as bare strings, so a stack reads
    /// `["dyld", "Analytics"]` rather than `[{"rawValue":"dyld"}, …]`. Trace JSON is
    /// the documented way to feed the gate in CI, which means it has to survive being
    /// read in a pull-request diff.
    func testTraceJSONUsesBareStringIdentifiers() throws {
        let trace = SampleWorkspace.trace(label: "t", specs: [
            .init(["dyld", "Analytics"], phase: .preMain, count: 1)
        ])
        let json = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        XCTAssertTrue(json.contains("\"dyld\""))
        XCTAssertFalse(json.contains("rawValue"), "identifiers must not encode as wrapper objects")
        XCTAssertEqual(try JSONDecoder().decode(LaunchTrace.self, from: Data(json.utf8)), trace)
    }

    /// The exact hand-written shape a CI step would be handed.
    func testAHandWrittenTraceFileDecodes() throws {
        let source = """
        {
          "label": "pr-4821",
          "sampleIntervalNanos": 1000000,
          "samples": [
            { "timestampNanos": 0, "stack": ["dyld"], "phase": 0 },
            { "timestampNanos": 1000000, "stack": ["dyld", "Analytics"], "phase": 0 },
            { "timestampNanos": 2000000, "stack": ["AppHost", "HomeFeature"], "phase": 1 }
          ]
        }
        """
        let trace = try JSONDecoder().decode(LaunchTrace.self, from: Data(source.utf8))
        XCTAssertEqual(trace.samples.count, 3)
        XCTAssertEqual(trace.timeToFirstFrameMilliseconds, 3, accuracy: 0.0001)
        XCTAssertEqual(trace.attribution()[ModuleID("Analytics")]?.selfMilliseconds, 1)
        XCTAssertEqual(trace.attribution()[ModuleID("HomeFeature")]?.selfMilliseconds, 1)
    }

    // MARK: Ranking

    /// The dashboard's headline table must not rank a module doing 9 ms of
    /// deliberately-deferred work above modules that actually cost launch time.
    /// Both orderings are legitimate — for different questions — so both exist, and
    /// this pins which is which.
    func testLaunchWindowRankingIgnoresDeferredWork() {
        let trace = SampleWorkspace.trace(label: "t", specs: [
            .init(["Deferred"], phase: .postFirstFrame, count: 90),
            .init(["OnLaunchPath"], phase: .preMain, count: 10)
        ])
        XCTAssertEqual(trace.rankedAttribution().first?.module, "Deferred",
                       "whole-trace ranking answers 'where did the CPU go'")
        XCTAssertEqual(trace.rankedByLaunchWindow().first?.module, "OnLaunchPath",
                       "launch-window ranking answers 'who is making launch slow'")
    }

    func testLaunchWindowRankingIsDeterministicOnTies() {
        let trace = SampleWorkspace.trace(label: "t", specs: [
            .init(["Zulu"], phase: .preMain, count: 5),
            .init(["Alpha"], phase: .preMain, count: 5)
        ])
        for _ in 0..<20 {
            XCTAssertEqual(trace.rankedByLaunchWindow().map(\.module), ["Alpha", "Zulu"])
        }
    }
}
