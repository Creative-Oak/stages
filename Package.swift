// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Stages",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "StageReader", targets: ["StageReader"]),
    .library(name: "WindowSource", targets: ["WindowSource"]),
    .executable(name: "stagesctl", targets: ["stagesctl"]),
  ],
  targets: [
    // Pure rules: [RawWindow] -> StageSnapshot. Everything Stage-Manager-specific lives here.
    .target(name: "StageReader"),
    // CGWindowList capture and polling. Injectable so tests can feed fixtures.
    .target(name: "WindowSource", dependencies: ["StageReader"]),
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
  ]
)
