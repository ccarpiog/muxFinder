import Foundation
import Security

/// An Apple Developer Team ID as the update's code requirement uses it (PLAN.md D39,
/// I-13b1): exactly 10 uppercase ASCII letters or digits. It is the one runtime value in the
/// requirement string, so nothing else can be built into it. Its text is never logged or
/// printed by the probe.
public struct UpdateTeamID: Sendable, Hashable {
  /// The ten characters.
  public let value: String

  /// The Team ID in `text`, or `nil` unless it is exactly 10 characters from `A`–`Z` and
  /// `0`–`9`.
  public init?(_ text: String) {
    let bytes = Array(text.utf8)
    guard bytes.count == 10,
      bytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) })
    else { return nil }
    value = text
  }
}

/// The requirement the downloaded bundle must satisfy (PLAN.md D39, I-13b1), in the code
/// requirement language, as clauses so that a failure can be told apart: identifier
/// `cc.carpio.muxfinder`; Apple's anchor with the Developer ID intermediate and Developer ID
/// Application leaf markers; the leaf's organizational unit equal to the Team ID; and
/// `notarized` (proven on the stapled 0.2.0 bundle: it passes there and fails for an ad hoc
/// copy). The full requirement is all four joined with `and`.
public enum UpdateCodeRequirement {
  /// `identifier "cc.carpio.muxfinder"`.
  public static let identifierClause = "identifier \"\(UpdateSource.bundleIdentifier)\""
  /// Apple's anchor, the Developer ID CA marker on the intermediate and the Developer ID
  /// Application marker on the leaf.
  public static let developerIDClause =
    "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
    + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  /// The notarization clause.
  public static let notarizedClause = "notarized"

  /// `certificate leaf[subject.OU] = "<team>"`.
  public static func teamClause(_ team: UpdateTeamID) -> String {
    "certificate leaf[subject.OU] = \"\(team.value)\""
  }

  /// Every clause: identifier, Developer ID, team and notarization.
  public static func full(_ team: UpdateTeamID) -> String {
    [identifierClause, developerIDClause, teamClause(team), notarizedClause].joined(
      separator: " and ")
  }
}

/// Why the bundle's signature or requirement check failed (PLAN.md D39, I-13b1).
public enum UpdateSignatureProblem: Error, Sendable, Hashable {
  /// The bundle could not be opened as code (this `OSStatus`).
  case unreadable(Int32)
  /// The bundle is not signed.
  case unsigned
  /// The signature or its seal is not valid (this `OSStatus`).
  case invalid(Int32)
  /// The signature's identifier is not `cc.carpio.muxfinder`.
  case notOurs
  /// The signature is not from a Developer ID Application certificate under Apple's anchor.
  case notDeveloperID
  /// The signing certificate belongs to another team.
  case otherTeam
  /// A requirement could not be compiled (this `OSStatus`; not expected).
  case requirementUnusable(Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .unreadable(let status): return "unreadable.\(status)"
    case .unsigned: return "unsigned"
    case .invalid(let status): return "invalid.\(status)"
    case .notOurs: return "notOurs"
    case .notDeveloperID: return "notDeveloperID"
    case .otherTeam: return "otherTeam"
    case .requirementUnusable(let status): return "requirementUnusable.\(status)"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .unreadable: return "the app in the download can't be checked"
    case .unsigned: return "the app in the download isn't signed"
    case .invalid: return "the app's signature isn't valid"
    case .notOurs: return "the app in the download isn't muxFinder"
    case .notDeveloperID: return "the app isn't signed with a Developer ID certificate"
    case .otherTeam: return "the app is signed by another developer"
    case .requirementUnusable: return "the app's signature couldn't be checked"
    }
  } // End of var reason
}

/// Why the notarization check failed.
public enum UpdateNotarizationProblem: Error, Sendable, Hashable {
  /// The bundle does not satisfy `notarized` (this `OSStatus`).
  case notNotarized(Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .notNotarized: return "notNotarized"
    }
  }

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String { "the app isn't notarized by Apple" }
}

/// What the code check came to.
public enum UpdateCodeCheckResult: Sendable, Hashable {
  /// The signature, the requirement and the notarization passed.
  case passed
  /// The signature or the requirement failed (notarization not checked).
  case signatureFailed(UpdateSignatureProblem)
  /// The signature and the requirement passed; notarization failed.
  case notarizationFailed(UpdateNotarizationProblem)
}

