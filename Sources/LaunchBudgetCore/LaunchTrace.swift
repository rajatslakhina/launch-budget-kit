//
//  LaunchTrace.swift
//  LaunchBudgetCore
//
//  Turning a sampled launch trace into per-module attribution.
//
//  Why sampling, and why this is subtler than it looks
//  ---------------------------------------------------
//  A launch profile is a set of stack samples taken at a fixed interval. Attribution
//  is the step where "here are 4,000 stacks" becomes "UIKitBridge owns 18 ms" — and
//  it is where naive implementations quietly produce numbers that add up to more than
//  100%.
//
//  Two rules make it correct:
//
//  1. **Self time** is charged to the module at the *top* of the stack only. That is
//     the module actually executing when the sample was taken.
//  2. **Total time** is charged to every *distinct* module in the stack. The
//     "distinct" is the part that gets missed: a stack that re-enters the same module
//     (A → B → A, which is normal for anything with a callback or a protocol
//     witness) must charge that module once for the sample, not twice. Without the
//     dedupe, total time for recursive modules inflates without bound and the biggest
//     offender in your report becomes whichever module has the deepest re-entrancy.
//
//  Self time sums to exactly the trace duration. Total time deliberately does not —
//  it double-counts across the caller/callee relationship by design, which is what
//  makes it useful for "how much launch time flows *through* this module".
//

import Foundation

/// One stack sample from a launch profile.
public struct LaunchSample: Sendable, Equatable, Codable {
    /// Nanoseconds since the start of the trace.
    public let timestampNanos: UInt64

    /// Call stack, root first, leaf last — the same order the App Launch instrument
    /// presents it in.
    public let stack: [ModuleID]

    /// Which launch phase this sample fell in.
    public let phase: LaunchPhase

    public init(timestampNanos: UInt64, stack: [ModuleID], phase: LaunchPhase) {
        self.timestampNanos = timestampNanos
        self.stack = stack
        self.phase = phase
    }

    /// The module actually executing. `nil` for an empty stack, which a real profiler
    /// does emit (idle / unsymbolicated samples) and which must not be silently
    /// attributed to anyone.
    public var leaf: ModuleID? { stack.last }
}

/// Per-module attribution for one trace.
public struct ModuleAttribution: Sendable, Equatable {
    public let module: ModuleID

    /// Time this module was itself executing.
    public let selfMilliseconds: Double

    /// Time spent anywhere below this module in the stack, including itself.
    public let totalMilliseconds: Double

    /// Number of samples in which this module was the leaf.
    public let selfSampleCount: Int

    /// Split of self time by phase — the number that tells you whether a module's
    /// cost is pre-main (linkage's problem) or post-main (the schedule's problem).
    public let selfMillisecondsByPhase: [LaunchPhase: Double]

    public func selfMilliseconds(in phase: LaunchPhase) -> Double {
        selfMillisecondsByPhase[phase] ?? 0
    }

    /// Self time inside the launch window only — pre-main plus pre-first-frame.
    ///
    /// This, not `selfMilliseconds`, is what a launch budget is denominated in.
    /// `selfMilliseconds` spans the whole trace including post-first-frame work, and
    /// comparing that against a time-to-first-frame total mixes two different windows:
    /// a module whose *deferred* work got slower would fail the gate even though the
    /// user-visible launch did not move at all. That is exactly the false positive
    /// that gets a launch gate switched off.
    public var launchWindowSelfMilliseconds: Double {
        selfMilliseconds(in: .preMain) + selfMilliseconds(in: .preFirstFrame)
    }
}

/// A complete launch trace.
public struct LaunchTrace: Sendable, Equatable, Codable {
    /// Human-readable label, e.g. a build number or commit SHA.
    public let label: String

    /// Nominal sampling interval. Each sample is charged this much time.
    public let sampleIntervalNanos: UInt64

    public let samples: [LaunchSample]

    public init(label: String, sampleIntervalNanos: UInt64, samples: [LaunchSample]) {
        self.label = label
        // A zero sample interval would make every duration zero and every comparison
        // trivially pass — a silently useless trace. Clamp to 1 ns so the numbers stay
        // meaningless-but-nonzero and the caller can see something is wrong.
        self.sampleIntervalNanos = max(1, sampleIntervalNanos)
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case label, sampleIntervalNanos, samples
    }

