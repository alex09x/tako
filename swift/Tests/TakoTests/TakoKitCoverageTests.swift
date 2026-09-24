import Foundation
import Testing
@testable import TakoKit

// TakoKit is the C-shaped surface upstream's app layer imports directly.
// Tako+Config.swift/TemporaryConfig already exercise the config-parsing path
// end to end; these tests round out the remaining entry points -- the
// no-op app/surface hooks that only need to be called to be proven total,
// and the config storage/parsing helpers' edge cases (quoting, diagnostics,
// unknown keys, cached C strings) that the higher-level shim never reaches
// directly.

@Suite
struct TakoKitFreeFunctionCoverageTests {
    @Test func initReturnsSuccess() {
        #expect(tako_init(0, nil) == TAKO_SUCCESS)
    }

    /// `tako_cli_try_action`, the color-scheme/occlusion hooks and the
    /// window-background-blur hook are permanently empty bodies on this
    /// Rust-core architecture (see the file header) -- there is no state
    /// they could plausibly reach, nil handles or not. The only provable
    /// claim is "no observable side effect", so a real config's storage
    /// stands in as a witness that nothing changed underneath these calls.
    @Test func appLevelNoOpHooksLeaveOtherStateUntouched() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        configStorage(config)?.values["title"] = "untouched"

        tako_cli_try_action()
        tako_app_set_color_scheme(nil, .TAKO_COLOR_SCHEME_DARK)
        tako_surface_set_color_scheme(nil, .TAKO_COLOR_SCHEME_LIGHT)
        tako_surface_set_occlusion(nil, true)
        tako_surface_set_occlusion(nil, false)
        tako_set_window_background_blur(nil, nil)

        #expect(configStorage(config)?.values["title"] == "untouched")
    }

    @Test func bindingLookupsAlwaysReportNoBinding() {
        #expect(tako_config_key_is_binding(nil, tako_input_key_s()) == false)
        #expect(tako_app_has_global_keybinds(nil) == false)
        #expect(tako_app_key(nil, tako_input_key_s()) == false)
        #expect(tako_surface_binding_action(nil, nil, 0) == false)
    }

    @Test func appLifecycleHooksAreNoOps() {
        tako_app_free(nil)
        #expect(tako_app_needs_confirm_quit(nil) == false)
        tako_app_tick(nil)
        tako_app_update_config(nil, nil)
    }

    @Test func surfaceLifecycleHooksAreNoOps() {
        tako_surface_update_config(nil, nil)
        tako_surface_request_close(nil)
        tako_surface_free(nil)
        tako_surface_text(nil, nil, 0)
        tako_surface_key(nil, tako_input_key_s())
        tako_surface_complete_clipboard_request(nil, nil, nil, true)
        #expect(tako_surface_needs_confirm_quit(nil) == false)
        #expect(tako_surface_process_exited(nil) == false)
    }
}

@Suite
struct TakoKitOpaqueHandleCoverageTests {
    @Test func handlesWrapAnOptionalRawPointer() {
        var scratch: Int32 = 0
        withUnsafeMutablePointer(to: &scratch) { pointer in
            let app = tako_app_t(raw: UnsafeMutableRawPointer(pointer))
            #expect(app.raw != nil)
            let alias: tako_app = app
            #expect(alias == app)

            let surface = tako_surface_t(raw: UnsafeMutableRawPointer(pointer))
            #expect(surface.raw != nil)
        }
        #expect(tako_app_t().raw == nil)
        #expect(tako_surface_t().raw == nil)
    }

    @Test func keyEventStructDefaultsMatchARestKey() {
        let key = tako_input_key_s()
        #expect(key.action == .TAKO_ACTION_PRESS)
        #expect(key.keycode == 0)
        #expect(key.mods == 0)
        #expect(key.text == nil)
        #expect(key.composing == false)
    }

    @Test func colorStructDefaultsToBlack() {
        let color = tako_config_color_s()
        #expect(color.r == 0)
        #expect(color.g == 0)
        #expect(color.b == 0)
    }

    @Test func quickTerminalSizeStructDefaults() {
        let size = tako_quick_terminal_size_s()
        #expect(size.tag == .TAKO_QUICK_TERMINAL_SIZE_NONE)
        #expect(size.value.percentage == 0)
        #expect(size.value.pixels == 0)

        let both = tako_config_quick_terminal_size_s()
        #expect(both.primary.tag == .TAKO_QUICK_TERMINAL_SIZE_NONE)
        #expect(both.secondary.tag == .TAKO_QUICK_TERMINAL_SIZE_NONE)
    }