/// Checks a bundle's code signature (PLAN.md D39, I-13b1): `SecurityUpdateCodeChecker` in the
/// app and the probe, fakes in tests that need a passing check on an unsigned stub.
public protocol UpdateCodeChecking: Sendable {
  /// Checks the bundle at `path` (absolute) against the requirement for `team`.
  func check(bundleAt path: String, team: UpdateTeamID) async -> UpdateCodeCheckResult
}

/// The code check over Security.framework (PLAN.md D39, I-13b1).
/// `SecStaticCodeCreateWithPath`, then `SecStaticCodeCheckValidityWithErrors` with strict
/// validation, all architectures, nested code, and the symbolic link and app-like
/// restrictions (they pass the 0.2.0 bundle); never the revocation-check flag, and never the
/// flag that lets trust evaluation use the network. In order: the signature alone
/// (`unsigned`, `invalid`), then the identifier (`notOurs`), the Developer ID markers
/// (`notDeveloperID`) and the team (`otherTeam`) as separate requirements so the reasons can
/// be told apart, and last the full requirement with `notarized` (`notNotarized`). The same
/// static code object is used throughout, so the bundle's contents are hashed once.
public struct SecurityUpdateCodeChecker: UpdateCodeChecking {
  /// The validity flags.
  public static let validityFlags = SecCSFlags(
    rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
      | UInt32(kSecCSStrictValidate) | UInt32(kSecCSRestrictSymlinks)
      | UInt32(kSecCSRestrictToAppLike))

  /// A checker.
  public init() {}

  /// Checks the bundle at `path` (see the type).
  public func check(bundleAt path: String, team: UpdateTeamID) async -> UpdateCodeCheckResult {
    Self.checkNow(bundleAt: path, team: team)
  }

  /// The check itself, synchronously.
  static func checkNow(bundleAt path: String, team: UpdateTeamID) -> UpdateCodeCheckResult {
    var created: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: path, isDirectory: true) as CFURL, [], &created)
    guard createStatus == errSecSuccess, let code = created else {
      return .signatureFailed(.unreadable(createStatus))
    }
    let signature = validity(of: code, requirement: nil)
    guard signature == errSecSuccess else {
      return .signatureFailed(
        signature == errSecCSUnsigned ? .unsigned : .invalid(signature))
    }
    let clauses: [(String, UpdateSignatureProblem)] = [
      (UpdateCodeRequirement.identifierClause, .notOurs),
      (UpdateCodeRequirement.developerIDClause, .notDeveloperID),
      (UpdateCodeRequirement.teamClause(team), .otherTeam),
    ]
    for (text, problem) in clauses {
      switch satisfies(code, text) {
      case .success(true): continue
      case .success(false): return .signatureFailed(problem)
      case .failure(let failure): return .signatureFailed(failure)
      }
    } // End of loop over the requirement's clauses
    switch satisfies(code, UpdateCodeRequirement.full(team)) {
    case .success(true): return .passed
    case .success(false): return .notarizationFailed(.notNotarized(errSecCSReqFailed))
    case .failure(let failure): return .signatureFailed(failure)
    }
  } // End of static func checkNow(bundleAt:team:)

  /// Whether `code` satisfies the requirement `text`: `true`, `false` (the requirement
  /// failed), or the problem when the requirement cannot be compiled or the check failed for
  /// another reason.
  static func satisfies(_ code: SecStaticCode, _ text: String) -> Result<
    Bool, UpdateSignatureProblem
  > {
    var requirement: SecRequirement?
    let compiled = SecRequirementCreateWithString(text as CFString, [], &requirement)
    guard compiled == errSecSuccess, let requirement else {
      return .failure(.requirementUnusable(compiled))
    }
    let status = validity(of: code, requirement: requirement)
    if status == errSecSuccess { return .success(true) }
    if status == errSecCSReqFailed { return .success(false) }
    return .failure(status == errSecCSUnsigned ? .unsigned : .invalid(status))
  } // End of static func satisfies(_:_:)

  /// `SecStaticCodeCheckValidityWithErrors` with `validityFlags`.
  static func validity(of code: SecStaticCode, requirement: SecRequirement?) -> OSStatus {
    var error: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(code, validityFlags, requirement, &error)
    error?.release()
    return status
  }

  /// Whether the bundle at `path` satisfies the requirement `text` alone (tests and the
  /// notarization proof).
  static func bundle(atPath path: String, satisfies text: String) -> Result<
    Bool, UpdateSignatureProblem
  > {
    var created: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: path, isDirectory: true) as CFURL, [], &created)
    guard status == errSecSuccess, let code = created else {
      return .failure(.unreadable(status))
    }
    return satisfies(code, text)
  } // End of static func bundle(atPath:satisfies:)
}
