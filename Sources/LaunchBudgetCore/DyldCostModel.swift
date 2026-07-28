//
//  DyldCostModel.swift
//  LaunchBudgetCore
//
//  A parameterised model of pre-main cost, so that a linkage decision can be
//  *predicted* before it is merged rather than discovered in a trace afterwards.
//
//  Honesty about what this is
//  --------------------------
//  These coefficients are a model, not a measurement of your app. They are seeded
//  from publicly reported iOS 26 → iOS 27 dyld figures (closure rebuild ~1.5x,
//  page-in/fixup work ~2.5x, static initialiser dispatch ~3x, ~21-23% end-to-end
//  improvement on real traces) and from the long-standing rule of thumb that each
//  additional dynamic image costs single-digit milliseconds on a cold launch.
//
//  The intended workflow is `calibrated(against:)`: take one real App Launch trace
//  from your own app, fit the per-image coefficient to it, and use the fitted model
//  from then on. A model you have not calibrated should be treated as a *ranking*
//  tool ("which of these two linkage plans is worse") and not as a predictor of
//  absolute milliseconds. `CostModelProvenance` on every profile records which of
//  the two you are holding, and the CI gate refuses to fail a build on an
//  uncalibrated absolute number.
//

import Foundation

/// Where a cost model's numbers came from — carried alongside the numbers so a
/// report can never present a guess as a measurement.
public enum CostModelProvenance: String, Sendable, Codable {
    /// Seeded from published platform figures. Good for ranking plans, not for
    /// asserting absolute milliseconds.
    case published

    /// Fitted against at least one real trace from this app.
    case calibrated

    public var isTrustworthyForAbsoluteThresholds: Bool {
        self == .calibrated
    }
}

/// The coefficients of the pre-main cost model.
public struct DyldCostModel: Sendable, Equatable {
    /// Fixed dyld setup cost paid once regardless of image count.
    public let fixedOverheadMilliseconds: Double

    /// Marginal cost of one additional dynamically linked image.
    public let perDynamicImageMilliseconds: Double

    /// Cost of running one module's static initialisers.
    public let perStaticInitializerModuleMilliseconds: Double

    /// Cost of one Objective-C `+load` implementation.
    public let perObjCLoadMilliseconds: Double

    public let provenance: CostModelProvenance

    /// Human-readable name for reports.
    public let name: String

    public init(
        name: String,
        fixedOverheadMilliseconds: Double,
        perDynamicImageMilliseconds: Double,
        perStaticInitializerModuleMilliseconds: Double,
        perObjCLoadMilliseconds: Double,
        provenance: CostModelProvenance
    ) {
        self.name = name
        // All four coefficients are costs. A negative cost would let a module
        // "pay back" launch time, which the gate would then read as an improvement.
        self.fixedOverheadMilliseconds = max(0, fixedOverheadMilliseconds)
        self.perDynamicImageMilliseconds = max(0, perDynamicImageMilliseconds)
        self.perStaticInitializerModuleMilliseconds = max(0, perStaticInitializerModuleMilliseconds)
        self.perObjCLoadMilliseconds = max(0, perObjCLoadMilliseconds)
        self.provenance = provenance
    }

    /// Baseline profile representing the pre-iOS-27 dynamic loader.
    public static let iOS26 = DyldCostModel(
        name: "iOS 26 (baseline)",
        fixedOverheadMilliseconds: 12.0,
        perDynamicImageMilliseconds: 3.2,
        perStaticInitializerModuleMilliseconds: 1.8,
        perObjCLoadMilliseconds: 0.35,
        provenance: .published
    )

    /// iOS 27 profile. The improvements are applied as ratios to the iOS 26 profile
    /// so the relationship between the two stays explicit and auditable rather than
    /// being two independent piles of magic numbers.
    ///
    /// - closure rebuild / image setup: ~1.5x faster  → fixed overhead ÷ 1.5
    /// - fixups and page-in work:       ~2.5x faster  → per-image ÷ 2.5
    /// - static initialiser dispatch:   ~3.0x faster  → per-initialiser ÷ 3.0
    ///
    /// `+load` is deliberately *not* discounted: it is app code, and a faster loader
    /// does not make your own `+load` body run faster. That asymmetry is the whole
    /// argument for why iOS 27 does not retire this budget system.
    ///
    /// A caveat worth stating rather than hiding: composing these three per-term
    /// ratios over a graph like `SampleWorkspace`'s produces roughly a **50%**
    /// predicted pre-main improvement, which is far more than the ~21-23% *end-to-end*
    /// figure the ratios were sourced alongside. Both can be true — end-to-end launch
    /// includes a large amount of app code that no loader improvement touches, while
    /// this model covers only the loader-attributable portion — but it means the
    /// number this model produces is emphatically **not** a prediction of what your
    /// users will see. It is a comparison between two linkage plans under one fixed
    /// set of assumptions. `LaunchBudgetCoreTests` pins the composed ratio so that
    /// this gap stays visible instead of drifting silently.
    public static let iOS27 = DyldCostModel(
        name: "iOS 27",
        fixedOverheadMilliseconds: iOS26.fixedOverheadMilliseconds / 1.5,
        perDynamicImageMilliseconds: iOS26.perDynamicImageMilliseconds / 2.5,
        perStaticInitializerModuleMilliseconds: iOS26.perStaticInitializerModuleMilliseconds / 3.0,
        perObjCLoadMilliseconds: iOS26.perObjCLoadMilliseconds,
        provenance: .published
    )

