import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The terminal definition loader's file rules (PLAN.md D19 and D38, Phase I-12b1), on private
/// temporary folders only: links, modes, owners, ACLs, sizes, counts, a missing or unsafe
/// folder, overrides and duplicate ids. The real terminals folder is never touched.
@Suite("Terminal definition loader")
struct TerminalDefinitionLoaderTests {
  /// Shorthand for the support enum.
  typealias Support = TerminalDefinitionTestSupport

  /// Runs `body` with a fresh private user folder, then removes it.
  func withUserFolder(_ body: (_ base: URL, _ user: URL) throws -> Void) throws {
    let (base, user) = try Support.makeUserFolder()
    defer {
      _ = chmod(user.path(percentEncoded: false), 0o700)
      try? FileManager.default.removeItem(at: base)
    }
    try body(base, user)
  }

  /// A good user definition loads as `user`; the folder is only read (nothing created or
  /// changed); hidden and non-`.json` files are ignored.
  @Test func loadsUserDefinitions() throws {
    try withUserFolder { _, user in
      try Support.writeDefinition(
        Support.appleScriptObject(id: "mine"), named: "mine.json", in: user)
      try Support.writeDefinition(
        Support.execObject(id: "wez"), named: "wez.json", in: user, mode: 0o644)
      try Support.write(Data("not json".utf8), named: "README.txt", in: user)
      try Support.write(Data("not json".utf8), named: ".hidden.json", in: user)
      let before = try FileManager.default.contentsOfDirectory(
        atPath: user.path(percentEncoded: false))
      let catalog = Support.load(user: user)
      #expect(catalog.problems.isEmpty)
      #expect(Support.sources(catalog) == ["mine:user", "wez:user"])
      let mine = try #require(catalog.definition(withID: "mine"))
      #expect(
        mine.script == TerminalScript(name: "sample.applescript", source: Support.sampleScript))
      #expect(catalog.definition(withID: "wez")?.script == nil)
      let after = try FileManager.default.contentsOfDirectory(
        atPath: user.path(percentEncoded: false))
      #expect(before.sorted() == after.sorted())
      var info = stat()
      try #require(lstat(user.path(percentEncoded: false), &info) == 0)
      #expect(info.st_mode & 0o7777 == 0o700)
    }
  } // End of func loadsUserDefinitions()

  /// A missing user folder is no problem, and nothing is created; built-ins still load.
  @Test func missingUserFolderIsFine() throws {
    try withUserFolder { base, _ in
      let missing = base.appending(path: "absent/terminals", directoryHint: .isDirectory)
      let catalog = Support.load(builtIn: Support.builtInDirectory, user: missing)
      #expect(catalog.problems.isEmpty)
      #expect(Support.sources(catalog) == ["ghostty:builtIn", "terminal:builtIn"])
      #expect(
        !FileManager.default.fileExists(
          atPath: base.appending(path: "absent").path(percentEncoded: false)))
      // A link on the way to nothing is missing too, not a problem.
      try FileManager.default.createSymbolicLink(
        atPath: base.appending(path: "dangling").path(percentEncoded: false),
        withDestinationPath: base.appending(path: "nowhere").path(percentEncoded: false))
      #expect(Support.load(user: base.appending(path: "dangling/terminals")).problems.isEmpty)
    }
  } // End of func missingUserFolderIsFine()

  /// An unsafe user folder makes every user definition unusable, with exactly one problem:
  /// its mode not 0700 (group or world access, or even 0755), another owner, an extended ACL,
  /// a symbolic link as the folder or on its path, a file in its place.
  @Test func unsafeUserFolderGivesOneProblem() throws {
    try withUserFolder { base, user in
      try Support.writeDefinition(
        Support.appleScriptObject(id: "mine"), named: "mine.json", in: user)
      try Support.writeDefinition(Support.execObject(id: "other"), named: "other.json", in: user)
      /// Expects the user folder at `folder` to give exactly one problem, `reason`, and only the built-ins.
      func expectOne(
        _ reason: TerminalDefinitionProblem.FolderReason, at folder: URL,
        owner: uid_t = geteuid()
      ) {
        let catalog = TerminalDefinitionLoader(
          builtInDirectory: Support.builtInDirectory,
          userDirectory: folder, owner: owner
        ).load()
        #expect(Support.sources(catalog) == ["ghostty:builtIn", "terminal:builtIn"])
        #expect(
          catalog.problems == [
            TerminalDefinitionFileProblem(
              folder: .user,
              fileName: folder.lastPathComponent, problem: .unsafeFolder(reason))
          ])
      } // End of func expectOne(_:at:owner:)
      let path = user.path(percentEncoded: false)
      for mode: mode_t in [0o755, 0o750, 0o701, 0o770, 0o500, 0o1700] {
        try #require(chmod(path, mode) == 0)
        expectOne(.permissionsNotPrivate, at: user)
      }
      try #require(chmod(path, 0o700) == 0)
      expectOne(.notOwnedByUser, at: user, owner: geteuid() + 1)
      try LaunchTestSupport.setACL(LaunchTestSupport.everyoneDenyDeleteACL, on: user)
      expectOne(.extendedACL, at: user)
      let folderDescriptor = open(path, O_RDONLY | O_DIRECTORY)
      try #require(folderDescriptor >= 0)
      defer { close(folderDescriptor) }
      try ExtendedACL.removeAll(from: folderDescriptor)
      // The folder itself a link.
      let link = base.appending(path: "linked", directoryHint: .notDirectory)
      try FileManager.default.createSymbolicLink(
        atPath: link.path(percentEncoded: false),
        withDestinationPath: path)
      expectOne(.symbolicLink, at: link)
      // A link on the way: the temporary folder through /var, and one made here.
      let unresolved = FileManager.default.temporaryDirectory
      if try Support.resolved(unresolved) != PrivateStorage.path(of: unresolved) {
        let viaVar = unresolved.appending(path: base.lastPathComponent + "/terminals")
        expectOne(.symbolicLink, at: viaVar)
      }
      let parentLink = base.appending(path: "parent", directoryHint: .notDirectory)
      try FileManager.default.createSymbolicLink(
        atPath: parentLink.path(percentEncoded: false),
        withDestinationPath: base.path(percentEncoded: false))
      expectOne(.symbolicLink, at: parentLink.appending(path: "terminals"))
      // A file where the folder goes.
      try Support.write(Data(), named: "plain-file", in: base)
      expectOne(.notAFolder, at: base.appending(path: "plain-file"))
      expectOne(.notAPlainPath, at: URL(fileURLWithPath: path + "/../terminals"))
    }
  } // End of func unsafeUserFolderGivesOneProblem()

  /// Each user file must be a regular file of the user's, opened without following a link,
  /// not group- or world-writable (readable is fine), with no extended ACL.
  @Test func refusesUnsafeUserFiles() throws {
    try withUserFolder { _, user in
      try Support.writeDefinition(
        Support.appleScriptObject(id: "good"), named: "good.json", in: user)
      try Support.writeDefinition(
        Support.execObject(id: "readable"), named: "readable.json", in: user,
        mode: 0o644)
      try Support.writeDefinition(
        Support.execObject(id: "group"), named: "group.json", in: user,
        mode: 0o620)
      try Support.writeDefinition(
        Support.execObject(id: "world"), named: "world.json", in: user,
        mode: 0o602)
      try Support.writeDefinition(Support.execObject(id: "acl"), named: "acl.json", in: user)
      try LaunchTestSupport.setACL(
        LaunchTestSupport.everyoneDenyDeleteACL,
        on: user.appending(path: "acl.json"))
      try FileManager.default.createSymbolicLink(
        atPath: user.appending(path: "link.json").path(percentEncoded: false),
        withDestinationPath: user.appending(path: "good.json").path(percentEncoded: false))
      try #require(
        mkfifo(user.appending(path: "fifo.json").path(percentEncoded: false), 0o600) == 0)
      try FileManager.default.createDirectory(
        at: user.appending(path: "folder.json"),
        withIntermediateDirectories: false)
      let catalog = Support.load(user: user)
      #expect(Support.sources(catalog) == ["good:user", "readable:user"])
      #expect(
        Support.problems(catalog) == [
          "user/acl.json: unsafeFile.extendedACL", "user/fifo.json: unsafeFile.notARegularFile",
          "user/folder.json: unsafeFile.notARegularFile",
          "user/group.json: unsafeFile.writableByOthers",
          "user/link.json: unsafeFile.symbolicLink", "user/world.json: unsafeFile.writableByOthers",
        ])
    }
  } // End of func refusesUnsafeUserFiles()

  /// A user file of another owner is refused (checked directly: the folder's own owner check
  /// comes first when loading).
  @Test func refusesAnotherOwnersFile() throws {
    try withUserFolder { _, user in
      try Support.writeDefinition(Support.execObject(), named: "x.json", in: user)
      let descriptor = open(user.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      let read = TerminalDefinitionLoader.readFile(
        named: "x.json", in: descriptor, limit: 1024,
        owner: geteuid() + 1)
      guard case .unusable(.notOwnedByUser) = read else {
        Issue.record("expected notOwnedByUser, got \(read)")
        return
      }
      guard
        case .contents = TerminalDefinitionLoader.readFile(
          named: "x.json", in: descriptor,
          limit: 1024, owner: nil)
      else {
        Issue.record("a built-in read has no owner rule")
        return
      }
    }
  } // End of func refusesAnotherOwnersFile()

  /// A definition file may be 64 KiB, no more; a script 256 KiB, no more.
  @Test func enforcesSizeLimits() throws {
    try withUserFolder { _, user in
      /// `object` as JSON padded with spaces to exactly `size` bytes.
      func padded(_ object: [String: Any], to size: Int) throws -> Data {
        var data = try Support.data(object)
        data.append(Data(repeating: 0x20, count: size - data.count))
        return data
      }
      let limit = TerminalDefinitionLoader.maximumDefinitionFileSize
      try Support.write(
        try padded(Support.execObject(id: "at-limit"), to: limit),
        named: "at-limit.json", in: user)
      try Support.write(
        try padded(Support.execObject(id: "over-limit"), to: limit + 1),
        named: "over-limit.json", in: user)
      let scriptLimit = TerminalDefinitionLoader.maximumScriptFileSize
      for (id, size) in [("script-at", scriptLimit), ("script-over", scriptLimit + 1)] {
        var object = Support.appleScriptObject(id: id)
        object["open"] = ["kind": "appleScript", "script": "\(id).applescript", "command": "words"]
        try Support.write(try Support.data(object), named: "\(id).json", in: user)
        var script = Data(Support.sampleScript.utf8)
        script.append(Data(repeating: 0x0A, count: size - script.count))
        try Support.write(script, named: "\(id).applescript", in: user)
      }
      let catalog = Support.load(user: user)
      #expect(Support.sources(catalog) == ["at-limit:user", "script-at:user"])
      #expect(
        catalog.problems.map(\.problem) == [
          .unsafeFile(.tooLarge), .unsafeScript(name: "script-over.applescript", .tooLarge),
        ])
    }
  } // End of func enforcesSizeLimits()

  /// At most 32 definition files are read, in name order; the rest are problems.
  @Test func readsAtMostThirtyTwoFiles() throws {
    try withUserFolder { _, user in
      for index in 1...33 {
        let id = String(format: "term-%02d", index)
        try Support.writeDefinition(Support.execObject(id: id), named: "\(id).json", in: user)
      }
      let catalog = Support.load(user: user)
      #expect(catalog.definitions.count == 32)
      #expect(catalog.definition(withID: "term-32") != nil)
      #expect(Support.problems(catalog) == ["user/term-33.json: tooManyFiles"])
      #expect(catalog.problems.first?.message.contains("at most 32") == true)
    }
  } // End of func readsAtMostThirtyTwoFiles()

  /// A script must be there, a regular file under the same rules, and UTF-8 text.
  @Test func refusesUnusableScripts() throws {
    try withUserFolder { base, user in
      /// Writes an `appleScript` definition `id` whose script is `<id>.applescript`.
      func definition(_ id: String) throws {
        var object = Support.appleScriptObject(id: id)
        object["open"] = [
          "kind": "appleScript", "script": "\(id).applescript", "command": "shellText",
        ]
        try Support.write(try Support.data(object), named: "\(id).json", in: user)
      }
      try definition("missing")
      try definition("linked")
      try Support.write(Data(Support.sampleScript.utf8), named: "elsewhere.applescript", in: base)
      try FileManager.default.createSymbolicLink(
        atPath: user.appending(path: "linked.applescript").path(percentEncoded: false),
        withDestinationPath: base.appending(path: "elsewhere.applescript").path(
          percentEncoded: false))
      try definition("writable")
      try Support.write(
        Data(Support.sampleScript.utf8), named: "writable.applescript", in: user,
        mode: 0o666)
      try definition("binary")
      // Not UTF-8 (a lead byte without its continuation), with no NUL byte.
      try Support.write(
        Data([0x6F, 0x6E, 0x20, 0xC3, 0x28]), named: "binary.applescript", in: user)
      try definition("nul")
      try Support.write(Data("on x()\0\nend x".utf8), named: "nul.applescript", in: user)
      let catalog = Support.load(user: user)
      #expect(catalog.definitions.isEmpty)
      #expect(
        catalog.problems.map(\.problem) == [
          .scriptNotText(name: "binary.applescript"),
          .unsafeScript(name: "linked.applescript", .symbolicLink),
          .unsafeScript(name: "missing.applescript", .missing),
          .scriptNotText(name: "nul.applescript"),
          .unsafeScript(name: "writable.applescript", .writableByOthers),
        ])
    }
  } // End of func refusesUnusableScripts()

  /// Content problems are kept per file and never stop the other files.
  @Test func keepsContentProblemsPerFile() throws {
    try withUserFolder { _, user in
      try Support.writeDefinition(Support.execObject(id: "fine"), named: "fine.json", in: user)
      try Support.write(Data("{ broken".utf8), named: "broken.json", in: user)
      try Support.write(
        try Support.data(
          Support.setting(
            "extra", to: 1,
            in: Support.execObject(id: "extra"))), named: "extra.json", in: user)
      try Support.write(
        try Support.data(Support.execObject(id: "iterm2")), named: "iterm2.json",
        in: user)
      let catalog = Support.load(user: user)
      #expect(Support.sources(catalog) == ["fine:user"])
      #expect(
        Support.problems(catalog) == [
          "user/broken.json: notJSON", "user/extra.json: unknownKey",
          "user/iterm2.json: reservedID",
        ])
    }
  } // End of func keepsContentProblemsPerFile()

  /// A user file with a member name twice (written as raw JSON text) is a problem of that file
  /// only: a valid definition in the same folder still loads.
  @Test func keepsDuplicateKeyFilesPerFile() throws {
    try withUserFolder { _, user in
      try Support.writeDefinition(Support.execObject(id: "fine"), named: "fine.json", in: user)
      let exec = (open: Support.execOpenText, focus: #""kind": "app""#)
      try Support.write(
        Data(
          Support.definitionText(
            before: #""schemaVersion": 9, "#, open: exec.open, focus: exec.focus
          ).utf8), named: "twice.json", in: user)
      try Support.write(
        Data(
          Support.definitionText(
            open: exec.open + #", "executable": "Contents/MacOS/other""#, focus: exec.focus
          ).utf8), named: "twice-open.json", in: user)
      let catalog = Support.load(user: user)
      #expect(Support.sources(catalog) == ["fine:user"])
      #expect(
        Support.problems(catalog) == [
          "user/twice-open.json: duplicateKey", "user/twice.json: duplicateKey",
        ])
      #expect(
        catalog.problems.map(\.problem.message) == [
          "This file has the key open.executable more than once.",
          "This file has the key schemaVersion more than once.",
        ])
    }
  } // End of func keepsDuplicateKeyFilesPerFile()

  /// A user definition overrides the built-in with its id; others are added; built-ins without
  /// an override stay.
  @Test func userDefinitionsOverrideBuiltIns() throws {
    try withUserFolder { _, user in
      var mine = Support.appleScriptObject(id: "terminal")
      mine["displayName"] = "My Terminal"
      try Support.writeDefinition(mine, named: "my-terminal.json", in: user)
      try Support.writeDefinition(
        Support.execObject(id: "wezterm"), named: "wezterm.json", in: user)
      let catalog = Support.load(builtIn: Support.builtInDirectory, user: user)
      #expect(catalog.problems.isEmpty)
      #expect(
        Support.sources(catalog)
          == ["ghostty:builtIn", "terminal:userOverride", "wezterm:user"])
      #expect(catalog.definition(withID: "terminal")?.definition.displayName == "My Terminal")
      #expect(catalog.definition(withID: "terminal")?.fileName == "my-terminal.json")
      #expect(catalog.definition(withID: "terminal")?.script?.name == "sample.applescript")
    }
  } // End of func userDefinitionsOverrideBuiltIns()

  /// Two user files with one id are both refused, and the built-in with that id stays; the
  /// same rule holds within the built-in folder.
  @Test func refusesDuplicateIDs() throws {
    try withUserFolder { base, user in
      try Support.writeDefinition(
        Support.appleScriptObject(id: "terminal"), named: "a.json", in: user)
      try Support.writeDefinition(Support.execObject(id: "terminal"), named: "b.json", in: user)
      let catalog = Support.load(builtIn: Support.builtInDirectory, user: user)
      #expect(Support.sources(catalog) == ["ghostty:builtIn", "terminal:builtIn"])
      #expect(
        Support.problems(catalog) == ["user/a.json: duplicateID", "user/b.json: duplicateID"])
      #expect(catalog.problems.first?.message.contains("terminal") == true)
      let builtIn = base.appending(path: "builtin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: false)
      try Support.writeDefinition(
        Support.execObject(id: "same"), named: "one.json", in: builtIn,
        mode: 0o644)
      try Support.writeDefinition(
        Support.execObject(id: "same"), named: "two.json", in: builtIn,
        mode: 0o644)
      try Support.writeDefinition(
        Support.execObject(id: "kept"), named: "kept.json", in: builtIn,
        mode: 0o644)
      let builtIns = Support.load(builtIn: builtIn, user: user)
      #expect(Support.sources(builtIns) == ["kept:builtIn"])
      #expect(
        Support.problems(builtIns) == [
          "builtIn/one.json: duplicateID", "builtIn/two.json: duplicateID",
          "user/a.json: duplicateID", "user/b.json: duplicateID",
        ])
    }
  } // End of func refusesDuplicateIDs()

  /// The built-in folder is not held to the user rules (an installed app may be root's, files
  /// 0644), but it is never a link and its files are never followed; a missing built-in folder
  /// is a problem.
  @Test func builtInFolderRules() throws {
    try withUserFolder { base, _ in
      let builtIn = base.appending(path: "builtin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: builtIn, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755])
      try Support.writeDefinition(
        Support.execObject(id: "open-mode"), named: "x.json", in: builtIn,
        mode: 0o664)
      try FileManager.default.createSymbolicLink(
        atPath: builtIn.appending(path: "link.json").path(percentEncoded: false),
        withDestinationPath: builtIn.appending(path: "x.json").path(percentEncoded: false))
      let catalog = Support.load(builtIn: builtIn)
      #expect(Support.sources(catalog) == ["open-mode:builtIn"])
      #expect(Support.problems(catalog) == ["builtIn/link.json: unsafeFile.symbolicLink"])
      let linked = base.appending(path: "builtin-link")
      try FileManager.default.createSymbolicLink(
        atPath: linked.path(percentEncoded: false),
        withDestinationPath: builtIn.path(percentEncoded: false))
      #expect(
        Support.problems(Support.load(builtIn: linked))
          == ["builtIn/builtin-link: unsafeFolder.symbolicLink"])
      #expect(
        Support.problems(Support.load(builtIn: base.appending(path: "none")))
          == ["builtIn/none: unsafeFolder.missing"])
      #expect(Support.load().definitions.isEmpty && Support.load().problems.isEmpty)
    }
  } // End of func builtInFolderRules()

  /// The user folder's standard place is `<muxFinder folder>/terminals`, and it is never
  /// created; the bundled folder is `Resources/Terminals` of a bundle.
  @Test func standardPlaces() {
    let paths = AppPaths(
      applicationSupportDirectory: URL(fileURLWithPath: "/tmp/mfx-example/muxFinder"))
    #expect(
      paths.terminalDefinitionsDirectory.path(percentEncoded: false)
        == "/tmp/mfx-example/muxFinder/terminals/")
    #expect(!FileManager.default.fileExists(atPath: "/tmp/mfx-example"))
    #expect(TerminalDefinitionLoader.bundledDirectory(of: .main)?.lastPathComponent == "Terminals")
  }
} // End of struct TerminalDefinitionLoaderTests
