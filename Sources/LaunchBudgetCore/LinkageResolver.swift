//
//  LinkageResolver.swift
//  LaunchBudgetCore
//
//  Resolves *declared* linkage into *effective* linkage.
//
//  The problem this solves
//  -----------------------
//  Every module author writes `.dynamic` or `.static` or "mergeable" in their own
//  package manifest, locally, in isolation. But linkage is not a local property —
//  it is a property of the whole graph. A module marked mergeable does not merge if
//  two separately-linked dynamic images both need it. A module marked static does
//  not stay one physical copy if three dynamic frameworks link it; it becomes three
//  copies, and the binary grows while nobody's declared setting looks wrong.
//
//  The failure mode this is built to prevent is not "someone picked the wrong
//  linkage". It is "everyone picked a locally reasonable linkage and the graph as a
//  whole ended up with 40 dynamic images anyway". That is a graph-level problem, so
//  it needs a graph-level resolver — this file — plus a CI gate that runs it on
//  every PR, so linkage is enforced rather than merely documented.
//

import Foundation

// MARK: - Diagnostics

/// A finding produced while resolving linkage.
public struct LinkageDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: Int, Sendable, Comparable, Codable {
        case info = 0
        case warning = 1
        case error = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var label: String {
            switch self {
            case .info: return "info"
            case .warning: return "warning"
            case .error: return "error"
            }
        }
    }

    public enum Kind: Sendable, Equatable {
        /// A `.mergeable` module could not be merged and fell back to dynamic.
        case mergeDenied(blockedBy: [ModuleID])
        /// A `.staticLibrary` module is linked by more than one dynamic image and is
        /// therefore physically duplicated into each of them.
        case staticDuplication(copies: Int, into: [ModuleID])
        /// A module declared as not participating in the first frame nonetheless has
        /// unconditional pre-main work.
        case unconditionalWorkInDeferredModule(objcLoadCount: Int, hasStaticInitializers: Bool)
        /// The resolved image count exceeds the policy ceiling.
        case imageCountCeilingExceeded(count: Int, ceiling: Int)
    }

    public let module: ModuleID
    public let kind: Kind
    public let severity: Severity
    public let message: String

    public var description: String {
        "[\(severity.label)] \(module): \(message)"
    }
}

// MARK: - Policy

/// The organisation-wide rules the resolver enforces.
///
/// This is the artifact an Engineering Lead actually owns. Individual module authors
/// own their own budget line; the lead owns this file, because these are the choices
/// that constrain every team at once.
public struct LinkagePolicyRules: Sendable, Equatable {
    /// Maximum number of dynamically linked images allowed in a release build.
    /// Exceeding it is an error, not a warning — this is the ceiling that stops the
    /// graph drifting back to 40 images one locally-reasonable PR at a time.
    public let dynamicImageCeiling: Int

    /// A static module linked into at least this many dynamic images is reported as
    /// duplicated. Two copies is usually acceptable; the default of 3 is where the
    /// binary-size argument starts to win.
    public let staticDuplicationThreshold: Int

    /// Whether a `.mergeable` module that cannot merge should be reported as an error
    /// rather than a warning. Teams that have committed to mergeable libraries
    /// project-wide want this on, because a silent fallback to dynamic is exactly the
    /// regression they adopted mergeable libraries to avoid.
    public let treatMergeDenialAsError: Bool

    public init(
        dynamicImageCeiling: Int = 6,
        staticDuplicationThreshold: Int = 3,
        treatMergeDenialAsError: Bool = false
    ) {
        self.dynamicImageCeiling = max(0, dynamicImageCeiling)
        self.staticDuplicationThreshold = max(2, staticDuplicationThreshold)
        self.treatMergeDenialAsError = treatMergeDenialAsError
    }

    public static let `default` = LinkagePolicyRules()
}

// MARK: - Plan

/// The resolved linkage for the whole graph.
public struct LinkagePlan: Sendable, Equatable {
    /// Effective linkage per module, after graph-level resolution.
    public let effectiveLinkage: [ModuleID: LinkagePolicy]

    /// Findings, ordered most severe first.
    public let diagnostics: [LinkageDiagnostic]

    /// Modules whose declared linkage the resolver had to override.
    public let overriddenModules: Set<ModuleID>

    /// Number of separately loaded dynamic images (excluding the host executable).
    public let dynamicImageCount: Int

    /// Number of modules contributing static-initialiser work.
    public let staticInitializerModuleCount: Int

    /// Total Objective-C `+load` implementations across the graph.
    public let objcLoadCount: Int

    /// Whether any diagnostic is an error.
    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    public func linkage(for module: ModuleID) -> LinkagePolicy? {
        effectiveLinkage[module]
    }
}

