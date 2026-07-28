//
//  LaunchBudgetDashboard.swift
//  LaunchBudgetKitUI
//
//  The demo surface: run the whole launch-budget pipeline live and let the user
//  change the inputs that a lead would actually argue about.
//
//  Three interactions, each mapped to a real decision:
//
//  • Cost model (iOS 26 ↔ iOS 27) — "the platform got faster, do we still need this?"
//  • Candidate build (regressed ↔ within-noise) — "does the gate cry wolf?"
//  • Defer a startup work item — "can we just move this off the critical path?"
//    Answered honestly: sometimes the answer is no, and the dashboard shows the exact
//    dependency that makes it no.
//
//  Implementation note: this view holds only value-type `@State` and derives
//  everything else with pure functions from LaunchBudgetCore. There is no observable
//  reference-type model, which means there is no actor-isolation question to get
//  wrong — a deliberate choice under Swift 6 strict concurrency.
//

#if canImport(SwiftUI)

import SwiftUI
import LaunchBudgetCore

// MARK: - Inputs

enum CostModelChoice: String, CaseIterable, Identifiable {
    case iOS26
    case iOS27

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iOS26: return "iOS 26"
        case .iOS27: return "iOS 27"
        }
    }

    var model: DyldCostModel {
        switch self {
        case .iOS26: return .iOS26
        case .iOS27: return .iOS27
        }
    }
}

enum CandidateChoice: String, CaseIterable, Identifiable {
    case regressed
    case withinNoise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regressed: return "Regressed PR"
        case .withinNoise: return "Noise-only PR"
        }
    }

    var trace: LaunchTrace {
        switch self {
        case .regressed: return SampleWorkspace.regressedCandidateTrace
        case .withinNoise: return SampleWorkspace.withinNoiseCandidateTrace
        }
    }
}

// MARK: - Dashboard

/// The demo's root view. Takes no parameters, so it can be dropped straight into an
/// `App` body.
public struct LaunchBudgetDashboard: View {

    @State private var costModelChoice: CostModelChoice = .iOS27
    @State private var candidateChoice: CandidateChoice = .regressed
    @State private var deferredItems: Set<WorkItemID> = []
    @State private var deferralError: String?

    public init() {}

    // MARK: Derived state

    /// The validated manifest. Optional all the way through rather than force-tried:
    /// a demo that crashes because a sample manifest was edited is a bad advert for a
    /// library whose entire pitch is "catch this in CI, not at runtime".
    private var graph: ModuleGraph? { SampleWorkspace.moduleGraph }

    private var scheduleItems: [StartupWorkItem] {
        SampleWorkspace.startupWorkItems.map { item in
            guard deferredItems.contains(item.id) else { return item }
            return StartupWorkItem(
                id: item.id,
                owner: item.owner,
                phase: .postFirstFrame,
                durationMilliseconds: item.durationMilliseconds,
                dependencies: item.dependencies,
                summary: item.summary
            )
        }
    }

    private var schedule: StartupSchedule? {
        try? StartupSchedule(items: scheduleItems)
    }

