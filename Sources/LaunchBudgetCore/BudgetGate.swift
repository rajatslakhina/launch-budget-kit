//
//  BudgetGate.swift
//  LaunchBudgetCore
//
//  The enforcement layer: the thing that actually fails a pull request.
//
//  Why this is the hard part
//  -------------------------
//  Writing a launch budget down is easy. Making it survive contact with a real
//  engineering org is not, and every failure mode is a *social* failure dressed up as
//  a technical one:
//
//  - A gate that is noisy gets disabled. Launch measurements on shared CI hardware
//    move by several milliseconds run-to-run for reasons that have nothing to do with
//    the diff. So the gate must have an explicit noise floor and must not fail on
//    anything inside it.
//  - A gate that cannot name an owner gets ignored. "Launch got 9 ms slower" starts
//    an argument; "TelemetryCore's pre-main self time went from 3 ms to 12 ms" starts
//    a fix. So every regression is attributed.
//  - A gate that *can't* attribute a regression must say so rather than guess. An
//    unattributed regression is a real and important finding — it usually means the
//    cost moved into a module that isn't in the manifest at all.
//  - A gate that fails on an uncalibrated model's absolute numbers gets rightly
//    distrusted. So absolute-threshold checks are suppressed unless the cost model
//    says it has been calibrated against a real trace.
//  - A new module with no declared budget must fail. Otherwise the budget system
//    decays by addition: every new module is exempt, and in two years nothing is
//    covered.
//

import Foundation

// MARK: - Policy

/// The tolerances the gate applies.
public struct GatePolicy: Sendable, Equatable {
    /// Measurement noise floor. A delta smaller than this is never a failure,
    /// regardless of the relative thresholds below.
    public let noiseFloorMilliseconds: Double

    /// A total-launch regression must exceed this fraction of the baseline to fail.
    public let totalRegressionTolerance: Double

    /// A per-module regression must exceed this fraction of that module's baseline
    /// to fail. Looser than the total tolerance because per-module numbers are
    /// noisier — they are a smaller slice of the same measurement.
    public let perModuleRegressionTolerance: Double

    /// Whether a module appearing in the candidate trace with no declared budget
    /// fails the build.
    public let requireBudgetForEveryModule: Bool

    /// Whether an unexplained (unattributable) regression fails the build.
    public let failOnUnattributedRegression: Bool

    public init(
        noiseFloorMilliseconds: Double = 2.0,
        totalRegressionTolerance: Double = 0.03,
        perModuleRegressionTolerance: Double = 0.15,
        requireBudgetForEveryModule: Bool = true,
        failOnUnattributedRegression: Bool = true
    ) {
        self.noiseFloorMilliseconds = max(0, noiseFloorMilliseconds)
        self.totalRegressionTolerance = max(0, totalRegressionTolerance)
        self.perModuleRegressionTolerance = max(0, perModuleRegressionTolerance)
        self.requireBudgetForEveryModule = requireBudgetForEveryModule
        self.failOnUnattributedRegression = failOnUnattributedRegression
    }

    public static let `default` = GatePolicy()

    /// A deliberately permissive policy for a team adopting the gate mid-flight:
    /// report everything, fail on nothing but hard budget breaches.
    public static let advisory = GatePolicy(
        noiseFloorMilliseconds: 5.0,
        totalRegressionTolerance: 0.10,
        perModuleRegressionTolerance: 0.40,
        requireBudgetForEveryModule: false,
        failOnUnattributedRegression: false
    )
}

// MARK: - Findings

/// One thing the gate found.
public struct GateFinding: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Total time-to-first-frame regressed beyond tolerance.
        case totalRegression(baselineMs: Double, candidateMs: Double, deltaMs: Double)
        /// One module's self time regressed beyond tolerance.
        case moduleRegression(module: ModuleID, baselineMs: Double, candidateMs: Double, deltaMs: Double)
        /// A module exceeded its declared budget outright.
        case budgetExceeded(module: ModuleID, budgetMs: Double, actualMs: Double, phase: LaunchPhase)
        /// A module showed up in the trace but is not in the manifest.
        case undeclaredModule(module: ModuleID, observedMs: Double)
        /// Total regressed, but the sum of per-module regressions does not explain it.
        case unattributedRegression(totalDeltaMs: Double, attributedDeltaMs: Double, unexplainedMs: Double)
        /// A linkage rule was violated.
        case linkageViolation(LinkageDiagnostic)
        /// The trace has too many unsymbolicated samples to trust.
        case lowTraceQuality(unattributedShare: Double)
        /// An absolute-threshold check was skipped because the cost model is not
        /// calibrated. Reported as info so nobody believes a check ran that didn't.
        case absoluteCheckSkipped(reason: String)
    }

    public let kind: Kind
    public let severity: LinkageDiagnostic.Severity
    public let message: String

    public var description: String { "[\(severity.label)] \(message)" }
}