    /// Explicit decoding initialiser, delegating to the memberwise one.
    ///
    /// This is not boilerplate. Swift's *synthesised* `init(from:)` assigns stored
    /// properties directly and never runs the clamping in the memberwise init — so a
    /// trace file with `"sampleIntervalNanos": 0` would decode unclamped, every
    /// duration would compute to zero, and the gate would pass everything silently.
    /// Since decoding from JSON is the documented way to feed the gate in CI, that is
    /// the *primary* path, not an edge case: the sanitisation has to survive it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decode(String.self, forKey: .label),
            sampleIntervalNanos: try container.decode(UInt64.self, forKey: .sampleIntervalNanos),
            samples: try container.decode([LaunchSample].self, forKey: .samples)
        )
    }

    private var millisecondsPerSample: Double {
        Double(sampleIntervalNanos) / 1_000_000.0
    }

    /// Total wall-clock duration represented by this trace.
    public var durationMilliseconds: Double {
        Double(samples.count) * millisecondsPerSample
    }

    /// Duration attributed to one phase.
    public func durationMilliseconds(in phase: LaunchPhase) -> Double {
        Double(samples.filter { $0.phase == phase }.count) * millisecondsPerSample
    }

    /// Duration of everything that happens before the first frame is committed —
    /// the number a user would call "how long the app took to open".
    public var timeToFirstFrameMilliseconds: Double {
        durationMilliseconds(in: .preMain) + durationMilliseconds(in: .preFirstFrame)
    }

    /// Samples with no resolvable frames. Reported rather than dropped: a trace that
    /// is 40% unsymbolicated is a trace whose attribution should not be trusted, and
    /// the only way anyone finds that out is if the number is on the report.
    public var unattributedSampleCount: Int {
        samples.filter { $0.stack.isEmpty }.count
    }

    public var unattributedMilliseconds: Double {
        Double(unattributedSampleCount) * millisecondsPerSample
    }

    /// Per-module attribution across the whole trace.
    ///
    /// Single pass over the samples; `Set` dedupe per sample keeps total time honest
    /// for re-entrant stacks (see the note at the top of this file).
    public func attribution() -> [ModuleID: ModuleAttribution] {
        let perSample = millisecondsPerSample

        var selfTime: [ModuleID: Double] = [:]
        var totalTime: [ModuleID: Double] = [:]
        var selfCount: [ModuleID: Int] = [:]
        var selfByPhase: [ModuleID: [LaunchPhase: Double]] = [:]

        for sample in samples {
            guard let leaf = sample.leaf else { continue }

            selfTime[leaf, default: 0] += perSample
            selfCount[leaf, default: 0] += 1
            selfByPhase[leaf, default: [:]][sample.phase, default: 0] += perSample

            // Dedupe: charge each distinct module in the stack exactly once for this
            // sample, no matter how many times it appears.
            var charged: Set<ModuleID> = []
            charged.reserveCapacity(sample.stack.count)
            for frame in sample.stack where charged.insert(frame).inserted {
                totalTime[frame, default: 0] += perSample
            }
        }

        var result: [ModuleID: ModuleAttribution] = [:]
        result.reserveCapacity(totalTime.count)
        for (module, total) in totalTime {
            result[module] = ModuleAttribution(
                module: module,
                selfMilliseconds: selfTime[module] ?? 0,
                totalMilliseconds: total,
                selfSampleCount: selfCount[module] ?? 0,
                selfMillisecondsByPhase: selfByPhase[module] ?? [:]
            )
        }
        return result
    }

    /// Attribution sorted by self time, heaviest first — the ordering a flamegraph
    /// summary table uses.
    public func rankedAttribution() -> [ModuleAttribution] {
        attribution()
            .values
            .sorted { lhs, rhs in
                if lhs.selfMilliseconds != rhs.selfMilliseconds {
                    return lhs.selfMilliseconds > rhs.selfMilliseconds
                }
                return lhs.module.rawValue < rhs.module.rawValue
            }
    }

    /// Attribution sorted by cost *inside the launch window* — the ordering that
    /// answers "who is making launch slow".
    ///
    /// `rankedAttribution()` sorts by whole-trace self time, which is the right
    /// ordering for a flamegraph and the wrong one for a budget: a module doing 9 ms
    /// of deliberately-deferred post-first-frame work would outrank modules that
    /// actually cost launch time. Same reasoning as `launchWindowSelfMilliseconds`.
    public func rankedByLaunchWindow() -> [ModuleAttribution] {
        attribution()
            .values
            .sorted { lhs, rhs in
                if lhs.launchWindowSelfMilliseconds != rhs.launchWindowSelfMilliseconds {
                    return lhs.launchWindowSelfMilliseconds > rhs.launchWindowSelfMilliseconds
                }
                return lhs.module.rawValue < rhs.module.rawValue
            }
    }

    /// Safe indexed access into the ranked attribution.
    ///
    /// Exists because the natural UI call site is `rows[indexPath.row]`, and a trace
    /// that shrinks between a reload and a render is exactly how that becomes a crash.
    public func rankedAttribution(at index: Int) -> ModuleAttribution? {
        let ranked = rankedAttribution()
        guard ranked.indices.contains(index) else { return nil }
        return ranked[index]
    }
}