// MARK: - Resolver

/// Resolves declared linkage into effective linkage across a whole module graph.
public struct LinkageResolver: Sendable {
    public let rules: LinkagePolicyRules

    public init(rules: LinkagePolicyRules = .default) {
        self.rules = rules
    }

    /// Resolve the graph.
    ///
    /// Four sweeps, O(V + E + |answer|) in total:
    ///
    /// 1. Seed every module with its declared linkage.
    /// 2. One **reverse** topological sweep — dependents before dependencies — that
    ///    simultaneously memoises, for every module, the set of dynamic images
    ///    physically containing its code, and uses that to decide merge eligibility.
    ///    Merge denial cascades correctly in this single pass.
    /// 3. Static duplication, reading the same memo, so it cannot disagree with 2.
    /// 4. Unconditional pre-main work in modules that claim to be off the launch path,
    ///    then the graph-wide dynamic-image ceiling.
    ///
    /// Steps 2 and 3 look at *dependents*, not dependencies, which is why the
    /// iteration order is the reverse of the one a build system would use — and why
    /// `ModuleGraph` maintains a reverse-adjacency index.
    public func resolve(_ graph: ModuleGraph) -> LinkagePlan {
        var effective: [ModuleID: LinkagePolicy] = [:]
        var diagnostics: [LinkageDiagnostic] = []
        var overridden: Set<ModuleID> = []

        // Pass 1 — seed with declared linkage. `.mergeable` is optimistically treated
        // as merged (i.e. static-equivalent at runtime) and demoted in pass 2 if the
        // graph does not permit it.
        for descriptor in graph.orderedDescriptors {
            effective[descriptor.id] = descriptor.declaredLinkage
        }

        // Passes 2 and 3 — merge eligibility and static duplication, in one walk.
        //
        // Both questions have the same shape: "which dynamic images physically contain
        // this module's code?" A static (or successfully merged) module is transparent
        // to that question, because its objects are copied into whatever links it —
        // so `Icons(mergeable) ← Utils(static) ← Feature(dynamic)` means `Feature`
        // contains `Icons`, even though `Icons`' only direct dependent is static.
        //
        // Iteration order is **reverse** topological — dependents before dependencies.
        // That does two things at once:
        //
        //   1. Merge denial cascades correctly in a single pass. Demoting a mergeable
        //      module to dynamic makes every mergeable module it depends on newly
        //      blocked; visiting dependents first means each module reads its
        //      dependents' *final* linkage, so no iteration-to-convergence is needed.
        //   2. It lets the transitive answer be memoised. `dynamicDependents[m]` is
        //      assembled from entries already computed for m's dependents, so the whole
        //      thing is one O(V + E + |answer|) sweep rather than a fresh graph walk
        //      per module. The un-memoised version was Θ(V²) on a deep chain and took
        //      3 seconds on 2,000 modules; this takes milliseconds.
        var dynamicDependents: [ModuleID: Set<ModuleID>] = [:]
        dynamicDependents.reserveCapacity(graph.count)

        for descriptor in graph.orderedDescriptors.reversed() {
            var reachable: Set<ModuleID> = []
            for dependent in graph.dependents(of: descriptor.id) {
                if effective[dependent] == .dynamicFramework {
                    // A dynamic image is a real linkage boundary — stop here.
                    reachable.insert(dependent)
                } else {
                    // Transparent: this module's code travels onward into whatever
                    // links its dependent. Already computed, by reverse-topo order.
                    reachable.formUnion(dynamicDependents[dependent] ?? [])
                }
            }
            // NOTE: for a module that is itself dynamic, this entry means "images
            // containing it, excluding itself" and is NOT a valid general answer. It
            // is never read as one — every read above is gated on the dependent not
            // being dynamic — but the invariant is worth stating rather than leaving
            // for a future pass to trip over.
            dynamicDependents[descriptor.id] = reachable

            guard descriptor.declaredLinkage == .mergeable else { continue }

            if reachable.isEmpty {
                // Merged: behaves like a static library at runtime.
                effective[descriptor.id] = .staticLibrary
            } else {
                effective[descriptor.id] = .dynamicFramework
                overridden.insert(descriptor.id)
                let blockers = reachable.sorted { $0.rawValue < $1.rawValue }
                diagnostics.append(
                    LinkageDiagnostic(
                        module: descriptor.id,
                        kind: .mergeDenied(blockedBy: blockers),
                        severity: rules.treatMergeDenialAsError ? .error : .warning,
                        message: "declared mergeable but linked by dynamic image(s) "
                            + blockers.map(\.rawValue).joined(separator: ", ")
                            + " — falls back to a separate dynamic image, so it still pays per-image load cost."
                    )
                )
            }
        }

        // Static duplication, reading the same memo — which is what guarantees the two
        // diagnostics cannot disagree about what "static" means. A static module
        // reachable from N dynamic images is physically copied N times; nobody's
        // declared setting is wrong, the graph shape is. This is what catches "we made
        // everything static to cut image count and the binary doubled".
        for descriptor in graph.orderedDescriptors where effective[descriptor.id] == .staticLibrary {
            let into = (dynamicDependents[descriptor.id] ?? []).sorted { $0.rawValue < $1.rawValue }
            guard into.count >= rules.staticDuplicationThreshold else { continue }
            diagnostics.append(
                LinkageDiagnostic(
                    module: descriptor.id,
                    kind: .staticDuplication(copies: into.count, into: into),
                    severity: .warning,
                    message: "static, but linked by \(into.count) dynamic images "
                        + "(\(into.map(\.rawValue).joined(separator: ", "))) — "
                        + "the code is duplicated into each. Consider making it dynamic, "
                        + "or making its dependents mergeable."
                )
            )
        }

        // Pass 4 — unconditional work in modules that claim not to touch launch.
        //
        // `+load` and static initialisers run whether or not the feature is used, so
        // a module that "isn't on the launch path" but ships either of them is on the
        // launch path anyway. This is the single most common way a launch budget is
        // blown by a team that believes it did nothing.
        for descriptor in graph.orderedDescriptors where !descriptor.participatesInFirstFrame {
            let hasUnconditionalWork = descriptor.objcLoadCount > 0 || descriptor.hasStaticInitializers
            guard hasUnconditionalWork else { continue }
            diagnostics.append(
                LinkageDiagnostic(
                    module: descriptor.id,
                    kind: .unconditionalWorkInDeferredModule(
                        objcLoadCount: descriptor.objcLoadCount,
                        hasStaticInitializers: descriptor.hasStaticInitializers
                    ),
                    severity: .warning,
                    message: "declared as not participating in the first frame, but ships "
                        + Self.unconditionalWorkPhrase(
                            objcLoadCount: descriptor.objcLoadCount,
                            hasStaticInitializers: descriptor.hasStaticInitializers
                        )
                        + " — this work runs before main() regardless, so the module is on the launch path."
                )
            )
        }

        // Pass 5 — image ceiling.
        let dynamicCount = effective.values.filter { $0 == .dynamicFramework }.count
        if dynamicCount > rules.dynamicImageCeiling {
            // Attributed to the graph as a whole rather than to one module, because
            // blaming the module that happened to be added last is how this rule gets
            // gamed and then ignored.
            diagnostics.append(
                LinkageDiagnostic(
                    module: ModuleID("<graph>"),
                    kind: .imageCountCeilingExceeded(count: dynamicCount, ceiling: rules.dynamicImageCeiling),
                    severity: .error,
                    message: "resolved to \(dynamicCount) dynamic images, over the policy ceiling of "
                        + "\(rules.dynamicImageCeiling). Every image is per-launch cost paid by every user, forever."
                )
            )
        }

        let staticInitCount = graph.orderedDescriptors.filter(\.hasStaticInitializers).count
        let loadCount = graph.orderedDescriptors.reduce(0) { $0 + $1.objcLoadCount }

        return LinkagePlan(
            effectiveLinkage: effective,
            // Severity, then module, then message. The third key is not decoration:
            // one module can raise two diagnostics of the same severity (Telemetry
            // raises both `unconditionalWork` and `staticDuplication`), and without it
            // their relative order is implementation-defined for any consumer reading
            // `LinkagePlan.diagnostics` directly rather than via `GateReport`.
            diagnostics: diagnostics.sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.module.rawValue != rhs.module.rawValue { return lhs.module.rawValue < rhs.module.rawValue }
                return lhs.message < rhs.message
            },
            overriddenModules: overridden,
            dynamicImageCount: dynamicCount,
            staticInitializerModuleCount: staticInitCount,
            objcLoadCount: loadCount
        )
    }

    /// Phrases the unconditional-work finding without emitting "0 +load
    /// implementation(s)", which reads as a bug in the report rather than a finding
    /// about the module.
    private static func unconditionalWorkPhrase(objcLoadCount: Int, hasStaticInitializers: Bool) -> String {
        let loadPhrase = "\(objcLoadCount) +load implementation(s)"
        switch (objcLoadCount > 0, hasStaticInitializers) {
        case (true, true): return loadPhrase + " and static initialisers"
        case (true, false): return loadPhrase
        case (false, true): return "static initialisers"
        case (false, false): return "unconditional pre-main work"
        }
    }
}