    /// Fit the per-image coefficient against one observed pre-main measurement.
    ///
    /// Everything except `perDynamicImageMilliseconds` is held fixed and the
    /// remainder is attributed to image loading. This is a single-degree-of-freedom
    /// fit, which is the honest thing to do with one data point — it will not
    /// discover that your `+load` cost is unusual, it will only stop the image term
    /// from being systematically wrong for your binary.
    ///
    /// - Parameters:
    ///   - observedPreMainMilliseconds: measured pre-main duration from a real trace.
    ///   - plan: the linkage plan that produced that trace.
    /// - Returns: a calibrated model, or `nil` if the plan has no dynamic images to
    ///   fit against (in which case the observation says nothing about per-image cost).
    public func calibrated(
        againstObservedPreMain observedPreMainMilliseconds: Double,
        plan: LinkagePlan
    ) -> DyldCostModel? {
        let dynamicImages = plan.dynamicImageCount
        guard dynamicImages > 0 else { return nil }
        guard observedPreMainMilliseconds.isFinite, observedPreMainMilliseconds >= 0 else { return nil }

        let nonImageCost =
            fixedOverheadMilliseconds
            + perStaticInitializerModuleMilliseconds * Double(plan.staticInitializerModuleCount)
            + perObjCLoadMilliseconds * Double(plan.objcLoadCount)

        let residual = observedPreMainMilliseconds - nonImageCost
        // A negative residual means the fixed terms alone already exceed the
        // observation — the model's shape is wrong for this app, and silently
        // clamping to zero would hide that. Refuse rather than fabricate.
        guard residual >= 0 else { return nil }

        return DyldCostModel(
            name: name + " (calibrated)",
            fixedOverheadMilliseconds: fixedOverheadMilliseconds,
            perDynamicImageMilliseconds: residual / Double(dynamicImages),
            perStaticInitializerModuleMilliseconds: perStaticInitializerModuleMilliseconds,
            perObjCLoadMilliseconds: perObjCLoadMilliseconds,
            provenance: .calibrated
        )
    }
}

/// A line-item breakdown of predicted pre-main cost.
///
/// Returned instead of a bare `Double` because "your pre-main is 41 ms" is not an
/// actionable statement, and "31 ms of your 41 ms pre-main is 9 dynamic images"
/// is.
public struct PreMainCostEstimate: Sendable, Equatable {
    public let fixedOverheadMilliseconds: Double
    public let dynamicImageMilliseconds: Double
    public let staticInitializerMilliseconds: Double
    public let objcLoadMilliseconds: Double
    public let dynamicImageCount: Int
    public let modelName: String
    public let provenance: CostModelProvenance

    public var totalMilliseconds: Double {
        fixedOverheadMilliseconds
        + dynamicImageMilliseconds
        + staticInitializerMilliseconds
        + objcLoadMilliseconds
    }

    /// The share of predicted pre-main cost that is attributable purely to how the
    /// module graph is *linked*, rather than to what any module actually does.
    /// This is the number that justifies owning linkage as an architectural policy.
    public var linkageAttributableShare: Double {
        let total = totalMilliseconds
        guard total > 0 else { return 0 }
        return dynamicImageMilliseconds / total
    }
}

public extension DyldCostModel {
    /// Predict pre-main cost for a resolved linkage plan.
    func estimatePreMain(for plan: LinkagePlan) -> PreMainCostEstimate {
        PreMainCostEstimate(
            fixedOverheadMilliseconds: fixedOverheadMilliseconds,
            dynamicImageMilliseconds: perDynamicImageMilliseconds * Double(plan.dynamicImageCount),
            staticInitializerMilliseconds: perStaticInitializerModuleMilliseconds * Double(plan.staticInitializerModuleCount),
            objcLoadMilliseconds: perObjCLoadMilliseconds * Double(plan.objcLoadCount),
            dynamicImageCount: plan.dynamicImageCount,
            modelName: name,
            provenance: provenance
        )
    }
}
