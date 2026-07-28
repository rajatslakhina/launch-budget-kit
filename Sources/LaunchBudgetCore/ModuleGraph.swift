//
//  ModuleGraph.swift
//  LaunchBudgetCore
//
//  The declarative half of the launch budget system: what modules exist, how they
//  are linked, what they are allowed to cost, and how they depend on each other.
//
//  Design note
//  -----------
//  Everything here is a value type. A launch budget system is evaluated in CI, on a
//  build machine, from a manifest and a trace file — there is no long-lived mutable
//  state to protect, so there is nothing here that needs an actor. Making the whole
//  model `Sendable` value types means the evaluation pipeline is trivially safe to
//  fan out across concurrent tasks later without revisiting any of this.
//

import Foundation

// MARK: - Identity

/// A stable identifier for a module in the SPM module graph.
///
/// Deliberately a wrapper rather than a bare `String`: module identity flows through
/// budgets, traces, and CI reports, and a raw `String` here invites accidentally
/// comparing a module name against a symbol name or a target name.
public struct ModuleID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

// MARK: - Linkage

/// How a module is linked into the app.
///
/// This is the single most consequential launch-time decision an iOS lead makes at
/// the module-graph level, because it is the one that scales with module *count*
/// rather than with module *content*.
public enum LinkagePolicy: String, Codable, Sendable, CaseIterable {
    /// Linked into the host executable. Costs no dyld image load, but is physically
    /// duplicated into every dynamic image that links it.
    case staticLibrary

    /// Its own Mach-O image. Pays per-image dyld cost on every launch, forever.
    case dynamicFramework

    /// Built dynamic for development (fast incremental builds), merged into the host
    /// binary for release builds. Only actually merges when the merge is unambiguous —
    /// see `LinkageResolver` for when it silently is not.
    case mergeable

    /// Human-readable label for CI output.
    public var displayName: String {
        switch self {
        case .staticLibrary: return "static"
        case .dynamicFramework: return "dynamic"
        case .mergeable: return "mergeable"
        }
    }
}

// MARK: - Budget

/// The launch-time budget a module is contractually allowed to consume.
///
/// Budgets are expressed in milliseconds because that is the unit the App Launch
/// instrument reports in and the unit a product owner can reason about. They are
/// declared per module so that a regression has an owner, not just a number.
public struct LaunchBudget: Codable, Sendable, Equatable {
    /// Budget for work that happens before `main()` — image loading, fixups,
    /// static initialisers, `+load`, eager protocol conformance registration.
    public let preMainMilliseconds: Double

    /// Budget for work between `main()` and the first frame being committed.
    public let firstFrameMilliseconds: Double

    public init(preMainMilliseconds: Double, firstFrameMilliseconds: Double) {
        // Negative budgets are meaningless and would silently invert every comparison
        // downstream, so clamp at construction rather than defending at every use site.
        self.preMainMilliseconds = max(0, preMainMilliseconds)
        self.firstFrameMilliseconds = max(0, firstFrameMilliseconds)
    }

    public var totalMilliseconds: Double {
        preMainMilliseconds + firstFrameMilliseconds
    }

    /// A budget of zero — the correct declaration for a module that must contribute
    /// nothing at all to launch (e.g. a settings feature module).
    public static let zero = LaunchBudget(preMainMilliseconds: 0, firstFrameMilliseconds: 0)
}

// MARK: - Module descriptor

/// Everything the budget system knows about one module.
public struct ModuleDescriptor: Sendable, Equatable {
    public let id: ModuleID

    /// What the module *asked* for in its package manifest. The resolver decides what
    /// it actually gets.
    public let declaredLinkage: LinkagePolicy

    /// Direct dependencies. Order is not significant.
    public let dependencies: [ModuleID]

    /// The contract this module is held to in CI.
    public let budget: LaunchBudget

    /// Whether the module contains Swift global `let`/`var` with non-trivial
    /// initialisers, or C++ static constructors. These run before `main()`.
    public let hasStaticInitializers: Bool

