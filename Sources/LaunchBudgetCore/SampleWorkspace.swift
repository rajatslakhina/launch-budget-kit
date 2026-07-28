//
//  SampleWorkspace.swift
//  LaunchBudgetCore
//
//  A worked example: a plausible mid-size retail app's module graph, its declared
//  startup schedule, and two launch traces — a baseline and a candidate containing a
//  regression that a code review would not have caught.
//
//  This is deliberately part of the shipping library rather than test-only fixtures,
//  for two reasons: the demo app renders it, and a team adopting the kit needs a
//  reference manifest to copy that already exercises every diagnostic the resolver
//  and the gate can produce.
//

import Foundation

/// A ready-made scenario for demos, tests, and onboarding.
public enum SampleWorkspace {

    // MARK: - Module IDs

    public enum Modules {
        public static let iconography: ModuleID = "Iconography"
        public static let designSystem: ModuleID = "DesignSystem"
        public static let networking: ModuleID = "Networking"
        public static let persistence: ModuleID = "Persistence"
        public static let analytics: ModuleID = "Analytics"
        public static let featureFlags: ModuleID = "FeatureFlags"
        public static let telemetry: ModuleID = "Telemetry"
        public static let homeFeature: ModuleID = "HomeFeature"
        public static let searchFeature: ModuleID = "SearchFeature"
        public static let checkoutFeature: ModuleID = "CheckoutFeature"
        public static let accountFeature: ModuleID = "AccountFeature"
        public static let appHost: ModuleID = "AppHost"
        /// Not in the manifest — appears only in the candidate trace, which is the
        /// point of it.
        public static let vendorSDK: ModuleID = "VendorAttributionSDK"
        /// The dynamic loader itself, so pre-main image work has somewhere to land.
        public static let dyld: ModuleID = "dyld"
    }

    // MARK: - Module graph

    /// The declared manifest.
    ///
    /// Every module's linkage here is locally defensible. The graph as a whole is
    /// still over budget — which is the argument this library exists to make.
    public static var moduleDescriptors: [ModuleDescriptor] {
        [
            ModuleDescriptor(
                id: Modules.iconography,
                declaredLinkage: .mergeable,
                dependencies: [],
                budget: LaunchBudget(preMainMilliseconds: 0, firstFrameMilliseconds: 5),
                participatesInFirstFrame: true
            ),
            ModuleDescriptor(
                id: Modules.designSystem,
                declaredLinkage: .mergeable,
                dependencies: [Modules.iconography],
                budget: LaunchBudget(preMainMilliseconds: 0, firstFrameMilliseconds: 5),
                participatesInFirstFrame: true
            ),
            ModuleDescriptor(
                id: Modules.networking,
                declaredLinkage: .dynamicFramework,
                dependencies: [],
                budget: LaunchBudget(preMainMilliseconds: 2, firstFrameMilliseconds: 2),
                hasStaticInitializers: true,
                participatesInFirstFrame: true
            ),
            ModuleDescriptor(
                id: Modules.persistence,
                declaredLinkage: .dynamicFramework,
                dependencies: [],
                budget: LaunchBudget(preMainMilliseconds: 2, firstFrameMilliseconds: 10),
                participatesInFirstFrame: true
            ),
            // The textbook offender: a module the team is certain is "not on the
            // launch path", which ships three `+load` implementations.
            ModuleDescriptor(
                id: Modules.analytics,
                declaredLinkage: .dynamicFramework,
                dependencies: [Modules.networking],
                // Budgeted at 3 ms because the team knowingly accepted the cost of
                // three +load implementations. The candidate build spends 11.
                budget: LaunchBudget(preMainMilliseconds: 3, firstFrameMilliseconds: 0),
                hasStaticInitializers: true,
                objcLoadCount: 3,
                participatesInFirstFrame: false
            ),
            ModuleDescriptor(
                id: Modules.featureFlags,
                declaredLinkage: .mergeable,
                dependencies: [Modules.networking, Modules.persistence],
                budget: LaunchBudget(preMainMilliseconds: 1, firstFrameMilliseconds: 3),
                participatesInFirstFrame: true
            ),
            ModuleDescriptor(
                id: Modules.telemetry,
                declaredLinkage: .staticLibrary,
                dependencies: [Modules.networking],
                budget: LaunchBudget(preMainMilliseconds: 1, firstFrameMilliseconds: 1),
                hasStaticInitializers: true,
                participatesInFirstFrame: false
            ),
            ModuleDescriptor(
                id: Modules.homeFeature,
                declaredLinkage: .dynamicFramework,
                dependencies: [
                    Modules.designSystem, Modules.networking,
                    Modules.persistence, Modules.featureFlags, Modules.telemetry
                ],
                budget: LaunchBudget(preMainMilliseconds: 0, firstFrameMilliseconds: 12),
                participatesInFirstFrame: true
            ),
            ModuleDescriptor(
                id: Modules.searchFeature,
                declaredLinkage: .dynamicFramework,
                dependencies: [Modules.designSystem, Modules.networking, Modules.featureFlags, Modules.telemetry],
                budget: .zero,
                participatesInFirstFrame: false
            ),
            ModuleDescriptor(
                id: Modules.checkoutFeature,
                declaredLinkage: .dynamicFramework,
                dependencies: [Modules.designSystem, Modules.networking, Modules.persistence, Modules.telemetry],
                budget: .zero,
                participatesInFirstFrame: false
            ),
            ModuleDescriptor(
                id: Modules.accountFeature,
                declaredLinkage: .mergeable,
                dependencies: [Modules.designSystem, Modules.networking],
                budget: .zero,
                participatesInFirstFrame: false
            ),
            ModuleDescriptor(
                id: Modules.appHost,
                declaredLinkage: .staticLibrary,
                dependencies: [Modules.homeFeature, Modules.searchFeature, Modules.checkoutFeature, Modules.accountFeature],
                budget: LaunchBudget(preMainMilliseconds: 0, firstFrameMilliseconds: 3),
                participatesInFirstFrame: true
            ),
            ModuleDescriptor(
                id: Modules.dyld,
                declaredLinkage: .staticLibrary,
                dependencies: [],
                budget: LaunchBudget(preMainMilliseconds: 16, firstFrameMilliseconds: 0),
                participatesInFirstFrame: true
            )
        ]
    }

