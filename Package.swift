// swift-tools-version: 6.0
//
//  Package.swift
//  LaunchBudgetKit
//
//  Note on structure: this package deliberately declares NO executable product.
//  The runnable demo lives in a separate repository with its own .xcodeproj, which
//  consumes this package by its git URL exactly the way any other client would.
//  See the "Demo app" section of README.md.
//

import PackageDescription

let package = Package(
    name: "LaunchBudgetKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // The whole budget system: graph, linkage resolver, cost model, startup
        // schedule, trace attribution, CI gate. No UIKit or SwiftUI dependency, so it
        // is usable from a command-line CI tool as well as from an app.
        .library(name: "LaunchBudgetCore", targets: ["LaunchBudgetCore"]),

        // SwiftUI presentation of the above. Depends on LaunchBudgetCore and
        // re-exports it, so a client only needs to import this one.
        .library(name: "LaunchBudgetKitUI", targets: ["LaunchBudgetKitUI"])
    ],
    targets: [
        .target(name: "LaunchBudgetCore"),
        .target(
            name: "LaunchBudgetKitUI",
            dependencies: ["LaunchBudgetCore"]
        ),
        .testTarget(
            name: "LaunchBudgetCoreTests",
            dependencies: ["LaunchBudgetCore"]
        )
    ]
)
