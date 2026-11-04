// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing

@testable import Tako

struct PTYShellLaunchTests {
  static let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources").path

  private func plan(
    shell: String = "/supported/bash", mode: Tako.Config.ShellIntegration = .detect,
    environment: [String: String] = [:], supported: Bool = true, program: [String]? = nil
  ) -> TakoPTYShellLaunchPlan {
    PTY.shellLaunchPlan(
      loginShell: shell, resourcesDir: Self.resources, mode: mode,
      shellFeatures: "path,prompt", environment: environment, program: program,
      supportsBashBootstrap: { _ in supported })
  }

  @Test func supportedBashHasCoupledArgvAndEnvironmentAtBothCreateBoundaries() {
    let launch = plan(environment: ["ENV": "original env"])
    #expect(launch.arguments == ["/supported/bash", "--posix", "-l"])
    let env = Dictionary(uniqueKeysWithValues: launch.environment)
    #expect(env["ENV"] == Self.resources + "/shell-integration/bash/tako.bash")
    #expect(env["TAKO_BASH_INJECT"] == "1")
    #expect(env["TAKO_BASH_ENV"] == "original env")
    #expect(env["TAKO_BASH_ENV_SET"] == "1")
    #expect(env["TAKO_SHELL_FEATURES"] == "path,prompt")
    let create = RuntimeCommand.createOnlyWithGenerationArguments(
      name: "test", generation: "generation", command: launch.arguments)
    #expect(Array(create.suffix(launch.arguments.count)) == launch.arguments)
    #expect(create.contains("--create-only"))
  }

  @Test func emptyAndAbsentENVAndInheritedPOSIXStateAreDistinct() {
    for environment in [
      [:], ["ENV": ""], ["POSIXLY_CORRECT": ""], ["SHELLOPTS": "braceexpand:posix"],
    ] {
      let env = Dictionary(uniqueKeysWithValues: plan(environment: environment).environment)
      #expect(env["TAKO_BASH_ENV_SET"] == (environment["ENV"] == nil ? "0" : "1"))
      #expect(
        env["TAKO_BASH_POSIX"]
          == (environment["POSIXLY_CORRECT"] != nil || environment["SHELLOPTS"] != nil ? "1" : "0"))
    }
  }

  @Test func unsupportedBashRetainsOrdinaryLoginAndManualSourceVariables() {
    let launch = plan(shell: "/bin/bash", environment: ["ENV": "keep"], supported: false)
    #expect(launch.arguments == ["/bin/bash", "-l"])
    let env = Dictionary(uniqueKeysWithValues: launch.environment)
    #expect(env["ENV"] == nil)
    #expect(env["TAKO_BASH_INJECT"] == nil)
    #expect(env["TAKO_RESOURCES_DIR"] == Self.resources)
    #expect(!TakoBashBootstrapSupport.supports("/no/such/bash"))
  }

  @Test func bashCapabilityDoesNotWaitForDescendantHoldingStdout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wrapper = directory.appendingPathComponent("bash")
    let childFile = directory.appendingPathComponent("bash.child")
    defer {
      if let text = try? String(contentsOf: childFile, encoding: .utf8),
        let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), child > 0
      {
        kill(child, SIGKILL)
      }
      try? FileManager.default.removeItem(at: directory)
    }
    try """
    #!/bin/sh
    printf 'GNU bash, version 5.2.0(1)-release\\n'
    /bin/sleep 10 &
    printf '%s\\n' "$!" > "$0.child"
    exit 0
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

    let start = ContinuousClock.now
    let supported = TakoBashBootstrapSupport.supports(wrapper.path)
    let elapsed = start.duration(to: .now)
    #expect(supported)
    #expect(elapsed < .seconds(1))
    let child = try #require(
      Int32(
        try String(contentsOf: childFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(child > 0)
    #expect(kill(child, 0) == 0)
  }

  @Test func disabledMissingResourcesAndExplicitProgramsNeverProbeOrRewrite() {
    for (mode, resources, program) in [
      (Tako.Config.ShellIntegration.none, Optional(Self.resources), Optional<[String]>.none),
      (.bash, nil, nil),
      (.bash, Self.resources, ["/runtime/zmx", "attach", "session"]),
      (.detect, Self.resources, ["/bin/bash", "-c", "printf explicit"]),
    ] {
      let launch = PTY.shellLaunchPlan(
        loginShell: "/bin/bash", resourcesDir: resources, mode: mode,
        shellFeatures: "path", environment: [:], program: program,
        supportsBashBootstrap: { _ in
          Issue.record("Unexpected probe")
          return true
        })
      #expect(launch.arguments == (program ?? ["/bin/bash", "-l"]))
      #expect(launch.environment.isEmpty)
    }
  }

  @Test func forcedModesAndOtherShellsKeepTheirEnvironmentMapping() {
    let forced = plan(shell: "/renamed-shell", mode: .bash)
    #expect(forced.arguments == ["/renamed-shell", "--posix", "-l"])
    for mode: Tako.Config.ShellIntegration in [.zsh, .fish, .elvish] {
      let launch = plan(
        mode: mode, environment: ["ZDOTDIR": "/old-zsh", "XDG_DATA_DIRS": "/old-xdg"])
      #expect(launch.arguments == ["/supported/bash", "-l"])
      let env = Dictionary(uniqueKeysWithValues: launch.environment)
      if mode == .zsh {
        #expect(env["ZDOTDIR"] == Self.resources + "/shell-integration/zsh")
        #expect(env["TAKO_ZSH_ZDOTDIR"] == "/old-zsh")
      } else {
        #expect(env["XDG_DATA_DIRS"] == Self.resources + "/shell-integration:/old-xdg")
      }
      #expect(env["ENV"] == nil)
    }
  }
}