    /// The validated graph.
    ///
    /// Returns an optional rather than force-trying: the descriptors above are known
    /// good today, but they are also the file people copy and edit, and a `try!` here
    /// would turn their first typo into a crash inside a demo app.
    public static var moduleGraph: ModuleGraph? {
        try? ModuleGraph(modules: moduleDescriptors)
    }

    // MARK: - Startup schedule

    public enum Work {
        public static let imageLoad: WorkItemID = "dyld.loadImages"
        public static let analyticsLoad: WorkItemID = "analytics.objcLoad"
        public static let telemetryStaticInit: WorkItemID = "telemetry.staticInit"
        public static let didFinishLaunching: WorkItemID = "app.didFinishLaunching"
        public static let openStore: WorkItemID = "persistence.openStore"
        public static let registerFonts: WorkItemID = "designSystem.registerFonts"
        public static let loadCachedFlags: WorkItemID = "featureFlags.loadCached"
        public static let buildHomeViewModel: WorkItemID = "home.buildViewModel"
        public static let renderFirstFrame: WorkItemID = "home.renderFirstFrame"
        public static let warmSession: WorkItemID = "networking.warmSession"
        public static let flushAnalytics: WorkItemID = "analytics.flushQueue"
        public static let prewarmSearch: WorkItemID = "search.prewarmIndex"
    }

