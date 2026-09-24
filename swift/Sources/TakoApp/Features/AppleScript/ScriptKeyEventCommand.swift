import AppKit

/// Handler for the `send key` AppleScript command defined in `Tako.sdef`.
///
/// Cocoa scripting instantiates this class because the command's `<cocoa>` element
/// specifies `class="TakoScriptKeyEventCommand"`. The runtime calls
/// `performDefaultImplementation()` to execute the command.
@MainActor
@objc(TakoScriptKeyEventCommand)
class ScriptKeyEventCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let keyName = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing key name."
            return nil
        }

        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }

        guard let surfaceView = terminal.surfaceView else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let surface = surfaceView.surfaceModel else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal surface model is not available."
            return nil
        }

        guard let key = Tako.Input.Key(rawValue: keyName) else {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown key name: \(keyName)"
            return nil
        }

        let action: Tako.Input.Action
        if let actionCode = evaluatedArguments?["action"] as? UInt32 {
            switch actionCode {
            case "GIpr".fourCharCode: action = .press
            case "GIrl".fourCharCode: action = .release
            default: action = .press
            }
        } else {
            action = .press
        }

        let mods: Tako.Input.Mods
        if let modsString = evaluatedArguments?["modifiers"] as? String {
            guard let parsed = Tako.Input.Mods(scriptModifiers: modsString) else {
                scriptErrorNumber = errAECoercionFail
                scriptErrorString = "Unknown modifier in: \(modsString)"
                return nil
            }
            mods = parsed
        } else {
            mods = []
        }

        let keyEvent = Tako.Input.KeyEvent(
            key: key,
            action: action,
            mods: mods
        )
        surface.sendKeyEvent(keyEvent)

        return nil
    }
}