/// The gate's verdict.
public struct GateReport: Sendable, Equatable {
    public let findings: [GateFinding]
    public let baselineTimeToFirstFrameMs: Double
    public let candidateTimeToFirstFrameMs: Double
    public let predictedPreMain: PreMainCostEstimate
    public let criticalPath: CriticalPathAnalysis?

    public var deltaMilliseconds: Double {
        candidateTimeToFirstFrameMs - baselineTimeToFirstFrameMs
    }

    public var deltaPercent: Double {
        guard baselineTimeToFirstFrameMs > 0 else { return 0 }
        return deltaMilliseconds / baselineTimeToFirstFrameMs
    }

    /// The build fails if and only if there is at least one error-severity finding.
    public var passed: Bool {
        !findings.contains { $0.severity == .error }
    }

    public var errors: [GateFinding] { findings.filter { $0.severity == .error } }
    public var warnings: [GateFinding] { findings.filter { $0.severity == .warning } }

    /// A CI-log-shaped rendering.
    public func consoleReport() -> String {
        var lines: [String] = []
        lines.append("── Launch Budget Gate ─────────────────────────────")
        lines.append(String(format: "  baseline TTFF : %.1f ms", baselineTimeToFirstFrameMs))
        lines.append(String(format: "  candidate TTFF: %.1f ms  (%+.1f ms, %+.1f%%)",
                            candidateTimeToFirstFrameMs, deltaMilliseconds, deltaPercent * 100))
        lines.append("  predicted pre-main: \(Milliseconds.format(predictedPreMain.totalMilliseconds)) ms"
                     + " via \(predictedPreMain.modelName) [\(predictedPreMain.provenance.rawValue)]")
        lines.append(String(format: "    └ %d dynamic images → %.1f ms (%.0f%% of pre-main)",
                            predictedPreMain.dynamicImageCount,
                            predictedPreMain.dynamicImageMilliseconds,
                            predictedPreMain.linkageAttributableShare * 100))
        if let criticalPath {
            lines.append(String(format: "  critical path : %.1f ms over %d items (serial would be %.1f ms)",
                                criticalPath.durationMilliseconds,
                                criticalPath.path.count,
                                criticalPath.serialMilliseconds))
            if let heaviest = criticalPath.heaviestOwner {
                lines.append("    └ heaviest owner: \(heaviest.module.rawValue)"
                             + " (\(Milliseconds.format(heaviest.milliseconds)) ms)")
            }
        }
        lines.append("")
        if findings.isEmpty {
            lines.append("  no findings")
        } else {
            for finding in findings {
                lines.append("  \(finding.description)")
            }
        }
        lines.append("")
        lines.append(passed ? "  RESULT: PASS" : "  RESULT: FAIL")
        lines.append("───────────────────────────────────────────────────")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Gate

/// Evaluates a candidate build against a baseline.
public struct BudgetGate: Sendable {
    public let policy: GatePolicy
    public let linkageRules: LinkagePolicyRules

    public init(policy: GatePolicy = .default, linkageRules: LinkagePolicyRules = .default) {
        self.policy = policy
        self.linkageRules = linkageRules
    }

    /// Run the gate.
    ///
    /// - Parameters:
    ///   - baseline: trace from the merge-base build.
    ///   - candidate: trace from the build under review.
    ///   - graph: the module manifest, already validated.
    ///   - schedule: the declared startup work graph, if the project has one.
    ///   - costModel: model used for the predicted pre-main breakdown.
    public func evaluate(
        baseline: LaunchTrace,
        candidate: LaunchTrace,
        graph: ModuleGraph,
        schedule: StartupSchedule? = nil,
        costModel: DyldCostModel = .iOS27
    ) -> GateReport {
        var findings: [GateFinding] = []

        // 1. Linkage — run the resolver and lift its errors into gate findings.
        let plan = LinkageResolver(rules: linkageRules).resolve(graph)
        for diagnostic in plan.diagnostics {
            findings.append(
                GateFinding(
                    kind: .linkageViolation(diagnostic),
                    severity: diagnostic.severity,
                    message: "linkage — \(diagnostic.module): \(diagnostic.message)"
                )
            )
        }

        let estimate = costModel.estimatePreMain(for: plan)

        // 2. Trace quality. Attribution over a mostly-unsymbolicated trace produces
        // confident-looking numbers about nothing, so check this before using any of
        // them.
        let unattributedShare = candidate.samples.isEmpty
            ? 0
            : Double(candidate.unattributedSampleCount) / Double(candidate.samples.count)
        if unattributedShare > 0.2 {
            findings.append(
                GateFinding(
                    kind: .lowTraceQuality(unattributedShare: unattributedShare),
                    severity: .error,
                    message: String(
                        format: "trace quality — %.0f%% of candidate samples have no resolvable frames; "
                            + "attribution below is not trustworthy. Check that dSYMs were available to the profiler.",
                        unattributedShare * 100
                    )
                )
            )
        }

        let baselineAttribution = baseline.attribution()
        let candidateAttribution = candidate.attribution()

        // 3. Total regression.
        let baselineTTFF = baseline.timeToFirstFrameMilliseconds
        let candidateTTFF = candidate.timeToFirstFrameMilliseconds
        let totalDelta = candidateTTFF - baselineTTFF
        let totalThreshold = max(policy.noiseFloorMilliseconds, baselineTTFF * policy.totalRegressionTolerance)
        let totalRegressed = totalDelta > totalThreshold

        if totalRegressed {
            findings.append(
                GateFinding(
                    kind: .totalRegression(baselineMs: baselineTTFF, candidateMs: candidateTTFF, deltaMs: totalDelta),
                    severity: .error,
                    message: String(
                        format: "time-to-first-frame regressed %.1f ms (%.1f → %.1f ms), over the "
                            + "%.1f ms threshold (max of %.1f ms noise floor and %.0f%% of baseline).",
                        totalDelta, baselineTTFF, candidateTTFF, totalThreshold,
                        policy.noiseFloorMilliseconds, policy.totalRegressionTolerance * 100
                    )
                )
            )
        }

        // 4. Per-module regression and budget breaches.
        var attributedDelta: Double = 0
        let allModules = Set(baselineAttribution.keys).union(candidateAttribution.keys)

        for module in allModules.sorted(by: { $0.rawValue < $1.rawValue }) {
            let baseSelf = baselineAttribution[module]?.selfMilliseconds ?? 0
            let candidateEntry = candidateAttribution[module]
            let candidateSelf = candidateEntry?.selfMilliseconds ?? 0
            let delta = candidateSelf - baseSelf

            // Undeclared module: in the trace, not in the manifest.
            //
            // Its cost is deliberately NOT added to `attributedDelta`. "Attributed"
            // here means "charged to a module that has a budget and an owner" — cost
            // belonging to something nobody declared is precisely the unattributed
            // case, and folding it in would let an unowned dependency explain away
            // the very regression it caused.
            if let candidateEntry, graph.descriptor(for: module) == nil {
                if policy.requireBudgetForEveryModule {
                    findings.append(
                        GateFinding(
                            kind: .undeclaredModule(module: module, observedMs: candidateEntry.selfMilliseconds),
                            severity: .error,
                            message: "\(module.rawValue) consumed "
                                + "\(Milliseconds.format(candidateEntry.selfMilliseconds)) ms of launch but has no "
                                + "declared budget. Add it to the manifest with an explicit budget — unbudgeted "
                                + "modules are how a launch budget quietly stops covering the app."
                        )
                    )
                }
                continue
            }

            if delta > 0 { attributedDelta += delta }

            let moduleThreshold = max(policy.noiseFloorMilliseconds, baseSelf * policy.perModuleRegressionTolerance)
            if delta > moduleThreshold {
                findings.append(
                    GateFinding(
                        kind: .moduleRegression(module: module, baselineMs: baseSelf, candidateMs: candidateSelf, deltaMs: delta),
                        severity: .error,
                        message: "\(module.rawValue) self time regressed "
                            + "\(Milliseconds.format(delta)) ms "
                            + "(\(Milliseconds.format(baseSelf)) → \(Milliseconds.format(candidateSelf)) ms), "
                            + "over its \(Milliseconds.format(moduleThreshold)) ms threshold."
                    )
                )
            }

            // Absolute budget breach — only meaningful with a calibrated model or a
            // real measured trace. The trace *is* real, so this check runs; what is
            // suppressed below is the *predicted* pre-main check.
            guard let descriptor = graph.descriptor(for: module), let candidateEntry else { continue }

            let preMainActual = candidateEntry.selfMilliseconds(in: .preMain)
            if preMainActual > descriptor.budget.preMainMilliseconds + policy.noiseFloorMilliseconds {
                findings.append(
                    GateFinding(
                        kind: .budgetExceeded(
                            module: module,
                            budgetMs: descriptor.budget.preMainMilliseconds,
                            actualMs: preMainActual,
                            phase: .preMain
                        ),
                        severity: .error,
                        message: "\(module.rawValue) used \(Milliseconds.format(preMainActual)) ms pre-main "
                            + "against a \(Milliseconds.format(descriptor.budget.preMainMilliseconds)) ms budget."
                    )
                )
            }

            let firstFrameActual = candidateEntry.selfMilliseconds(in: .preFirstFrame)
            if firstFrameActual > descriptor.budget.firstFrameMilliseconds + policy.noiseFloorMilliseconds {
                findings.append(
                    GateFinding(
                        kind: .budgetExceeded(
                            module: module,
                            budgetMs: descriptor.budget.firstFrameMilliseconds,
                            actualMs: firstFrameActual,
                            phase: .preFirstFrame
                        ),
                        severity: .error,
                        message: "\(module.rawValue) used \(Milliseconds.format(firstFrameActual)) ms before "
                            + "first frame against a "
                            + "\(Milliseconds.format(descriptor.budget.firstFrameMilliseconds)) ms budget."
                    )
                )
            }
        }

        // 5. Unattributed regression — the honest "we know it got slower and we
        // cannot tell you why" finding.
        if totalRegressed {
            let unexplained = totalDelta - attributedDelta
            if unexplained > policy.noiseFloorMilliseconds {
                findings.append(
                    GateFinding(
                        kind: .unattributedRegression(
                            totalDeltaMs: totalDelta,
                            attributedDeltaMs: attributedDelta,
                            unexplainedMs: unexplained
                        ),
                        severity: policy.failOnUnattributedRegression ? .error : .warning,
                        message: String(
                            format: "%.1f ms of the %.1f ms regression could not be attributed to any module "
                                + "(only %.1f ms was). The cost is most likely in code that carries no budget — "
                                + "a new dependency, or the dynamic loader itself.",
                            unexplained, totalDelta, attributedDelta
                        )
                    )
                )
            }
        }

        // 6. Predicted-pre-main check, suppressed unless the model is calibrated.
        if !estimate.provenance.isTrustworthyForAbsoluteThresholds {
            findings.append(
                GateFinding(
                    kind: .absoluteCheckSkipped(
                        reason: "cost model '\(estimate.modelName)' is seeded from published figures, not calibrated "
                            + "against this app. Predicted pre-main is shown for ranking only and was not gated on."
                    ),
                    severity: .info,
                    message: "predicted pre-main of "
                        + String(format: "%.1f ms", estimate.totalMilliseconds)
                        + " was NOT gated on — the cost model is uncalibrated. "
                        + "Run DyldCostModel.calibrated(againstObservedPreMain:plan:) with one real trace to enable this check."
                )
            )
        } else {
            let declaredPreMainBudget = graph.orderedDescriptors.reduce(0) { $0 + $1.budget.preMainMilliseconds }
            if estimate.totalMilliseconds > declaredPreMainBudget + policy.noiseFloorMilliseconds {
                findings.append(
                    GateFinding(
                        kind: .totalRegression(
                            baselineMs: declaredPreMainBudget,
                            candidateMs: estimate.totalMilliseconds,
                            deltaMs: estimate.totalMilliseconds - declaredPreMainBudget
                        ),
                        severity: .error,
                        message: String(
                            format: "calibrated model predicts %.1f ms pre-main against a declared budget of %.1f ms.",
                            estimate.totalMilliseconds, declaredPreMainBudget
                        )
                    )
                )
            }
        }

        return GateReport(
            // Sorted most-severe-first, with the message as a tiebreaker. The
            // tiebreaker is not cosmetic: Swift's sort is not stable, so without it
            // two identical runs of the same gate could emit findings in different
            // orders, and a CI report that reorders itself is a report engineers stop
            // reading diffs of.
            findings: findings.sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.message < rhs.message
            },
            baselineTimeToFirstFrameMs: baselineTTFF,
            candidateTimeToFirstFrameMs: candidateTTFF,
            predictedPreMain: estimate,
            criticalPath: schedule?.criticalPath()
        )
    }
}
