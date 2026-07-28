//
//  StartupSchedule.swift
//  LaunchBudgetCore
//
//  The deferred-init critical path.
//
//  Linkage (see LinkageResolver) governs the cost you pay before `main()`. This file
//  governs the cost you pay after it: the graph of startup work items, which of them
//  the first frame actually blocks on, and — the part teams get wrong — whether the
//  deferral you *declared* is a deferral you actually *got*.
//
//  The bug class this exists to catch
//  ----------------------------------
//  A team moves analytics initialisation to "after first frame". Six months later
//  someone makes the session restorer, which *is* on the critical path, read a value
//  that analytics initialisation populates. Nothing crashes. Nothing in the diff
//  looks wrong. The deferral is now a lie: either the work has silently moved back
//  onto the critical path, or the critical-path item is reading uninitialised state.
//  Both are bad, and neither shows up in a build.
//
//  `StartupSchedule.validate()` makes that a hard, mechanical failure: an item in an
//  earlier phase may never depend on an item in a later phase.
//

import Foundation

// MARK: - Phase

/// When a piece of startup work runs, relative to the first committed frame.
public enum LaunchPhase: Int, Sendable, Comparable, Codable, CaseIterable {
    /// Before `main()`. Not schedulable — it is a consequence of linkage and of
    /// `+load`/static initialisers. Modelled here so it can appear in the critical
    /// path, not because it can be reordered.
    case preMain = 0

    /// After `main()`, before the first frame is committed. This is the phase whose
    /// length the user actually experiences as "launch".
    case preFirstFrame = 1

    /// After the first frame. Free, from the user's point of view, up to the point
    /// where it starts causing hitches.
    case postFirstFrame = 2

    public static func < (lhs: LaunchPhase, rhs: LaunchPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .preMain: return "pre-main"
        case .preFirstFrame: return "pre-first-frame"
        case .postFirstFrame: return "post-first-frame"
        }
    }
}

/// Identifier for a unit of startup work.
public struct WorkItemID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
    public var description: String { rawValue }

    // Single-value coding, for the same reason as `ModuleID`.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One unit of startup work, owned by exactly one module.
public struct StartupWorkItem: Sendable, Equatable {
    public let id: WorkItemID

    /// The module that owns this work — and therefore the team that owns the
    /// regression when it gets slower.
    public let owner: ModuleID

    /// The phase this work is *declared* to run in.
    public let phase: LaunchPhase

    /// Estimated (or measured) duration in milliseconds.
    public let durationMilliseconds: Double

    /// Work that must complete before this item can start.
    public let dependencies: [WorkItemID]

    /// Short description for reports.
    public let summary: String

    public init(
        id: WorkItemID,
        owner: ModuleID,
        phase: LaunchPhase,
        durationMilliseconds: Double,
        dependencies: [WorkItemID] = [],
        summary: String = ""
    ) {
        self.id = id
        self.owner = owner
        self.phase = phase
        // A NaN duration would poison every comparison in the critical-path
        // computation (all comparisons against NaN are false, so the longest-path
        // relaxation would silently never update). Normalise it here, once.
        self.durationMilliseconds = durationMilliseconds.isFinite ? max(0, durationMilliseconds) : 0
        self.dependencies = dependencies
        self.summary = summary
    }
}

// MARK: - Errors

public enum StartupScheduleError: Error, Equatable, CustomStringConvertible {
    case duplicateWorkItem(WorkItemID)
    case unknownDependency(item: WorkItemID, missing: WorkItemID)
    case cycle(path: [WorkItemID])
    /// An item in an earlier phase depends on an item in a later phase. This is the
    /// "your deferral is a lie" failure described at the top of this file.
    case phaseInversion(item: WorkItemID, itemPhase: LaunchPhase, dependency: WorkItemID, dependencyPhase: LaunchPhase)

    public var description: String {
        switch self {
        case .duplicateWorkItem(let id):
            return "Startup work item '\(id)' is declared more than once."
        case .unknownDependency(let item, let missing):
            return "Work item '\(item)' depends on '\(missing)', which does not exist."
        case .cycle(let path):
            return "Startup work cycle: \(path.map(\.rawValue).joined(separator: " → "))"
        case .phaseInversion(let item, let itemPhase, let dependency, let dependencyPhase):
            return "Phase inversion: '\(item)' runs \(itemPhase.displayName) but depends on "
                + "'\(dependency)', which runs \(dependencyPhase.displayName). "
                + "Either '\(dependency)' is not really deferred, or '\(item)' is reading state that is not ready yet."
        }
    }
}

// MARK: - Critical path

