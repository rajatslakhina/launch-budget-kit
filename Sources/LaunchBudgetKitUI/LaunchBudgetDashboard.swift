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

    /// Everything the body needs, derived exactly once per pass.
    ///
    /// `graph`, `plan`, `schedule` and `report` used to be four separate computed
    /// properties, so a single `body` pass rebuilt and re-validated the startup
    /// schedule three times and ran the linkage resolver twice. Harmless at this data
    /// size — and a bad look in a project whose entire subject is not doing redundant
    /// work at startup.
    private struct Snapshot {
        let graph: ModuleGraph
        let plan: LinkagePlan
        let schedule: StartupSchedule
        let report: GateReport
        let attribution: [ModuleAttribution]
    }

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

    private var snapshot: Snapshot? {
        guard let graph, let schedule else { return nil }
        let candidate = candidateChoice.trace
        let report = BudgetGate(policy: .default).evaluate(
            baseline: SampleWorkspace.baselineTrace,
            candidate: candidate,
            graph: graph,
            schedule: schedule,
            costModel: costModelChoice.model
        )
        return Snapshot(
            graph: graph,
            // Read off the report rather than resolving again. `BudgetGate` already ran
            // the resolver on this exact graph; running it a second time here is the
            // redundant work this whole type exists to remove.
            plan: report.linkagePlan,
            schedule: schedule,
            report: report,
            attribution: candidate.rankedByLaunchWindow()
        )
    }

    // MARK: Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let snapshot {
                        verdictSection(snapshot.report)
                        controlsSection()
                        preMainSection(snapshot.report, plan: snapshot.plan)
                        linkageSection(graph: snapshot.graph, plan: snapshot.plan)
                        criticalPathSection(snapshot.schedule)
                        attributionSection(snapshot.attribution)
                        findingsSection(snapshot.report)
                        consoleSection(snapshot.report)
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
            // `navigationBarTitleDisplayMode` is `@available(macOS, unavailable)`, and
            // `canImport(SwiftUI)` is true on macOS — so without this guard the package
            // would fail to build on a Mac while passing on Linux (where this whole
            // target compiles to an empty module). Platform-guarded rather than dropped,
            // because the inline title is what keeps the dense dashboard readable on a
            // phone.
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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

    private func criticalPathSection(_ schedule: StartupSchedule) -> some View {
        // Takes the already-validated schedule from the snapshot rather than
        // rebuilding it: recomputing `scheduleItems`, re-running phase-inversion
        // validation and re-running the topological sort on every body pass is
        // precisely the pattern this project is about not doing.
        let analysis = schedule.criticalPath()
        let onPath = Set(analysis.path)
        return DashboardSection(
            "Critical path",
            subtitle: String(
                format: "%.1f ms over %ld items. Serial total would be %.1f ms, so %.1f ms is already overlapped. "
                    + "Shortening anything off this path changes nothing.",
                analysis.durationMilliseconds, analysis.path.count,
                analysis.serialMilliseconds, analysis.concurrencyHeadroomMilliseconds
            )
        ) {
            VStack(spacing: 0) {
                ForEach(schedule.orderedItems.filter { onPath.contains($0.id) || deferredItems.contains($0.id) }, id: \.id) { item in
                    CriticalPathRow(
                        item: item,
                        isDeferred: deferredItems.contains(item.id),
                        isDeferrable: item.phase != .preMain,
                        onToggle: { toggleDeferral(of: item.id) }
                    )
                    Divider().opacity(0.3)
                }

                if let heaviest = analysis.heaviestOwner {
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

    /// Per-module trace attribution — the fourth layer, and the one that turns
    /// "launch got slower" into "this team's module got slower".
    private func attributionSection(_ ranked: [ModuleAttribution]) -> some View {
        DashboardSection(
            "Trace attribution",
            subtitle: "Ranked by cost inside the launch window, not by whole-trace self time — deferred "
                + "work is not a launch cost. Self time is charged to the top of the stack only; total time "
                + "to every distinct module in it, once per sample even for re-entrant stacks."
        ) {
            VStack(spacing: 0) {
                if ranked.isEmpty {
                    Text("No attributable samples in this trace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // `ranked` is already in hand — indexing it directly is safe
                    // because the indices come from `ranked.indices`. Calling the
                    // bounds-checked `rankedAttribution(at:)` here instead would
                    // re-materialise the trace and re-run the whole attribution once
                    // per row, which is the redundant work the `Snapshot` above exists
                    // to remove. (That accessor is for callers holding an index whose
                    // provenance they don't control; it is exercised in
                    // `TraceAttributionTests`.)
                    ForEach(Array(ranked.indices.prefix(8)), id: \.self) { index in
                        AttributionRow(entry: ranked[index])
                        Divider().opacity(0.3)
                    }
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