    public static var startupWorkItems: [StartupWorkItem] {
        [
            StartupWorkItem(
                id: Work.imageLoad, owner: Modules.dyld, phase: .preMain,
                durationMilliseconds: 14.0,
                summary: "Load and fix up all dynamic images"
            ),
            StartupWorkItem(
                id: Work.analyticsLoad, owner: Modules.analytics, phase: .preMain,
                durationMilliseconds: 3.2,
                summary: "Three +load implementations registering swizzles"
            ),
            StartupWorkItem(
                id: Work.telemetryStaticInit, owner: Modules.telemetry, phase: .preMain,
                durationMilliseconds: 1.9,
                summary: "Global signal registry built at static-init time"
            ),
            StartupWorkItem(
                id: Work.didFinishLaunching, owner: Modules.appHost, phase: .preFirstFrame,
                durationMilliseconds: 1.2, dependencies: [Work.imageLoad],
                summary: "App entry point"
            ),
            StartupWorkItem(
                id: Work.openStore, owner: Modules.persistence, phase: .preFirstFrame,
                durationMilliseconds: 8.5, dependencies: [Work.didFinishLaunching],
                summary: "Open the persistent store and run pending migrations"
            ),
            StartupWorkItem(
                id: Work.registerFonts, owner: Modules.designSystem, phase: .preFirstFrame,
                durationMilliseconds: 3.7, dependencies: [Work.didFinishLaunching],
                summary: "Register custom fonts and resolve the type scale"
            ),
            StartupWorkItem(
                id: Work.loadCachedFlags, owner: Modules.featureFlags, phase: .preFirstFrame,
                durationMilliseconds: 2.4, dependencies: [Work.openStore],
                summary: "Read last-known-good flag payload from disk"
            ),
            StartupWorkItem(
                id: Work.buildHomeViewModel, owner: Modules.homeFeature, phase: .preFirstFrame,
                durationMilliseconds: 5.1, dependencies: [Work.loadCachedFlags, Work.registerFonts],
                summary: "Compose the home screen model from cached state"
            ),
            StartupWorkItem(
                id: Work.renderFirstFrame, owner: Modules.homeFeature, phase: .preFirstFrame,
                durationMilliseconds: 4.2, dependencies: [Work.buildHomeViewModel],
                summary: "Commit the first frame"
            ),
            StartupWorkItem(
                id: Work.warmSession, owner: Modules.networking, phase: .postFirstFrame,
                durationMilliseconds: 6.0, dependencies: [Work.didFinishLaunching],
                summary: "Establish the shared URLSession and warm TLS"
            ),
            StartupWorkItem(
                id: Work.flushAnalytics, owner: Modules.analytics, phase: .postFirstFrame,
                durationMilliseconds: 4.5, dependencies: [Work.warmSession],
                summary: "Flush the queued session-start events"
            ),
            StartupWorkItem(
                id: Work.prewarmSearch, owner: Modules.searchFeature, phase: .postFirstFrame,
                durationMilliseconds: 9.0,
                summary: "Build the local search index"
            )
        ]
    }

    public static var startupSchedule: StartupSchedule? {
        try? StartupSchedule(items: startupWorkItems)
    }

    // MARK: - Traces

    /// A compact way to describe "this stack, sampled this many times, in this phase".
    public struct SampleSpec: Sendable {
        public let stack: [ModuleID]
        public let phase: LaunchPhase
        public let count: Int

        public init(_ stack: [ModuleID], phase: LaunchPhase, count: Int) {
            self.stack = stack
            self.phase = phase
            // A negative count would silently drop the spec; clamping makes the
            // resulting trace shorter but never malformed.
            self.count = max(0, count)
        }
    }

    /// Expand specs into a trace. 1 ms per sample keeps the arithmetic legible in the
    /// demo — a real capture would use a much finer interval.
    public static func trace(label: String, specs: [SampleSpec], sampleIntervalNanos: UInt64 = 1_000_000) -> LaunchTrace {
        var samples: [LaunchSample] = []
        var timestamp: UInt64 = 0
        for spec in specs {
            for _ in 0..<spec.count {
                samples.append(LaunchSample(timestampNanos: timestamp, stack: spec.stack, phase: spec.phase))
                timestamp &+= sampleIntervalNanos
            }
        }
        return LaunchTrace(label: label, sampleIntervalNanos: sampleIntervalNanos, samples: samples)
    }

    /// Baseline trace — the merge-base build. Everything inside budget.
    public static var baselineTrace: LaunchTrace {
        trace(label: "main@a41f9c", specs: [
            .init([Modules.dyld], phase: .preMain, count: 14),
            .init([Modules.dyld, Modules.analytics], phase: .preMain, count: 3),
            .init([Modules.dyld, Modules.telemetry], phase: .preMain, count: 2),
            .init([Modules.dyld, Modules.networking], phase: .preMain, count: 2),

            .init([Modules.appHost], phase: .preFirstFrame, count: 1),
            .init([Modules.appHost, Modules.persistence], phase: .preFirstFrame, count: 8),
            .init([Modules.appHost, Modules.designSystem, Modules.iconography], phase: .preFirstFrame, count: 4),
            .init([Modules.appHost, Modules.featureFlags, Modules.persistence], phase: .preFirstFrame, count: 2),
            .init([Modules.appHost, Modules.homeFeature], phase: .preFirstFrame, count: 5),
            .init([Modules.appHost, Modules.homeFeature, Modules.designSystem], phase: .preFirstFrame, count: 4),

            .init([Modules.appHost, Modules.networking], phase: .postFirstFrame, count: 6),
            .init([Modules.appHost, Modules.searchFeature], phase: .postFirstFrame, count: 9)
        ])
    }

