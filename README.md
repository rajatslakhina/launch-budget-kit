# LaunchBudgetKit

**Apple made the dynamic loader roughly twice as fast in iOS 27. Silicon is about 10× faster than it was in 2016. So why does your app still take the same second and a half to open?**

Because launch time was never really a *performance* problem. It's an **architecture** problem that gets paid for in milliseconds — and the platform getting faster just raises the ceiling on how much architecture you can get away with before anyone notices.

LaunchBudgetKit treats pre-main and time-to-first-frame as an **owned, enforced, per-module budget** rather than something you profile once a year when someone complains. It is the policy layer an Engineering Lead writes so that every other team's locally-reasonable decisions can't quietly add up to a slow app.

```
── Launch Budget Gate ─────────────────────────────
  baseline TTFF : 45.0 ms
  candidate TTFF: 64.0 ms  (+19.0 ms, +42.2%)
  predicted pre-main: 22.4 ms via iOS 27 [published]
    └ 9 dynamic images → 11.5 ms (51% of pre-main)
  critical path : 35.4 ms over 6 items (serial would be 44.2 ms)
    └ heaviest owner: dyld (14.0 ms)

  [error] Analytics self time regressed 8.0 ms (3.0 → 11.0 ms), over its 2.0 ms threshold.
  [error] Analytics used 11.0 ms pre-main against a 3.0 ms budget.
  [error] Persistence used 15.0 ms before first frame against a 10.0 ms budget.
  [error] VendorAttributionSDK consumed 6.0 ms of launch but has no declared budget.
  [error] 6.0 ms of the 19.0 ms regression could not be attributed to any module (only 13.0 ms was).
  [error] linkage — <graph>: resolved to 9 dynamic images, over the policy ceiling of 6.
  [warning] linkage — DesignSystem: declared mergeable but linked by dynamic image(s)
            CheckoutFeature, HomeFeature, SearchFeature — falls back to a separate dynamic image.
  [info] predicted pre-main of 22.4 ms was NOT gated on — the cost model is uncalibrated.

  RESULT: FAIL
───────────────────────────────────────────────────
```

That output is produced by real, tested code in this repo, from a manifest and two trace files. Every line of it is a decision someone has to own.

---

## Why this matters

Three things are true at once, and together they're the whole argument:

1. **Launch cost is graph-shaped, not file-shaped.** Every module author picks `.static` or `.dynamic` or mergeable *locally*, in their own package manifest. But whether a mergeable module actually merges depends on who links it — a graph-level property nobody can see from inside their own module. Forty teams making forty locally-correct decisions is how an app ends up with forty dynamic images.

2. **The expensive work is the work nobody thinks they're doing.** `+load` and static initialisers run before `main()` whether or not the feature is ever used. A team can be genuinely certain their module "isn't on the launch path" while shipping three `+load` implementations that run on every cold launch, forever.

3. **iOS 27 makes this *less* visible, not less real.** The loader got faster (published figures: closure rebuild ~1.5×, fixups ~2.5×, static-initialiser dispatch ~3×, ~21–23% end to end). Your own `+load` body did not. So the share of launch time you control goes *up* while the absolute number goes down — which is exactly the condition under which a budget stops being enforced and starts being decorative.

The deliverable here isn't a screen. It's a **policy other teams build against**, plus the CI gate that makes it real.

---

## What's in the box

Four interacting layers. Each one is useless alone; the point is the composition.

### 1. `ModuleGraph` — a validated dependency graph