/// The result of a critical-path analysis over the startup graph.
public struct CriticalPathAnalysis: Sendable, Equatable {
    /// The ordered chain of work items that determines time-to-first-frame.
    /// Shortening anything *not* on this path does not make launch faster.
    public let path: [WorkItemID]

    /// Duration of that chain, in milliseconds.
    public let durationMilliseconds: Double

    /// Total duration of all pre-first-frame work if it ran strictly serially.
    /// The gap between this and `durationMilliseconds` is the headroom available from
    /// concurrency alone.
    public let serialMilliseconds: Double

    /// Total duration of work explicitly moved past the first frame. This is the
    /// number a deferral effort should be judged on.
    public let deferredMilliseconds: Double

    /// Per-module contribution to the critical path — who owns the regression.
    public let ownerContributions: [ModuleID: Double]

    /// Concurrency headroom: how much of the pre-first-frame work is already
    /// overlapping. 0 means fully serial (every item is on the critical path).
    public var concurrencyHeadroomMilliseconds: Double {
        max(0, serialMilliseconds - durationMilliseconds)
    }

    /// The module contributing the most to the critical path, if any.
    public var heaviestOwner: (module: ModuleID, milliseconds: Double)? {
        // Ties broken by name so the report is stable across runs.
        let best = ownerContributions
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }
            .first
        guard let best else { return nil }
        return (best.key, best.value)
    }
}

// MARK: - Schedule

/// A validated graph of startup work.
///
/// As with `ModuleGraph`, validation happens once at construction and the invariants
/// (no duplicates, no dangling edges, acyclic, no phase inversions) hold for the
/// lifetime of the value — so `criticalPath()` can be a straightforward longest-path
/// walk with no defensive re-checking.
public struct StartupSchedule: Sendable {
    public let items: [WorkItemID: StartupWorkItem]

    /// Work items in dependency order.
    public let topologicalOrder: [WorkItemID]

    public init(items: [StartupWorkItem]) throws {
        var table: [WorkItemID: StartupWorkItem] = [:]
        table.reserveCapacity(items.count)
        for item in items {
            guard table[item.id] == nil else {
                throw StartupScheduleError.duplicateWorkItem(item.id)
            }
            table[item.id] = item
        }

        for item in items {
            for dependency in item.dependencies {
                guard let dependencyItem = table[dependency] else {
                    throw StartupScheduleError.unknownDependency(item: item.id, missing: dependency)
                }
                // The phase-inversion check. Deliberately at *construction*, so an
                // invalid schedule cannot be analysed at all — a critical path
                // computed over an inverted schedule is a number that describes a
                // program that cannot run in the declared order.
                guard dependencyItem.phase <= item.phase else {
                    throw StartupScheduleError.phaseInversion(
                        item: item.id,
                        itemPhase: item.phase,
                        dependency: dependency,
                        dependencyPhase: dependencyItem.phase
                    )
                }
            }
        }

        self.items = table
        self.topologicalOrder = try StartupSchedule.topologicallySort(table)
    }

    public var count: Int { items.count }

    /// Work items in dependency order.
    public var orderedItems: [StartupWorkItem] {
        topologicalOrder.compactMap { items[$0] }
    }

    // MARK: Critical path

    /// Longest path through the pre-first-frame subgraph.
    ///
    /// Longest path is NP-hard in general graphs but linear in a DAG when relaxed in
    /// topological order — which is available here for free, because construction
    /// already computed it and already proved acyclicity.
    ///
    /// - Parameter includePreMain: whether pre-main work counts toward the path.
    ///   Defaults to `true`, because from the user's point of view launch starts at
    ///   tap, not at `main()`.
    public func criticalPath(includePreMain: Bool = true) -> CriticalPathAnalysis {
        let blockingPhases: Set<LaunchPhase> = includePreMain
            ? [.preMain, .preFirstFrame]
            : [.preFirstFrame]

        // `best[id]` = duration of the longest chain ending at `id`.
        var best: [WorkItemID: Double] = [:]
        var predecessor: [WorkItemID: WorkItemID] = [:]

        for id in topologicalOrder {
            guard let item = items[id], blockingPhases.contains(item.phase) else { continue }

            var incumbent: Double = 0
            var incumbentPredecessor: WorkItemID?

            // Sorted so that ties resolve to the same predecessor on every run.
            for dependency in item.dependencies.sorted(by: { $0.rawValue < $1.rawValue }) {
                // Dependencies outside the blocking set contribute nothing to
                // time-to-first-frame; the phase-inversion invariant guarantees they
                // cannot be *later*-phase items, so skipping them here is safe.
                guard let candidate = best[dependency] else { continue }
                // `incumbentPredecessor == nil` is load-bearing, not defensive: a
                // dependency whose accumulated length is exactly 0 (a zero-duration
                // root, or a NaN duration normalised to 0 at construction) would never
                // beat the initial `incumbent` of 0 under a bare `>`, so it would be
                // dropped from the reconstructed path — and the reported item count
                // would silently disagree with the reported duration.
                if incumbentPredecessor == nil || candidate > incumbent {
                    incumbent = candidate
                    incumbentPredecessor = dependency
                }
            }

            best[id] = incumbent + item.durationMilliseconds
            if let incumbentPredecessor {
                predecessor[id] = incumbentPredecessor
            }
        }

        // Terminal of the longest chain. Ties broken by name for report stability.
        let terminal = best
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }
            .first

