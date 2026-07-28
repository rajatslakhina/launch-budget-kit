//
//  DashboardComponents.swift
//  LaunchBudgetKitUI
//
//  Small presentation pieces for LaunchBudgetDashboard.
//
//  The whole UI layer is wrapped in `#if canImport(SwiftUI)` so the package still
//  builds and its tests still run on a platform without SwiftUI (Linux CI, for
//  instance). On such a platform this target compiles to an empty module rather than
//  failing the build — which is what lets the core logic be verified headlessly.
//

#if canImport(SwiftUI)

import SwiftUI
@_exported import LaunchBudgetCore

// MARK: - Severity styling

extension LinkageDiagnostic.Severity {
    var tint: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

extension LinkagePolicy {
    var tint: Color {
        switch self {
        case .staticLibrary: return .green
        case .dynamicFramework: return .red
        case .mergeable: return .blue
        }
    }
}

// MARK: - Section container

struct DashboardSection<Content: View>: View {
    let title: String
    let subtitle: String?
    // No `@ViewBuilder` here: the explicit init below suppresses the memberwise
    // initialiser the attribute would apply to, so it would be a silent no-op.
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.09))
        )
    }
}

// MARK: - Stacked proportional bar

/// A horizontal stacked bar. Segments are laid out proportionally to their values.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 18

    private var total: Double {
        // Guarded below before being used as a divisor.
        segments.reduce(0) { $0 + max(0, $1.value) }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let totalValue = total
            // spacing: 0 — the segment widths already sum to exactly `width`, so any
            // spacing overflows the container (the clipShape was hiding it).
            HStack(spacing: 0) {
                if totalValue > 0 {
                    ForEach(segments) { segment in
                        let fraction = max(0, segment.value) / totalValue
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: width * fraction)
                    }
                } else {
                    // Empty-state: a graph with no measured cost still renders a bar
                    // rather than collapsing to nothing, so the layout does not jump.
                    Rectangle().fill(Color.secondary.opacity(0.2))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: height)
    }
}

// MARK: - Metric

struct MetricTile: View {
    let label: String
    let value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Linkage row

struct LinkageRow: View {
    let module: ModuleDescriptor
    let effective: LinkagePolicy
    let wasOverridden: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(module.id.rawValue)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 4)

            Text(module.declaredLinkage.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(wasOverridden ? Color.secondary : module.declaredLinkage.tint)
                .strikethrough(wasOverridden, color: .secondary)

            if wasOverridden {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(effective.displayName)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(effective.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Finding row

struct FindingRow: View {
    let severity: LinkageDiagnostic.Severity
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity.symbolName)
                .foregroundStyle(severity.tint)
                .font(.caption)
                .padding(.top, 2)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

// MARK: - Critical path row

struct CriticalPathRow: View {
    let item: StartupWorkItem
    let isDeferred: Bool
    let isDeferrable: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.id.rawValue)
                        .font(.caption.monospaced().weight(.medium))
                        .strikethrough(isDeferred, color: .secondary)
                    Text(item.phase.displayName)
                        .font(.system(size: 9).weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f ms", item.durationMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isDeferred ? .secondary : .primary)

                if isDeferrable {
                    Button(action: onToggle) {
                        Text(isDeferred ? "restore" : "defer")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Text("fixed")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Attribution row

struct AttributionRow: View {
    let entry: ModuleAttribution

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.module.rawValue)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text("self " + Milliseconds.format(entry.selfMilliseconds) + " ms")
                    .font(.caption2.monospacedDigit())
                Text("total " + Milliseconds.format(entry.totalMilliseconds) + " ms")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(Milliseconds.format(entry.launchWindowSelfMilliseconds) + " ms in launch")
                .font(.system(size: 9))
                .foregroundStyle(entry.launchWindowSelfMilliseconds > 0 ? Color.orange : Color.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

#endif
