import AppKit
import Cocoa
import TakoKit

// Initialize Tako global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if tako_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != TAKO_SUCCESS {
    Tako.logger.critical("tako_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Tako.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "Tako failed to initialize! If you're executing Tako from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `tako +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `tako +boo`.
tako_cli_try_action()

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