        var path: [WorkItemID] = []
        if let terminal {
            var cursor: WorkItemID? = terminal.key
            // Bounded by item count: the acyclicity invariant makes an infinite walk
            // impossible, but bounding it means a future refactor that breaks the
            // invariant hangs a test rather than hanging CI.
            var guardCounter = 0
            while let current = cursor, guardCounter <= items.count {
                path.append(current)
                cursor = predecessor[current]
                guardCounter += 1
            }
            path.reverse()
        }

        let serial = orderedItems
            .filter { blockingPhases.contains($0.phase) }
            .reduce(0) { $0 + $1.durationMilliseconds }

        let deferred = orderedItems
            .filter { $0.phase == .postFirstFrame }
            .reduce(0) { $0 + $1.durationMilliseconds }

        var contributions: [ModuleID: Double] = [:]
        for id in path {
            guard let item = items[id] else { continue }
            contributions[item.owner, default: 0] += item.durationMilliseconds
        }

        return CriticalPathAnalysis(
            path: path,
            durationMilliseconds: terminal?.value ?? 0,
            serialMilliseconds: serial,
            deferredMilliseconds: deferred,
            ownerContributions: contributions
        )
    }

    /// Produce a new schedule with one item moved to a different phase.
    ///
    /// Returns a `Result` rather than throwing so a UI can offer "what if we deferred
    /// this?" as a live, non-fatal exploration: an illegal deferral surfaces as the
    /// specific `phaseInversion` that blocks it, which is exactly the information the
    /// engineer needs ("you can't defer this until you break its dependency on X").
    public func moving(_ id: WorkItemID, to phase: LaunchPhase) -> Result<StartupSchedule, StartupScheduleError> {
        guard let existing = items[id] else {
            return .failure(.unknownDependency(item: id, missing: id))
        }

        let replacement = StartupWorkItem(
            id: existing.id,
            owner: existing.owner,
            phase: phase,
            durationMilliseconds: existing.durationMilliseconds,
            dependencies: existing.dependencies,
            summary: existing.summary
        )

        var next = orderedItems
        // `firstIndex(of:)` on a value type compares all stored properties; matching
        // on `id` is the intent, and avoids relying on `Equatable` semantics here.
        guard let index = next.firstIndex(where: { $0.id == id }) else {
            return .failure(.unknownDependency(item: id, missing: id))
        }
        next[index] = replacement

        do {
            return .success(try StartupSchedule(items: next))
        } catch let error as StartupScheduleError {
            return .failure(error)
        } catch {
            // `StartupSchedule.init` only ever throws `StartupScheduleError`; this
            // arm exists so the function is total rather than relying on `try!`.
            return .failure(.unknownDependency(item: id, missing: id))
        }
    }

    // MARK: Topological sort

    private static func topologicallySort(_ table: [WorkItemID: StartupWorkItem]) throws -> [WorkItemID] {
        var indegree: [WorkItemID: Int] = [:]
        var dependents: [WorkItemID: [WorkItemID]] = [:]

        for (id, item) in table {
            indegree[id, default: 0] += 0
            for dependency in item.dependencies {
                indegree[id, default: 0] += 1
                dependents[dependency, default: []].append(id)
            }
        }

        var ready = indegree.filter { $0.value == 0 }.keys.sorted { $0.rawValue < $1.rawValue }
        var order: [WorkItemID] = []
        order.reserveCapacity(table.count)

        while !ready.isEmpty {
            let current = ready.removeFirst()
            order.append(current)
            for child in (dependents[current] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
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
            let stuck = Set(table.keys).subtracting(order).sorted { $0.rawValue < $1.rawValue }
            throw StartupScheduleError.cycle(path: stuck)
        }
        return order
    }
}
