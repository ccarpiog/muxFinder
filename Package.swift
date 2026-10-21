// swift-tools-version: 6.0
// The muxFinder package: core library, helper executables, the menu bar app and its tests.

import PackageDescription

let package = Package(
  name: "muxFinder",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MuxFinderCore", targets: ["MuxFinderCore"]),
    .executable(name: "muxfinder-launch", targets: ["muxfinder-launch"]),
    .executable(name: "muxfinder-probe", targets: ["muxfinder-probe"]),
    .executable(name: "MuxFinderApp", targets: ["MuxFinderApp"]),
  ],
  targets: [
    .target(name: "MuxFinderCore"),
    .executableTarget(name: "muxfinder-launch", dependencies: ["MuxFinderCore"]),
    .executableTarget(name: "muxfinder-probe", dependencies: ["MuxFinderCore"]),
    .executableTarget(name: "MuxFinderApp", dependencies: ["MuxFinderCore"]),
    .testTarget(
      name: "MuxFinderCoreTests",
      dependencies: ["MuxFinderCore"],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