    /// Count of Objective-C `+load` implementations. Each one is unconditional
    /// pre-main work that cannot be deferred by any amount of Swift-side discipline.
    public let objcLoadCount: Int

    /// Whether the module is reachable from the first-frame render path. A module
    /// that is not should never appear in a pre-main trace at all; if it does, that
    /// is itself a finding.
    public let participatesInFirstFrame: Bool

    public init(
        id: ModuleID,
        declaredLinkage: LinkagePolicy,
        dependencies: [ModuleID] = [],
        budget: LaunchBudget,
        hasStaticInitializers: Bool = false,
        objcLoadCount: Int = 0,
        participatesInFirstFrame: Bool = false
    ) {
        self.id = id
        self.declaredLinkage = declaredLinkage
        self.dependencies = dependencies
        self.budget = budget
        self.hasStaticInitializers = hasStaticInitializers
        // A negative `+load` count is nonsense; clamping avoids it silently
        // subtracting cost from the model further down.
        self.objcLoadCount = max(0, objcLoadCount)
        self.participatesInFirstFrame = participatesInFirstFrame
    }
}

// MARK: - Graph

/// Errors raised while validating a module graph.
///
/// These are hard failures rather than diagnostics: a graph with a cycle or a
/// dangling edge has no well-defined launch order, so producing a cost number for it
/// would be worse than producing nothing.
public enum ModuleGraphError: Error, Equatable, CustomStringConvertible {
    case duplicateModule(ModuleID)
    case unknownDependency(module: ModuleID, missing: ModuleID)
    case dependencyCycle(path: [ModuleID])
    case emptyGraph

    public var description: String {
        switch self {
        case .duplicateModule(let id):
            return "Module '\(id)' is declared more than once in the manifest."
        case .unknownDependency(let module, let missing):
            return "Module '\(module)' depends on '\(missing)', which is not in the manifest."
        case .dependencyCycle(let path):
            return "Dependency cycle: \(path.map(\.rawValue).joined(separator: " → "))"
        case .emptyGraph:
            return "The module graph is empty; there is nothing to budget."
        }
    }
}

/// A validated module dependency graph.
///
/// The initialiser is the only way to build one, and it is failable-by-throwing, so
/// every downstream algorithm (linkage resolution, cost modelling, gating) can assume
/// acyclicity and edge-completeness without re-checking. That invariant is the whole
/// reason this type exists instead of passing `[ModuleDescriptor]` around.
public struct ModuleGraph: Sendable {
    public let modules: [ModuleID: ModuleDescriptor]

    /// Modules in dependency order: every module appears after all of its dependencies.
    /// Computed once at construction because three separate algorithms need it.
    public let topologicalOrder: [ModuleID]

    public init(modules: [ModuleDescriptor]) throws {
        guard !modules.isEmpty else { throw ModuleGraphError.emptyGraph }

        var table: [ModuleID: ModuleDescriptor] = [:]
        table.reserveCapacity(modules.count)
        for module in modules {
            guard table[module.id] == nil else {
                throw ModuleGraphError.duplicateModule(module.id)
            }
            table[module.id] = module
        }

        // Edge completeness: a dangling dependency means the manifest is out of sync
        // with the package graph, which is exactly the state where a cost model would
        // quietly under-report.
        for module in modules {
            for dependency in module.dependencies where table[dependency] == nil {
                throw ModuleGraphError.unknownDependency(module: module.id, missing: dependency)
            }
        }

        self.modules = table
        self.topologicalOrder = try ModuleGraph.topologicallySort(table)
    }

    public var count: Int { modules.count }

    /// All modules, in dependency order.
    public var orderedDescriptors: [ModuleDescriptor] {
        // Every id in `topologicalOrder` came from `modules`, so this lookup cannot
        // fail; `compactMap` is used instead of `!` so a future refactor that breaks
        // the invariant degrades rather than crashes.
        topologicalOrder.compactMap { modules[$0] }
    }