Construction is failable-by-throwing and validates duplicates, dangling edges, and cycles (Kahn's algorithm, with a concrete cycle path in the error — "there is a cycle somewhere in your 200 modules" is not an actionable message). Everything downstream can then assume acyclicity without re-checking.

Both the topological sort and the transitive-closure walk are **iterative, not recursive**. A deep module graph is a real thing, and blowing the stack inside a CI gate is a bad way to find out.

### 2. `LinkageResolver` — declared linkage → *effective* linkage

The graph-level algorithm that makes the invisible visible. Five linear passes:

| Rule | What it catches |
|---|---|
| **Merge denial** | A `.mergeable` module linked by any dynamic image can't merge. It silently becomes a dynamic image and keeps paying per-image cost — while its manifest still says "mergeable". |
| **Merge-denial cascade** | If a mergeable module is demoted, every mergeable module *it* depends on is now linked by a dynamic image and must be demoted too. Resolved in one pass by iterating in **reverse** topological order. |
| **Static duplication** | A `.static` module linked by N dynamic frameworks is physically copied N times. Nobody's setting is wrong; the graph shape is. |
| **Unconditional work off the launch path** | A module declaring `participatesInFirstFrame: false` that ships `+load` or static initialisers is on the launch path anyway. |
| **Image ceiling** | The org-wide cap. Attributed to `<graph>`, not to whichever module happened to be added last — blaming the newcomer is how a ceiling rule gets gamed and then ignored. |

### 3. `StartupSchedule` — the deferred-init critical path

A DAG of startup work items, each owned by exactly one module, each declared to run `preMain` / `preFirstFrame` / `postFirstFrame`.

**The invariant that makes this worth having: an item in an earlier phase may never depend on an item in a later phase.** That's a compile-time-shaped check for a bug class that has no compile-time signal today:

> A team moves analytics init to "after first frame". Six months later, the session restorer — which *is* on the critical path — starts reading a value analytics init populates. Nothing crashes. Nothing in the diff looks wrong. The deferral is now a lie.

`StartupSchedule.init` rejects it, and names the exact dependency that makes it illegal. `moving(_:to:)` returns a `Result` instead of throwing, so a UI can offer "what if we deferred this?" as a live exploration — and the refusal is the useful answer: *you can't defer this until you break its dependency on X.*

Critical path is longest-path over the DAG, relaxed in topological order (linear, because acyclicity was already proved at construction). It also reports serial total and concurrency headroom, because "shorten this item" is worthless advice for anything off the path.

### 4. `LaunchTrace` + `BudgetGate` — attribution and enforcement

Attribution has one subtlety that inflates every naive implementation:

- **Self time** goes to the top of the stack only.
- **Total time** goes to every *distinct* module in the stack. A stack that re-enters the same module (`A → B → A`, normal for anything with a callback or a protocol witness) must charge it **once per sample**, not three times. Without the dedupe, whichever module has the deepest re-entrancy always tops your report regardless of what it costs.

The gate is designed around the ways a gate like this dies in a real org:

| Failure mode | Design response |
|---|---|
| Gate is noisy → gets disabled | Explicit noise floor. A delta inside it is never a failure, regardless of relative thresholds. |
| Gate can't name an owner → gets ignored | Every regression is attributed to a module with a declared budget. |
| Gate *can't* attribute it → guesses | `unattributedRegression` is a first-class finding. Cost belonging to an undeclared module is deliberately **not** counted as attributed — otherwise an unowned dependency explains away the very regression it caused. |
| Gate fails builds on an uncalibrated guess → distrusted | Absolute-threshold checks on predicted pre-main are **suppressed** unless `CostModelProvenance == .calibrated`, and the report says so out loud. |
| Budget decays by addition | A module in the trace with no manifest entry is a hard failure. Otherwise every new module is exempt and in two years nothing is covered. |
| Trace is half unsymbolicated → confident numbers about nothing | >20% unresolvable samples fails before its numbers are believed. |

---

## Design decisions, and what was rejected

**The cost model ships as a *model*, and says so.** `DyldCostModel.iOS26` / `.iOS27` are seeded from published platform figures, and iOS 27 is expressed as *ratios applied to the iOS 26 profile* rather than as a second pile of magic numbers, so the relationship stays auditable. Every model carries `CostModelProvenance`, and the gate refuses to fail a build on an uncalibrated absolute number.

> *Rejected:* shipping the seeded numbers as if they predicted your app. It would demo better and be dishonest. `calibrated(againstObservedPreMain:plan:)` fits the per-image term against one real trace — a single-degree-of-freedom fit, which is the honest thing to do with one data point, and it **refuses** rather than clamping when the residual comes out negative, because a negative residual means the model's shape is wrong for your app and hiding that is worse than failing.

**`+load` cost is deliberately *not* discounted on iOS 27.** A faster loader doesn't make your own `+load` body run faster. That asymmetry is the entire reason this library still matters on iOS 27, and encoding it is a claim the code makes on purpose.

**Everything is a `Sendable` value type; there is not one actor.** A budget system is evaluated in CI, from a manifest and a trace file. There is no long-lived mutable state to protect. Reaching for an actor here would be concurrency cosplay.

> *Rejected:* an `actor BudgetEvaluator`. It would look more "Swift 6", add a suspension point to every call, and protect nothing.

**Validation happens once, at construction.** `ModuleGraph` and `StartupSchedule` can only be built through throwing initialisers that prove their invariants. The alternative — passing arrays around and defending in each algorithm — means every new algorithm is a new chance to forget.

**Determinism is treated as a correctness property, not a nicety.** Topological seeds are sorted, ties are broken by name, and `findings` sorts by severity *then message* because Swift's sort isn't stable. A CI report that reorders itself between identical runs is a report nobody diffs.

**No `%@` anywhere.** `String(format: "%@", swiftString)` works on Darwin via ObjC bridging and produces garbage on Linux. Every user-facing string is interpolated; only numeric formatting goes through `String(format:)`. That's what lets the core build and test headlessly on Linux — see verification below.

---

## Crash-safety rules this codebase holds itself to

- **No force-unwraps.** Not one `!` in `Sources/`. Where a lookup provably can't fail, `compactMap` is used instead, so a future refactor that breaks the invariant degrades rather than traps.
- **Every collection access is bounds-checked.** `LaunchTrace.rankedAttribution(at:)` exists precisely because the natural call site is `rows[indexPath.row]`.
- **Every numeric input is sanitised at the boundary.** Negative budgets, negative `+load` counts, negative sample counts, and a zero sample interval are all clamped at construction. `NaN` durations are neutralised — all comparisons against `NaN` are false, so an unsanitised `NaN` would make the longest-path relaxation silently skip every update and report a *confidently wrong* number.
- **Loops that walk a graph are bounded even where the invariant already guarantees termination**, so a broken invariant fails a test instead of hanging CI.

---

## Verification — exactly what was and wasn't checked

Being specific, because "it builds" and "it works" are different claims:

- ✅ **`swift build` succeeds** in debug and release, Swift 6 language mode (`swift-tools-version: 6.0`, toolchain 6.2, Linux aarch64).
- ✅ **`swift test` passes 94/94.** Coverage is weighted toward the degenerate inputs rather than the happy path: empty graphs, self-edges, 4-node cycles, a 2,000-deep dependency chain, out-of-range and `Int.min`/`Int.max` indices, `NaN`/`±∞`/negative durations, zero sample intervals, empty traces, fully-unsymbolicated traces, re-entrant stacks, merge-denial cascades, calibration refusals, and determinism (asserted by running the same computation 20× and comparing).
- ✅ **`LaunchBudgetKitUI` compiles** — the SwiftUI sources are wrapped in `#if canImport(SwiftUI)`, so on Linux the target compiles to an empty module. That's what makes headless verification of the core possible.
- ⚠️ **The SwiftUI layer's *rendering* was not verified on Linux** and cannot be — `import SwiftUI` doesn't resolve there. It was verified by running the demo app on a real iOS Simulator instead; see the demo repo below for screenshots.

---

## Demo app

The runnable demo lives in its own repository and consumes this package **by its git URL**, exactly the way any external client would — not as a local path reference sitting next to it on disk:

**→ [launch-budget-kit-demo-app](https://github.com/rajatslakhina/launch-budget-kit-demo-app)**

This repo deliberately declares **no executable product and no app target**. A Swift Package `.executableTarget` run as an iOS app does not produce a stable `.app` bundle; it crashes 100% reproducibly on launch with `__BKSHIDEvent__BUNDLE_IDENTIFIER_FOR_CURRENT_PROCESS_IS_NIL__`, because the synthesised bundle identifier lives in a per-checkout Xcode setting that is never committed. The runnable app belongs in its own `.xcodeproj`.

---

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/launch-budget-kit.git", branch: "main")
```

```swift
import LaunchBudgetCore

let graph = try ModuleGraph(modules: myManifest)
let schedule = try StartupSchedule(items: myStartupWork)

let report = BudgetGate(
    policy: GatePolicy(noiseFloorMilliseconds: 2.0, totalRegressionTolerance: 0.03),
    linkageRules: LinkagePolicyRules(dynamicImageCeiling: 6)
).evaluate(
    baseline: try JSONDecoder().decode(LaunchTrace.self, from: baselineJSON),
    candidate: try JSONDecoder().decode(LaunchTrace.self, from: candidateJSON),
    graph: graph,
    schedule: schedule,
    costModel: .iOS27
)

print(report.consoleReport())
exit(report.passed ? 0 : 1)
```

`SampleWorkspace` ships a complete worked example — a plausible mid-size retail app whose manifest exercises every diagnostic — as a reference to copy, and as what the demo app renders.

To run the tests:

```bash
git clone https://github.com/rajatslakhina/launch-budget-kit.git
cd launch-budget-kit
swift test
```

---

## Requirements

Swift 6.0+ · iOS 17+ / macOS 14+ for `LaunchBudgetKitUI`. `LaunchBudgetCore` has no dependency beyond Foundation and builds anywhere Swift does, including inside a Linux CI container.

---

### Sources for the platform figures

- Jacob Bartlett — [How did Apple cut launch time by 30% in iOS 27?](https://blog.jacobstechtavern.com/p/ios-27-launch-time) and the [Launch30](https://github.com/jacobsapps/Launch30) experiment
- CodeColorist — [iOS 27 reworked stub islands](https://codecolor.ist/posts/2026-06-15-ios27-reworked-stub-islands/)

The coefficients derived from these are seeded defaults for *ranking* linkage plans, not predictions about your app. Calibrate them.
