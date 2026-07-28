//
//  Formatting.swift
//  LaunchBudgetCore
//
//  One tiny helper, for one specific portability reason.
//
//  `String(format: "%@", someSwiftString)` is not portable: on Darwin `%@` takes an
//  Objective-C object and a Swift `String` bridges into one, but on Linux Foundation
//  there is no such bridge and the result is garbage or a trap. Since this library is
//  meant to run inside a CI tool as happily as inside an app — and its own tests run
//  on Linux — every user-facing string here is built by interpolation, and only
//  *numeric* formatting goes through `String(format:)`, which is portable.
//

import Foundation

/// Millisecond formatting used across reports.
public enum Milliseconds {
    /// One decimal place, no unit suffix. The caller appends " ms" so that call sites
    /// read as sentences rather than as format strings.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    /// Signed, for deltas, so "+3.2" and "-3.2" both read unambiguously.
    public static func signed(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%+.1f", value)
    }

    /// Percentage with no decimals.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }
}