    private var report: GateReport? {
        guard let graph else { return nil }
        return BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: candidateChoice.trace,
            graph: graph,
            schedule: schedule,
            costModel: costModelChoice.model
        )
    }

    private var plan: LinkagePlan? {
        graph.map { LinkageResolver().resolve($0) }
    }

    // MARK: Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let report, let plan, let graph {
                        verdictSection(report)
                        controlsSection()
                        preMainSection(report, plan: plan)
                        linkageSection(graph: graph, plan: plan)
                        criticalPathSection()
                        findingsSection(report)
                        consoleSection(report)
                    } else {
                        // Reachable only if the bundled manifest is invalid. Shown as
                        // a real state rather than an empty screen.
                        ContentUnavailableView(
                            "Sample manifest is invalid",
                            systemImage: "exclamationmark.triangle",
                            description: Text("The bundled module graph failed validation, so no budget can be computed.")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding(14)
            }
            .navigationTitle("Launch Budget")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "Can't defer that",
                isPresented: Binding(
                    get: { deferralError != nil },
                    set: { if !$0 { deferralError = nil } }
                ),
                actions: { Button("OK", role: .cancel) { deferralError = nil } },
                message: { Text(deferralError ?? "") }
            )
        }
    }

    // MARK: Sections

    private func verdictSection(_ report: GateReport) -> some View {
        DashboardSection(
            report.passed ? "Gate: PASS" : "Gate: FAIL",
            subtitle: report.passed
                ? "No error-severity findings. This build may merge."
                : "\(report.errors.count) error-severity finding(s). This build is blocked."
        ) {
            HStack(alignment: .top, spacing: 10) {
                MetricTile(
                    label: "Baseline TTFF",
                    value: String(format: "%.0f ms", report.baselineTimeToFirstFrameMs)
                )
                MetricTile(
                    label: "Candidate",
                    value: String(format: "%.0f ms", report.candidateTimeToFirstFrameMs),
                    caption: String(format: "%+.0f ms (%+.0f%%)", report.deltaMilliseconds, report.deltaPercent * 100),
                    tint: report.deltaMilliseconds > 0 ? .red : .green
                )
                MetricTile(
                    label: "Critical path",
                    value: String(format: "%.0f ms", report.criticalPath?.durationMilliseconds ?? 0),
                    caption: String(format: "%.0f ms deferred", report.criticalPath?.deferredMilliseconds ?? 0),
                    tint: .blue
                )
            }
        }
    }

    private func controlsSection() -> some View {
        DashboardSection(
            "Inputs",
            subtitle: "The two things a lead argues about: does the newer OS retire this problem, and does the gate fire on noise?"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Cost model", selection: $costModelChoice) {
                    ForEach(CostModelChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Candidate", selection: $candidateChoice) {
                    ForEach(CandidateChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func preMainSection(_ report: GateReport, plan: LinkagePlan) -> some View {
        let estimate = report.predictedPreMain
        return DashboardSection(
            "Predicted pre-main",
            subtitle: "\(estimate.modelName) · \(estimate.provenance.rawValue) model. "
                + String(format: "%.0f%% of predicted pre-main is linkage, not code.", estimate.linkageAttributableShare * 100)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                StackedBar(segments: [
                    .init(id: "images", value: estimate.dynamicImageMilliseconds, color: .red),
                    .init(id: "fixed", value: estimate.fixedOverheadMilliseconds, color: .orange),
                    .init(id: "staticInit", value: estimate.staticInitializerMilliseconds, color: .yellow),
                    .init(id: "load", value: estimate.objcLoadMilliseconds, color: .purple)
                ])

                HStack(spacing: 10) {
                    legend(.red, "\(estimate.dynamicImageCount) images", estimate.dynamicImageMilliseconds)
                    legend(.orange, "dyld fixed", estimate.fixedOverheadMilliseconds)
                }
                HStack(spacing: 10) {
                    legend(.yellow, "static init", estimate.staticInitializerMilliseconds)
                    legend(.purple, "\(plan.objcLoadCount) +load", estimate.objcLoadMilliseconds)
                }

                Text(String(format: "total %.1f ms", estimate.totalMilliseconds))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2)
            Text(String(format: "%.1f ms", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkageSection(graph: ModuleGraph, plan: LinkagePlan) -> some View {
        DashboardSection(
            "Resolved linkage",
            subtitle: "\(plan.dynamicImageCount) dynamic images after resolution. "
                + "\(plan.overriddenModules.count) module(s) did not get the linkage they declared."
        ) {
            VStack(spacing: 0) {
                ForEach(graph.orderedDescriptors, id: \.id) { descriptor in
                    LinkageRow(
                        module: descriptor,
                        effective: plan.linkage(for: descriptor.id) ?? descriptor.declaredLinkage,
                        wasOverridden: plan.overriddenModules.contains(descriptor.id)
                    )
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private func criticalPathSection() -> some View {
        let analysis = schedule?.criticalPath()
        let onPath = Set(analysis?.path ?? [])
        return DashboardSection(
            "Critical path",
            subtitle: analysis.map {
                String(
                    format: "%.1f ms over %d items. Serial total would be %.1f ms, so %.1f ms is already overlapped. "
                        + "Shortening anything off this path changes nothing.",
                    $0.durationMilliseconds, $0.path.count, $0.serialMilliseconds, $0.concurrencyHeadroomMilliseconds
                )
            } ?? "Schedule is invalid."
        ) {
            VStack(spacing: 0) {
                ForEach(scheduleItems.filter { onPath.contains($0.id) || deferredItems.contains($0.id) }, id: \.id) { item in
                    CriticalPathRow(
                        item: item,
                        isDeferred: deferredItems.contains(item.id),
                        isDeferrable: item.phase != .preMain,
                        blockedReason: nil,
                        onToggle: { toggleDeferral(of: item.id) }
                    )
                    Divider().opacity(0.3)
                }

                if let analysis, let heaviest = analysis.heaviestOwner {
                    Text("Heaviest owner on the path: \(heaviest.module.rawValue) — "
                         + "\(Milliseconds.format(heaviest.milliseconds)) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func findingsSection(_ report: GateReport) -> some View {
        DashboardSection(
            "Findings",
            subtitle: "\(report.errors.count) error · \(report.warnings.count) warning"
        ) {
            VStack(spacing: 0) {
                if report.findings.isEmpty {
                    Text("Nothing to report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Indexed identity is deliberate: two findings can carry the same
                    // message text (e.g. the same module breaching two phase budgets),
                    // so message alone is not a stable unique id for ForEach.
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { entry in
                        FindingRow(severity: entry.element.severity, message: entry.element.message)
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func consoleSection(_ report: GateReport) -> some View {
        DashboardSection("CI output", subtitle: "Exactly what the build log would print.") {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(report.consoleReport())
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Actions

    /// Attempt to move a work item past the first frame.
    ///
    /// The interesting branch is the failure: `StartupSchedule` refuses a deferral
    /// that would leave a critical-path item depending on deferred work, and reports
    /// exactly which dependency blocks it. Surfacing that verbatim is the point of
    /// the interaction — "you can't defer this until you break its dependency on X"
    /// is the actual engineering answer.
    private func toggleDeferral(of id: WorkItemID) {
        var next = deferredItems
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }

        let candidateItems = SampleWorkspace.startupWorkItems.map { item -> StartupWorkItem in
            guard next.contains(item.id) else { return item }
            return StartupWorkItem(
                id: item.id,
                owner: item.owner,
                phase: .postFirstFrame,
                durationMilliseconds: item.durationMilliseconds,
                dependencies: item.dependencies,
                summary: item.summary
            )
        }

        do {
            _ = try StartupSchedule(items: candidateItems)
            deferredItems = next
        } catch let error as StartupScheduleError {
            deferralError = error.description
        } catch {
            deferralError = "Unexpected scheduling error."
        }
    }
}

#Preview {
    LaunchBudgetDashboard()
}

#endif