    @Test func startSearchStructHoldsAnOptionalNeedle() {
        #expect(tako_action_start_search_s().needle == nil)
    }
}

@Suite
struct TakoConfigStorageCoverageTests {
    @Test func configStorageOfANilHandleIsNil() {
        #expect(configStorage(nil) == nil)
        #expect(configStorage(tako_config_t(raw: nil)) == nil)
    }

    @Test func newConfigIsBackedByRealStorageAndFreeReleasesIt() {
        let config = tako_config_new()
        #expect(config != nil)
        #expect(configStorage(config) != nil)
        tako_config_free(config)
    }

    @Test func cloneOfANilHandleIsNil() {
        #expect(tako_config_clone(nil) == nil)
    }

    @Test func cloneCopiesValuesKeybindsAndErrors() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        parseTakoConfigText("title = original\nkeybind=cmd+t=new_tab\nnot-a-key = x", into: configStorage(config)!)

        let clone = tako_config_clone(config)
        defer { tako_config_free(clone) }
        let cloneStorage = configStorage(clone)
        #expect(cloneStorage?.values["title"] == "original")
        #expect(cloneStorage?.keybindLines == ["cmd+t=new_tab"])
        #expect(cloneStorage?.errors.isEmpty == false)

        // The clone is a snapshot, not a shared reference.
        configStorage(config)?.values["title"] = "changed"
        #expect(cloneStorage?.values["title"] == "original")
    }

    @Test func loadFileWithAMissingPathIsANoOp() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        "/no/such/file/exists.tako".withCString { path in
            tako_config_load_file(config, path)
        }
        #expect(configStorage(config)?.values.isEmpty == true)
    }

    @Test func loadFileWithANilConfigOrNilPathIsANoOp() {
        tako_config_load_file(nil, nil) // Must not crash with no config at all.

        let config = tako_config_new()
        defer { tako_config_free(config) }
        tako_config_load_file(config, nil)
        #expect(configStorage(config)?.values.isEmpty == true)
        #expect(configStorage(config)?.loadedPath == nil)
    }

    @Test func loadFileParsesRealContent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tako")
        try "title = From Disk".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let config = tako_config_new()
        defer { tako_config_free(config) }
        file.path.withCString { path in
            tako_config_load_file(config, path)
        }
        #expect(configStorage(config)?.values["title"] == "From Disk")
    }

    @Test func loadDefaultFilesSkipsMissingCandidatesWithoutCrashing() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        tako_config_load_default_files(config)
        tako_config_load_default_files(nil) // Must not crash with no config at all.

        // Whether any of upstream's candidate paths exist depends on the
        // machine running the test, so this can't assert emptiness -- it
        // asserts the invariant that holds either way: a loaded path is
        // always one of the candidates, and its presence tracks
        // exactly whether anything actually landed in `values`.
        let storage = configStorage(config)
        let candidates = [
            "~/.config/tako-core/config", "~/.config/tako/config",
        ].map { ($0 as NSString).expandingTildeInPath }
        if let loadedPath = storage?.loadedPath {
            #expect(candidates.contains(loadedPath))
            #expect(storage?.values.isEmpty == false)
        } else {
            #expect(storage?.values.isEmpty == true)
        }
    }

    @Test func cliArgsAndRecursiveFileHooksAreNoOps() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        configStorage(config)?.values["title"] = "untouched"

        tako_config_load_cli_args(nil)
        tako_config_load_recursive_files(nil)
        tako_config_load_cli_args(config)
        tako_config_load_recursive_files(config)

        #expect(configStorage(config)?.values["title"] == "untouched")
    }

    @Test func finalizePopulatesTheAutoUpdateChannelDefault() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        tako_config_finalize(config)
        #expect(configStorage(config)?.values["auto-update-channel"] == "tip")
    }

    @Test func finalizeDoesNotOverrideAnExplicitChannel() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        configStorage(config)?.values["auto-update-channel"] = "stable"
        tako_config_finalize(config)
        #expect(configStorage(config)?.values["auto-update-channel"] == "stable")
    }

    @Test func diagnosticsCountAndLookup() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        #expect(tako_config_diagnostics_count(config) == 0)
        parseTakoConfigText("bogus-key = 1", into: configStorage(config)!)
        #expect(tako_config_diagnostics_count(config) == 1)

        let diagnostic = tako_config_get_diagnostic(config, 0)
        #expect(String(cString: diagnostic.message).contains("bogus-key"))
    }

    @Test func diagnosticLookupOutOfRangeOrNilConfigReturnsAnEmptyMessage() {
        #expect(String(cString: tako_config_get_diagnostic(nil, 0).message).isEmpty)
        let config = tako_config_new()
        defer { tako_config_free(config) }
        #expect(String(cString: tako_config_get_diagnostic(config, 5).message).isEmpty)
    }

    @Test func getReturnsTheStoredValueAndCachesItsCString() {
        let config = tako_config_new()
        defer { tako_config_free(config) }
        configStorage(config)?.values["title"] = "Hello"

        var first: UnsafePointer<CChar>?
        let firstOK = "title".withCString { key in
            tako_config_get(config, &first, key, UInt("title".utf8.count))
        }
        #expect(firstOK)
        #expect(first.map(String.init(cString:)) == "Hello")

        var second: UnsafePointer<CChar>?
        _ = "title".withCString { key in
            tako_config_get(config, &second, key, UInt("title".utf8.count))
        }
        // Same key, same cached backing pointer.
        #expect(first == second)
    }

    @Test func getFailsForAMissingKeyOrANilConfigOrANilKey() {
        var value: UnsafePointer<CChar>?
        #expect(tako_config_get(nil, &value, "title", 5) == false)

        let config = tako_config_new()
        defer { tako_config_free(config) }
        #expect(tako_config_get(config, &value, nil, 0) == false)
        #expect("missing".withCString { key in
            tako_config_get(config, &value, key, 7)
        } == false)
    }
}

