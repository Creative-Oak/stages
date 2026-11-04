// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Stages",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "StageReader", targets: ["StageReader"]),
    .library(name: "WindowSource", targets: ["WindowSource"]),
    .library(name: "StageStore", targets: ["StageStore"]),
    .library(name: "Switcher", targets: ["Switcher"]),
    .library(name: "Commands", targets: ["Commands"]),
    .library(name: "ActivityLog", targets: ["ActivityLog"]),
    .executable(name: "stagesctl", targets: ["stagesctl"]),
  ],
  targets: [
    // Pure rules: [RawWindow] -> StageSnapshot. Everything Stage-Manager-specific lives here.
    .target(name: "StageReader"),
    // CGWindowList capture and polling. Injectable so tests can feed fixtures.
    .target(name: "WindowSource", dependencies: ["StageReader"]),
    // Stage records (name, ink, slot) matched to snapshots, persisted as JSON.
    .target(name: "StageStore", dependencies: ["StageReader"]),
    // Switcher logic: MRU and cycle order, filtering, the hold-modifier session. Pure.
    .target(name: "Switcher", dependencies: ["StageReader"]),
    // stages:// URL parsing (Raycast Quicklinks). Pure.
    .target(name: "Commands", dependencies: ["StageReader"]),
    // Append-only JSONL of centre-stage changes. Local only.
    .target(name: "ActivityLog"),
    // Debug CLI: record fixtures, read live or recorded captures, watch committed snapshots.
    .executableTarget(
      name: "stagesctl", dependencies: ["StageReader", "WindowSource"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "StageReaderTests",
      dependencies: ["StageReader"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "StageStoreTests", dependencies: ["StageStore", "StageReader"]),
    .testTarget(name: "SwitcherTests", dependencies: ["Switcher"]),
    .testTarget(name: "CommandsTests", dependencies: ["Commands"]),
    .testTarget(name: "ActivityLogTests", dependencies: ["ActivityLog"]),
  ]
)