    public func descriptor(for id: ModuleID) -> ModuleDescriptor? {
        modules[id]
    }

    /// The set of modules that directly depend on `id`.
    public func dependents(of id: ModuleID) -> Set<ModuleID> {
        var result: Set<ModuleID> = []
        for (candidateID, descriptor) in modules where descriptor.dependencies.contains(id) {
            result.insert(candidateID)
        }
        return result
    }

    /// The transitive closure of `id`'s dependencies, excluding `id` itself.
    ///
    /// Iterative rather than recursive: a deep module graph in a large app is a real
    /// thing, and blowing the stack inside a CI gate is a bad way to find out.
    public func transitiveDependencies(of id: ModuleID) -> Set<ModuleID> {
        guard modules[id] != nil else { return [] }
        var visited: Set<ModuleID> = []
        var stack: [ModuleID] = modules[id]?.dependencies ?? []

        while let next = stack.popLast() {
            guard !visited.contains(next) else { continue }
            visited.insert(next)
            if let descriptor = modules[next] {
                stack.append(contentsOf: descriptor.dependencies)
            }
        }
        return visited
    }

    // MARK: Topological sort

    /// Kahn's algorithm, with the leftover set reported as a cycle.
    ///
    /// Iterative by construction, which matters here for the same reason as above: a
    /// recursive DFS sort is the more familiar formulation but trades a stack frame
    /// per module for it.
    private static func topologicallySort(_ table: [ModuleID: ModuleDescriptor]) throws -> [ModuleID] {
        var indegree: [ModuleID: Int] = [:]
        var dependents: [ModuleID: [ModuleID]] = [:]

        for (id, descriptor) in table {
            indegree[id, default: 0] += 0
            for dependency in descriptor.dependencies {
                indegree[id, default: 0] += 1
                dependents[dependency, default: []].append(id)
            }
        }

        // Sorted seed so the output order is deterministic across runs — a CI report
        // that reorders itself between identical runs is a report nobody trusts.
        var ready = indegree.filter { $0.value == 0 }.keys.sorted { $0.rawValue < $1.rawValue }
        var order: [ModuleID] = []
        order.reserveCapacity(table.count)

        while !ready.isEmpty {
            let current = ready.removeFirst()
            order.append(current)
            let children = (dependents[current] ?? []).sorted { $0.rawValue < $1.rawValue }
            for child in children {
                guard let remaining = indegree[child] else { continue }
                let updated = remaining - 1
                indegree[child] = updated
                if updated == 0 {
                    ready.append(child)
                    ready.sort { $0.rawValue < $1.rawValue }
                }
            }
        }

        guard order.count == table.count else {
            let stuck = Set(table.keys).subtracting(order)
            throw ModuleGraphError.dependencyCycle(path: Self.extractCycle(from: stuck, table: table))
        }
        return order
    }

    /// Walks the residual (cyclic) subgraph to produce a concrete cycle path for the
    /// error message. A cycle error that just says "there is a cycle" is not
    /// actionable in a 200-module graph.
    private static func extractCycle(from stuck: Set<ModuleID>, table: [ModuleID: ModuleDescriptor]) -> [ModuleID] {
        guard let start = stuck.sorted(by: { $0.rawValue < $1.rawValue }).first else { return [] }

        var path: [ModuleID] = []
        var seen: Set<ModuleID> = []
        var current = start

        // Bounded by the size of the residual set, so this terminates even if the
        // graph is malformed in a way the caller did not anticipate.
        for _ in 0...stuck.count {
            if seen.contains(current) {
                path.append(current)
                if let firstIndex = path.firstIndex(of: current) {
                    return Array(path[firstIndex...])
                }
                return path
            }
            seen.insert(current)
            path.append(current)
            let next = table[current]?.dependencies.first { stuck.contains($0) }
            guard let next else { return path }
            current = next
        }
        return path
    }
}