    /// Candidate trace — the build under review.
    ///
    /// Three things changed, and a diff review would plausibly have waved all three
    /// through:
    ///
    /// 1. `Analytics` pre-main self time went 3 ms → 11 ms. Someone added a fourth
    ///    `+load` that reads a plist.
    /// 2. A vendor attribution SDK was added. It is not in the manifest, so it has no
    ///    budget and no owner, and it costs 6 ms pre-main.
    /// 3. `Persistence` first-frame work went 8 ms → 13 ms after a migration was added.
    ///
    /// Together they are a ~19 ms regression on a ~47 ms launch — well over 30%.
    public static var regressedCandidateTrace: LaunchTrace {
        trace(label: "pr-4821@7be012", specs: [
            .init([Modules.dyld], phase: .preMain, count: 14),
            .init([Modules.dyld, Modules.analytics], phase: .preMain, count: 11),
            .init([Modules.dyld, Modules.telemetry], phase: .preMain, count: 2),
            .init([Modules.dyld, Modules.networking], phase: .preMain, count: 2),
            .init([Modules.dyld, Modules.vendorSDK], phase: .preMain, count: 6),

            .init([Modules.appHost], phase: .preFirstFrame, count: 1),
            .init([Modules.appHost, Modules.persistence], phase: .preFirstFrame, count: 13),
            .init([Modules.appHost, Modules.designSystem, Modules.iconography], phase: .preFirstFrame, count: 4),
            .init([Modules.appHost, Modules.featureFlags, Modules.persistence], phase: .preFirstFrame, count: 2),
            .init([Modules.appHost, Modules.homeFeature], phase: .preFirstFrame, count: 5),
            .init([Modules.appHost, Modules.homeFeature, Modules.designSystem], phase: .preFirstFrame, count: 4),

            .init([Modules.appHost, Modules.networking], phase: .postFirstFrame, count: 6),
            .init([Modules.appHost, Modules.searchFeature], phase: .postFirstFrame, count: 9)
        ])
    }

    /// A candidate that is within noise of the baseline — used to show that the gate
    /// does *not* fire on run-to-run variation, which is the property that decides
    /// whether anyone leaves it switched on.
    public static var withinNoiseCandidateTrace: LaunchTrace {
        trace(label: "pr-4820@1cc903", specs: [
            .init([Modules.dyld], phase: .preMain, count: 14),
            .init([Modules.dyld, Modules.analytics], phase: .preMain, count: 4),
            .init([Modules.dyld, Modules.telemetry], phase: .preMain, count: 2),
            .init([Modules.dyld, Modules.networking], phase: .preMain, count: 2),

            .init([Modules.appHost], phase: .preFirstFrame, count: 1),
            .init([Modules.appHost, Modules.persistence], phase: .preFirstFrame, count: 8),
            .init([Modules.appHost, Modules.designSystem, Modules.iconography], phase: .preFirstFrame, count: 4),
            .init([Modules.appHost, Modules.featureFlags, Modules.persistence], phase: .preFirstFrame, count: 2),
            .init([Modules.appHost, Modules.homeFeature], phase: .preFirstFrame, count: 5),
            .init([Modules.appHost, Modules.homeFeature, Modules.designSystem], phase: .preFirstFrame, count: 4),

            .init([Modules.appHost, Modules.networking], phase: .postFirstFrame, count: 6),
            .init([Modules.appHost, Modules.searchFeature], phase: .postFirstFrame, count: 9)
        ])
    }

    // MARK: - One-call evaluation

    /// The whole pipeline in one call — graph → linkage → cost model → schedule →
    /// gate. This is the shape a CI step would use.
    ///
    /// Returns `nil` only if the sample manifest itself is invalid, which can only
    /// happen if someone edited it.
    public static func evaluate(
        candidate: LaunchTrace? = nil,
        costModel: DyldCostModel = .iOS27,
        policy: GatePolicy = .default,
        linkageRules: LinkagePolicyRules = .default
    ) -> GateReport? {
        guard let graph = moduleGraph else { return nil }
        return BudgetGate(policy: policy, linkageRules: linkageRules).evaluate(
            baseline: baselineTrace,
            candidate: candidate ?? regressedCandidateTrace,
            graph: graph,
            schedule: startupSchedule,
            costModel: costModel
        )
    }
}