@Suite
struct UnquoteConfigValueCoverageTests {
    @Test func stripsMatchingDoubleQuotes() {
        #expect(unquoteConfigValue("\"hello world\"") == "hello world")
    }

    @Test func stripsMatchingSingleQuotes() {
        #expect(unquoteConfigValue("'hello'") == "hello")
    }

    @Test func leavesMismatchedQuotesAlone() {
        #expect(unquoteConfigValue("\"hello'") == "\"hello'")
    }

    @Test func leavesALoneQuoteCharacterAlone() {
        #expect(unquoteConfigValue("\"") == "\"")
    }

    @Test func leavesAnUnquotedValueAlone() {
        #expect(unquoteConfigValue("bare") == "bare")
    }

    @Test func leavesAnEmptyValueAlone() {
        #expect(unquoteConfigValue("") == "")
    }
}

@Suite
struct ParseTakoConfigTextCoverageTests {
    @Test func blankAndCommentLinesAreIgnored() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("\n  \n# a comment\n   # indented comment", into: storage)
        #expect(storage.values.isEmpty)
        #expect(storage.errors.isEmpty)
    }

    @Test func linesWithoutAnEqualsSignAreIgnored() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("not-a-key-value-pair", into: storage)
        #expect(storage.values.isEmpty)
        #expect(storage.errors.isEmpty)
    }

    @Test func emptyKeyIsIgnored() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("  = value-with-no-key", into: storage)
        #expect(storage.values.isEmpty)
        #expect(storage.errors.isEmpty)
    }

    @Test func keybindLinesAccumulateSeparatelyFromValues() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("keybind=cmd+t=new_tab\nkeybind=cmd+w=close_surface", into: storage)
        #expect(storage.keybindLines == ["cmd+t=new_tab", "cmd+w=close_surface"])
        #expect(storage.values["keybind"] == nil)
    }

    @Test func unknownKeysAreReportedAsErrorsAndNotStored() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("not-a-real-key = 1", into: storage)
        #expect(storage.errors == ["unknown configuration key: not-a-real-key"])
        #expect(storage.values["not-a-real-key"] == nil)
    }

    @Test func knownKeysAreStoredWithQuotesStripped() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("title = \"Quoted Title\"", into: storage)
        #expect(storage.values["title"] == "Quoted Title")
        #expect(storage.errors.isEmpty)
    }

    @Test func laterDuplicateKeysOverwriteEarlierOnes() {
        let storage = TakoConfigStorage()
        parseTakoConfigText("maximize = false\nmaximize = true", into: storage)
        #expect(storage.values["maximize"] == "true")
    }
}
