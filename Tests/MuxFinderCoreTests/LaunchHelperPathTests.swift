import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for the D2 helper-path rule and for locating the helper next to an executable.
@Suite("Launch helper path")
struct LaunchHelperPathTests {
  /// Paths made of `[A-Za-z0-9._/-]` are accepted unchanged.
  @Test(arguments: [
    "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch",
    "/Users/ccarpio/Developer/Utils/muxFinder/.build/out/Products/Debug/muxfinder-launch",
    "/tmp/a_b-c.d/X9/muxfinder-launch",
    "/",
  ])
  func acceptsPlainPaths(path: String) throws {
    #expect(try LaunchHelperPath(validating: path).path == path)
  }

  /// Relative paths are refused as not absolute.
  @Test(arguments: ["", "muxfinder-launch", "./muxfinder-launch", "~/muxfinder-launch"])
  func refusesRelativePaths(path: String) {
    #expect(throws: LaunchHelperPathError.notAbsolute) { try LaunchHelperPath(validating: path) }
  }

  /// Spaces, quotes, `$`, backticks, shell operators, control characters and non-ASCII are
  /// refused, with the "move muxFinder to /Applications" message.
  @Test(arguments: [
    "/Applications/mux Finder.app/Contents/MacOS/muxfinder-launch",
    "/Users/o'neil/muxfinder-launch",
    #"/tmp/"quoted"/muxfinder-launch"#,
    "/tmp/$HOME/muxfinder-launch",
    "/tmp/$(id)/muxfinder-launch",
    "/tmp/`id`/muxfinder-launch",
    "/tmp/a;b/muxfinder-launch",
    "/tmp/a\tb/muxfinder-launch",
    "/tmp/a\nb/muxfinder-launch",
    "/Users/josé/muxfinder-launch",
    "/tmp/日本/muxfinder-launch",
    "/tmp/a~b/muxfinder-launch",
    "/tmp/a\\b/muxfinder-launch",
  ])
  func refusesSpecialCharacters(path: String) {
    #expect(throws: LaunchHelperPathError.unsupportedCharacters) {
      try LaunchHelperPath(validating: path)
    }
    #expect(LaunchHelperPathError.unsupportedCharacters.message.contains("/Applications"))
  }

  /// The tab's command line is the path, `attach` and the canonical id.
  @Test func buildsTheCommandLine() throws {
    let path = try LaunchHelperPath(validating: "/Applications/muxFinder.app/Contents/MacOS/x")
    let id = try #require(LaunchToken("0f8fad5b-d9cb-469f-a165-70867728950e"))
    #expect(
      path.attachCommandLine(for: id)
        == "/Applications/muxFinder.app/Contents/MacOS/x attach 0f8fad5b-d9cb-469f-a165-70867728950e"
    )
  }

  /// The helper is found next to the executable (symbolic links in the directory resolved),
  /// only as an executable regular file, and only in a plain path.
  @Test func locatesTheHelperNextToTheExecutable() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let macOS = root.appending(path: "muxFinder.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let app = macOS.appending(path: "muxFinder")
    let helper = macOS.appending(path: LaunchHelperPath.executableName)

    #expect(throws: LaunchHelperPathError.notFound) { try LaunchHelperPath.locate(nextTo: app) }
    try Data("#!/bin/sh\n".utf8).write(to: helper)
    #expect(throws: LaunchHelperPathError.notFound) { try LaunchHelperPath.locate(nextTo: app) }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: helper.path(percentEncoded: false)
    )
    let found = try LaunchHelperPath.locate(nextTo: app)
    let resolvedDirectory = try #require(realpath(macOS.path(percentEncoded: false), nil))
    defer { free(resolvedDirectory) }
    #expect(found.path == String(cString: resolvedDirectory) + "/muxfinder-launch")

    let linked = root.appending(path: "Linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: macOS)
    #expect(try LaunchHelperPath.locate(nextTo: linked.appending(path: "muxFinder")) == found)

    #expect(throws: LaunchHelperPathError.executableUnknown) {
      try LaunchHelperPath.locate(nextTo: nil)
    }
  } // End of func locatesTheHelperNextToTheExecutable()

  /// A helper in a folder whose name has a space is found but refused.
  @Test func refusesAHelperInASpacedFolder() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "mux Finder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let helper = folder.appending(path: LaunchHelperPath.executableName)
    try Data("#!/bin/sh\n".utf8).write(to: helper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: helper.path(percentEncoded: false)
    )
    #expect(throws: LaunchHelperPathError.unsupportedCharacters) {
      try LaunchHelperPath.locate(nextTo: folder.appending(path: "muxFinder"))
    }
  } // End of func refusesAHelperInASpacedFolder()
}
