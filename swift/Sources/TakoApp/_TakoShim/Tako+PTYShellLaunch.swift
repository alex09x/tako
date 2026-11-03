// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

struct TakoPTYShellLaunchPlan {
  let arguments: [String]
  /// Additions to the inherited environment, computed before forkpty.
  let environment: [(String, String)]
}

extension PTY {
  /// Used both by the direct PTY and the persistent session's create-only
  /// command. Explicit programs (including attach clients) are never rewritten.
  static func shellLaunchPlan(
    config: Tako.Config? = nil,
    loginShell: String = PTY.loginShell,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    program: [String]? = nil
  ) -> TakoPTYShellLaunchPlan {
    let resources = Bundle.main.resourceURL?.appendingPathComponent("tako").path
    return shellLaunchPlan(
      loginShell: loginShell, resourcesDir: resources,
      mode: config?.shellIntegration ?? .detect,
      shellFeatures: shellFeatures(config?.shellIntegrationFeatures),
      environment: environment, program: program)
  }

  /// Resource and capability inputs are explicit so consumer tests can use
  /// the real bundled script without modifying an installed application.
  static func shellLaunchPlan(
    loginShell: String, resourcesDir: String?, mode: Tako.Config.ShellIntegration,
    shellFeatures: String, environment: [String: String], program: [String]? = nil,
    supportsBashBootstrap: (String) -> Bool = TakoBashBootstrapSupport.supports
  ) -> TakoPTYShellLaunchPlan {
    if let program { return TakoPTYShellLaunchPlan(arguments: program, environment: []) }
    var arguments = [loginShell, "-l"]
    guard mode != .none, let resourcesDir,
      FileManager.default.fileExists(atPath: resourcesDir + "/shell-integration")
    else {
      return TakoPTYShellLaunchPlan(arguments: arguments, environment: [])
    }
    let base = resourcesDir + "/shell-integration"
    var variables = shellIntegrationVariables(
      resourcesDir: resourcesDir, base: base, mode: mode, loginShell: loginShell,
      shellFeatures: shellFeatures, environment: environment)
    let isBash =
      mode == .bash || (mode == .detect && (loginShell as NSString).lastPathComponent == "bash")
    let script = base + "/bash/tako.bash"
    if isBash, FileManager.default.isReadableFile(atPath: script), supportsBashBootstrap(loginShell)
    {
      arguments = [loginShell, "--posix", "-l"]
      // Bash expands ENV as a double-quoted string, including command
      // substitutions. Keep resource paths literal even with $, ` or \.
      let literalScript = script.reduce(into: "") { result, character in
        if "\\$`\"".contains(character) { result.append("\\") }
        result.append(character)
      }
      let posix =
        environment["POSIXLY_CORRECT"] != nil
        || (environment["SHELLOPTS"] ?? "").split(separator: ":").contains("posix")
      let inheritErrexit = (environment["BASHOPTS"] ?? "").split(separator: ":").contains(
        "inherit_errexit")
      variables += [
        ("ENV", literalScript), ("TAKO_BASH_INJECT", "1"),
        ("TAKO_BASH_ENV", environment["ENV"] ?? ""),
        ("TAKO_BASH_ENV_SET", environment["ENV"] == nil ? "0" : "1"),
        ("TAKO_BASH_POSIX", posix ? "1" : "0"),
        ("TAKO_BASH_INHERIT_ERREXIT", inheritErrexit ? "1" : "0"),
      ]
    }
    return TakoPTYShellLaunchPlan(arguments: arguments, environment: variables)
  }
}

/// --version does not load user startup files. Cache successes and failures by
/// executable identity; replacing/upgrading a shell invalidates its entry.
/// A failed/old probe must never strand the user's shell in forced POSIX mode.
enum TakoBashBootstrapSupport {
  private static let lock = NSLock()
  private static var cache: [String: Bool] = [:]

  static func supports(_ shell: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let resolved = URL(fileURLWithPath: shell).resolvingSymlinksInPath().path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved) else {
      return false
    }
    let key =
      "\(shell):\(resolved):\(attributes[.systemFileNumber] ?? ""):\(attributes[.modificationDate] ?? ""):\(attributes[.size] ?? "")"
    if let supported = cache[key] { return supported }
    let supported = probe(shell)
    cache[key] = supported
    return supported
  }

  private static func probe(_ shell: String) -> Bool {
    let process = Process()
    let output = Pipe()
    let finished = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["--version"]
    // No BASH_ENV, exported functions or shell options from the app host.
    process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return false }
    if finished.wait(timeout: .now() + 1) == .timedOut {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      return false
    }
    guard process.terminationStatus == 0 else { return false }
    let version = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let prefix = "GNU bash, version "
    guard version.hasPrefix(prefix),
      let major = Int(version.dropFirst(prefix.count).prefix(while: { $0.isNumber }))
    else { return false }
    return major >= 4
  }
}
