// swift-tools-version: 6.0
// The muxFinder package: core library, the app's view-model and view library, helper
// executables, the menu bar app and their tests.

import PackageDescription

let package = Package(
  name: "muxFinder",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MuxFinderCore", targets: ["MuxFinderCore"]),
    .library(name: "MuxFinderUI", targets: ["MuxFinderUI"]),
    .executable(name: "muxfinder-launch", targets: ["muxfinder-launch"]),
    .executable(name: "muxfinder-probe", targets: ["muxfinder-probe"]),
    .executable(name: "MuxFinderApp", targets: ["MuxFinderApp"]),
  ],
  targets: [
    .target(name: "MuxFinderCore"),
    .target(name: "MuxFinderUI", dependencies: ["MuxFinderCore"]),
    .executableTarget(name: "muxfinder-launch", dependencies: ["MuxFinderCore"]),
    .executableTarget(name: "muxfinder-probe", dependencies: ["MuxFinderCore"]),
    .executableTarget(name: "MuxFinderApp", dependencies: ["MuxFinderCore", "MuxFinderUI"]),
    .testTarget(
      name: "MuxFinderCoreTests",
      dependencies: ["MuxFinderCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "MuxFinderUITests",
      dependencies: ["MuxFinderUI", "MuxFinderCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
