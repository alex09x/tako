// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import Tako

struct PTYBashStartupTests {
  static let modernBash: String? = {
    let candidates = [
      ProcessInfo.processInfo.environment["TAKO_TEST_BASH"],
      "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash", "/usr/bin/bash",
    ]
    return candidates.compactMap { $0 }.first { TakoBashBootstrapSupport.supports($0) }
  }()

  @Test(
    .enabled(if: modernBash != nil, "Requires an existing Bash 4+; no packages are installed"),
    arguments: [".bash_profile", ".bash_login", ".profile"], [0, 1, 2, 3])
  func automaticBootstrapPreservesLoginStartup(profile: String, state: Int) throws {
    let shell = try #require(Self.modernBash)
    let oldENV: String? = state == 0 ? nil : (state == 1 ? "" : "literal $HOME previous ENV")
    let result = try runStartup(
      shell: shell, profile: profile, oldENV: oldENV,
      posix: state == 3, manual: false)
    check(result, profile: profile, oldENV: oldENV, posix: state == 3)
  }

  @Test func stockBashKeepsManualSourcingAndDoesNotForcePOSIX() throws {
    guard !TakoBashBootstrapSupport.supports("/bin/bash") else { return }
    let result = try runStartup(
      shell: "/bin/bash", profile: ".bash_profile",
      oldENV: "manual ENV", posix: false, manual: true)
    check(result, profile: ".bash_profile", oldENV: "manual ENV", posix: false)
  }

  private struct Result {
    let output: String
    let bin: String
  }

  private func check(_ result: Result, profile: String, oldENV: String?, posix: Bool) {
    #expect(result.output.contains("TRACE:\(profile);rc;"))
    #expect(
      result.output.contains("PROFILE_ENV:\(oldENV == nil ? "unset" : "set"):\(oldENV ?? "")"))
    #expect(result.output.contains("FINAL_ENV:\(oldENV == nil ? "unset" : "set"):\(oldENV ?? "")"))
    #expect(result.output.contains("PROFILE_POSIX:\(posix ? "on" : "off")"))
    #expect(result.output.contains("FINAL_POSIX:\(posix ? "on" : "off")"))
    #expect(result.output.contains("INJECT:unset"))
    #expect(result.output.contains("FINAL_PATH:/profile-first:/usr/bin:/bin:\(result.bin)"))
    #expect(result.output.contains("USER_PROMPT"))
    #expect(result.output.contains("\u{1b}]7;kitty-shell-cwd://"))
    #expect(result.output.contains("\u{1b}]133;A"))
    #expect(!result.output.contains("TRACE:\(profile);rc;rc;"))
  }

  private func runStartup(
    shell: String, profile: String, oldENV: String?, posix: Bool, manual: Bool
  ) throws -> Result {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "tako-bash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // ENV expansion must not interpret these characters in a resource path.
    let resources = root.appendingPathComponent("resources $literal `quoted` \\")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: PTYShellLaunchTests.resources).appendingPathComponent(
        "shell-integration"),
      to: resources.appendingPathComponent("shell-integration"))
    let bin = root.appendingPathComponent("app bin").path
    let profileBody = """
      TAKO_PROFILE_TRACE='\(profile);'
      printf 'PROFILE_ENV:%s:%s\\n' "${ENV+set}" "$ENV"
      if [ "${ENV+set}" != set ]; then printf 'PROFILE_ENV:unset:\\n'; fi
      if shopt -oq posix; then printf 'PROFILE_POSIX:on\\n'; else printf 'PROFILE_POSIX:off\\n'; fi
      PATH=/profile-first:/usr/bin:/bin
      source "$HOME/.bashrc"
      \(manual ? "source \"$TAKO_RESOURCES_DIR/shell-integration/bash/tako.bash\"" : "")
      """
    // Earlier files are absent; a readable later file must not also run.
    let profiles = [".bash_profile", ".bash_login", ".profile"]
    let selected = try #require(profiles.firstIndex(of: profile))
    for name in profiles.dropFirst(selected) {
      try (name == profile ? profileBody : "TAKO_PROFILE_TRACE+=WRONG;")
        .write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try """
    TAKO_PROFILE_TRACE="${TAKO_PROFILE_TRACE}rc;"
    PROMPT_COMMAND="printf 'USER_PROMPT\\n'"

    """
    .write(to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
    var environment = [
      "HOME": home.path, "PATH": "/usr/bin:/bin", "HISTFILE": "/dev/null", "PS1": "test> ",
    ]
    environment["ENV"] = oldENV
    if posix { environment["POSIXLY_CORRECT"] = "1" }
    let launch = PTY.shellLaunchPlan(
      loginShell: shell, resourcesDir: resources.path, mode: .bash,
      shellFeatures: "path,prompt", environment: environment)
    #expect(launch.arguments == (manual ? [shell, "-l"] : [shell, "--posix", "-l"]))
    for (key, value) in launch.environment { environment[key] = value }
    environment["TAKO_BIN_DIR"] = bin
    let pty = try #require(
      PTY(
        cols: 200, rows: 24, workingDirectory: home.path, program: launch.arguments + ["-i"],
        environment: environment,
        removing: ["ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "POSIXLY_CORRECT"]))
    defer { pty.terminate() }
    let lock = NSLock()
    var data = Data()
    pty.readLoop(
      targetQueue: .global(),
      onData: { chunk in
        lock.lock()
        data.append(chunk)
        lock.unlock()
      }, onExit: {})
    func output() -> String {
      lock.lock()
      defer { lock.unlock() }
      return String(decoding: data, as: UTF8.self)
    }
    #expect(waitUntil(timeout: 5) { output().contains("USER_PROMPT") })
    pty.write(
      Data(
        """
        printf 'TRACE:%s\\n' "$TAKO_PROFILE_TRACE"; printf 'FINAL_ENV:%s:%s\\n' "${ENV+set}" "$ENV"; if [ "${ENV+set}" != set ]; then printf 'FINAL_ENV:unset:\\n'; fi
        if shopt -oq posix; then tako_posix=on; else tako_posix=off; fi; printf 'FINAL_POSIX:%s\\n' "$tako_posix"
        printf 'INJECT:%s\\n' "${TAKO_BASH_INJECT-unset}"; printf 'FINAL_PATH:%s\\n' "$PATH"; printf 'END_%s\\n' BASH_STARTUP

        """.utf8))
    #expect(waitUntil(timeout: 5) { output().contains("END_BASH_STARTUP") })
    return Result(output: output(), bin: bin)
  }
}
