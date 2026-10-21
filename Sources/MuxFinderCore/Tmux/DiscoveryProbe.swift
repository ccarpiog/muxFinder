import Foundation

/// Why a host configuration cannot be probed. `message` is English, sentence case.
public enum DiscoveryConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The SSH destination is invalid.
  case invalidDestination(ValidationError)
  /// The tmux path override is invalid.
  case invalidTmuxPath(ValidationError)
  /// The strict known-hosts file of the test harness has an unusable path.
  case invalidKnownHostsFile

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .invalidDestination(let error), .invalidTmuxPath(let error):
      return error.message
    case .invalidKnownHostsFile:
      return
        "The known-hosts file path must be absolute and use only letters, digits, “.”, “_”, “-” "
        + "and “/”."
    }
  }

  /// Same as `message`.
  public var description: String { message }
}

/// The outcome of discovering one host.
public struct DiscoveryResult: Sendable, Hashable {
  /// The host that was probed (`HostConfig.id`).
  public var hostID: UUID
  /// What was found.
  public var status: HostStatus
  /// The parsed report (node name, tmux path and version, raw listings), when there was one.
  public var report: ProbeReport?
  /// How long the probe process ran.
  public var duration: Duration

  /// Creates a result.
  public init(hostID: UUID, status: HostStatus, report: ProbeReport?, duration: Duration) {
    self.hostID = hostID
    self.status = status
    self.report = report
    self.duration = duration
  }
}

/// Runs the discovery probe for a host and classifies the outcome.
///
/// - Local hosts: `/bin/sh -c <ProbeScript.script> muxfinder [override]` through argv, with the
///   local environment minus `TMUX` and `TMUX_PANE` (they would point tmux at the server
///   muxFinder happens to run inside, not the default one; PLAN.md D9).
/// - SSH hosts: `/usr/bin/ssh <D6 options> -n -T -- <destination> <D3 command>`. The
///   destination is validated first (no leading `-`, no whitespace or control characters), and
///   the remote command comes only from `ShellQuoting.remoteCommand(script:args:)`.
///
/// Every run is bounded by `timeout` (12 s by default), after which the runner kills the whole
/// process group.
public struct DiscoveryProbe: Sendable {
  /// Host-key checking for SSH runs.
  public enum HostKeyPolicy: Sendable, Hashable {
    /// The user's own SSH configuration, unchanged. Production always uses this.
    case userConfiguration
    /// Test harness only, and only ever stricter than the user's configuration:
    /// `StrictHostKeyChecking=yes`, this file as the only user known-hosts file, no global
    /// known-hosts file, and no connection sharing (`ControlMaster=no`, `ControlPath=none`), so
    /// an existing master connection from the user's configuration is never reused without the
    /// host key being checked against this file. ssh never writes to known-hosts files under
    /// strict checking.
    case strict(knownHostsFile: String)
  }

  /// The hard limit on one probe run (PLAN.md D6).
  public static let defaultTimeout: Duration = .seconds(12)
  /// The local shell that runs the probe.
  public static let shellURL = URL(fileURLWithPath: "/bin/sh")
  /// The ssh client.
  public static let sshURL = URL(fileURLWithPath: "/usr/bin/ssh")
  /// Noninteractive SSH options (PLAN.md D6). Nothing here weakens host-key checking.
  public static let sshOptions = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=1",
  ]
  /// Environment variables removed for local runs.
  public static let strippedVariables = ["TMUX", "TMUX_PANE"]

  /// Runs the probe process.
  public var runner: any ProcessRunner
  /// The environment the child environment is built from (normally this process's).
  public var baseEnvironment: [String: String]
  /// The hard limit on one run.
  public var timeout: Duration
  /// Host-key checking for SSH runs.
  public var hostKeyPolicy: HostKeyPolicy

  /// Creates a probe. Tests pass a fake runner and an explicit environment.
  public init(
    runner: any ProcessRunner = PosixSpawnProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: Duration = DiscoveryProbe.defaultTimeout,
    hostKeyPolicy: HostKeyPolicy = .userConfiguration
  ) {
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.timeout = timeout
    self.hostKeyPolicy = hostKeyPolicy
  } // End of init(runner:baseEnvironment:timeout:hostKeyPolicy:)

  /// Discovers `host`. Never throws except `CancellationError` when the calling task is
  /// cancelled (the process group has been killed by then); every other problem is a status.
  public func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let request: ProcessRequest
    do throws(DiscoveryConfigurationError) {
      request = try self.request(for: host)
    } catch {
      return DiscoveryResult(
        hostID: host.id,
        status: .probeError(error.message),
        report: nil,
        duration: .zero
      )
    }
    let result: ProcessResult
    do {
      result = try await runner.run(request)
    } catch let error as ProcessRunnerError {
      return DiscoveryResult(
        hostID: host.id,
        status: .probeError("Could not start the discovery probe. \(error.description)"),
        report: nil,
        duration: .zero
      )
    }
    let transport: DiscoveryTransport = host.mode == .local ? .local : .ssh
    let classification = ErrorClassifier.classify(result, transport: transport, hostID: host.id)
    return DiscoveryResult(
      hostID: host.id,
      status: classification.status,
      report: classification.report,
      duration: result.duration
    )
  } // End of func discover(_:)

  /// The process request that probes `host`. Exposed so tests and the probe CLI can inspect it.
  public func request(for host: HostConfig) throws(DiscoveryConfigurationError) -> ProcessRequest {
    var probeArguments: [String] = []
    if let override = host.tmuxPathOverride {
      do throws(ValidationError) {
        probeArguments.append(try Validation.executablePath(override))
      } catch {
        throw .invalidTmuxPath(error)
      }
    }
    let environment = Self.localEnvironment(base: baseEnvironment)
    switch host.mode {
    case .local:
      return ProcessRequest(
        executableURL: Self.shellURL,
        arguments: ["-c", ProbeScript.script.source, ShellQuoting.scriptName] + probeArguments,
        environment: environment,
        timeout: timeout
      )
    case .ssh:
      let destination: String
      do throws(ValidationError) {
        destination = try Validation.sshDestination(host.sshDestination)
      } catch {
        throw .invalidDestination(error)
      }
      let command = ShellQuoting.remoteCommand(script: ProbeScript.script, args: probeArguments)
      return ProcessRequest(
        executableURL: Self.sshURL,
        arguments: Self.sshOptions + (try hostKeyArguments())
          + ["-n", "-T", "--", destination, command],
        environment: environment,
        timeout: timeout
      )
    }
  } // End of func request(for:)

  /// The ssh options for `hostKeyPolicy`.
  func hostKeyArguments() throws(DiscoveryConfigurationError) -> [String] {
    switch hostKeyPolicy {
    case .userConfiguration:
      return []
    case .strict(let file):
      // ssh splits this option on whitespace and expands `%` and `~`, so only plain paths.
      let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
      guard file.hasPrefix("/"), file.allSatisfy(allowed.contains) else {
        throw .invalidKnownHostsFile
      }
      return [
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=\(file)",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
      ]
    }
  } // End of func hostKeyArguments()

  /// The environment for probe processes: `ProcessEnvironment.local(base:)` without `TMUX` and
  /// `TMUX_PANE`.
  public static func localEnvironment(base: [String: String]) -> [String: String] {
    var environment = ProcessEnvironment.local(base: base)
    for name in strippedVariables {
      environment[name] = nil
    }
    return environment
  }
}
