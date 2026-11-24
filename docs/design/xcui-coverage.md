# Native desktop interaction acceptance

The owner requested XCUITest coverage for every feature and interactive control.
The right-hand resident implements coherent slices; primary reviews them and runs
the real UI gate on the MacBook. No additional one-shot workers are to be created.

Full acceptance of the rows below remains pending. Three concrete journeys passed
on `c307c5a0`; this does not mean their entire feature areas are complete. Existing
model tests or prototype browser checks do not satisfy native UI checks. Each test
must prove the resulting behavior, not merely that a button is clickable.

## Recorded GUI evidence

External checkout: `ci/tako-native-design-acceptance` on the designated MacBook.
The original result is `target/desktop-c307.xcresult` (overall exit 65):

- `TakoDesktopSettingsUITests/testCenteredSettingsKeepTheirPositionAcrossSectionsAndRestoreTerminalFocus`: passed, 23.102 s.
- `TakoDesktopShortcutsUITests/testRecordingConflictCanCancelReassignAndResetWithoutExecutingShortcut`: passed, 27.234 s.
- `TakoDesktopThemeUITests/testCustomThemePreviewCancelAndSaveReachTheRealTerminal`: passed, 48.142 s.
- First-run completion initially failed to restore terminal input; product fix `69cd902b` subsequently passed the same GUI regression.
- Fractional-size test initially clicked an offscreen field. The follow-up `desktop-font.xcresult` still clicked beneath the clipped page: `isHittable` alone was insufficient. Requiring the entire physical frame inside the visible page above the footer fixed the fixture, and the actual fractional input then passed.

Subsequent evidence on `b923de5d` with the corrected physical viewport guard:

- `target/desktop-half.xcresult`: `testHalfPointButtonsAndDecimalCommaCommitWithoutRounding` passed, 28.589 s, exit 0. Actual mouse/keyboard input verified 13.5, +0.5, −0.5, comma normalization to 14.5, persisted config and reopened settings.
- `target/desktop-expanded.xcresult`: 16/17 passed. The formerly failing setup-focus case passed (26.457 s), independent fractional-size/scheme/relaunch passed (27.628 s), both scope-inheritance cases and actual terminal/header menus passed.
- The remaining failure was the missing immediate validation message after 73. Primary localized the unmounted observer in the footer; resident fixed it in `56a74b4c`, and the directly affected GUI rerun passed.
- The three original green journeys, the half-point journey and the 16 expanded passes account for 20/21 distinct methods across these recorded revisions. This is not a claim that every feature, or every method on one final revision, has passed.

On `56a74b4c`, `target/desktop-final.xcresult` ran ten directly affected/new
methods: nine passed, one failed. The invalid-size message is now verified
(19.173 s); whole-level reset and inheritance passed (61.060 s); half-point input
passed again (28.239 s). Float/drag/grid/process identity, shelf/restore/maximize/
close, all sections, shortcut validation, Cmd-K and sidebar gear/keyboard entries
also passed. The only failure is the plus-menu scenario: video shows the native
menu and correct item labels, but the application's exported AX hierarchy omits
the popup items. Native menu ownership/anchoring is being investigated; the test
still requires an actual menu-item click and resulting split/session creation.
There are 25 distinct green methods out of 26 authored methods across recorded
revisions; the overall final bundle exits 65 and is not a green acceptance gate.

The plus-menu failure was then fixed by anchoring `NSMenu.popUp` to its real
`SessionSidebarHeaderNewSession` NSView instead of a screen point with `in: nil`.
The unchanged physical-click scenario passed in `target/desktop-plus.xcresult`
(15.501 s; exit 0), creating a split and a new session through the actual menu
items. All **26 distinct authored methods now have passing evidence** across the
listed revisions, with unchanged successful checks reused. The historical failed
bundles remain failed evidence; no skipped case or zero-test run is counted.
Full design acceptance and production installation are separate from this set.

## Expanded scenario inventory

There are **26 authored desktop GUI test methods**, including the original five.
Authored is not executed or passed. The expanded candidate builds and runs on the
same isolated host; production user data and provider processes are not fixtures.

| Suite | Methods | Behavior |
| --- | ---: | --- |
| TakoDesktopSettingsUITests | 2 | Center/focus; independent fractional size and app scheme persistence |
| TakoDesktopSetupUITests | 1 | Five optional stages, finish and immediate existing-terminal input |
| TakoDesktopThemeUITests | 1 | Real renderer preview, cancellation, save and relaunch |
| TakoDesktopShortcutsUITests | 1 | Conflict cancellation, reassignment and reset |
| TakoDesktopFontUITests | 3 | Half-point buttons/comma; invalid input; installed-font search/selection |
| TakoDesktopScopeUITests | 2 | Workspace/session/pane inheritance and reset; sibling isolation |
| TakoDesktopControlsUITests | 4 | All 11 pages; independent activity controls; search/Escape; optional access disclosure |
| TakoDesktopMenuUITests | 2 | Terminal-content and pane-header appearance entry points |
| TakoDesktopDraftValidationUITests | 2 | Invalid name and config; all five editor tabs |
| TakoDesktopRecordingUITests | 3 | Escape cancellation; unmodified-key rejection; Backspace default reset |
| TakoDesktopSidebarUITests | 3 | Gear/keyboard entry points; Cmd-K/search/Escape; plus-menu split/session creation |
| TakoDesktopCanvasUITests | 2 | Float/drag/grid and process identity; minimize/restore/maximize/close |

## Remaining full feature acceptance

| Area | Controls and required outcomes |
| --- | --- |
| Settings entry | Gear and Cmd+, open centered settings; keyboard icon opens Keys; X/Escape restore terminal focus and preserve process identity. |
| Settings navigation | Every section is reachable, active section is visible, search finds settings/actions/fonts and opens the actual target. Small-window scrolling keeps actions reachable. |
| Application appearance | System/light/dark selection changes application chrome, preserves terminal theme/font size and survives relaunch. |
| Theme catalog | Search/filter, preset selection and inheritance use real installed themes; selection changes the renderer immediately. |
| Custom theme | Duplicate, name, edit, save and cancel; built-ins remain unchanged, invalid names/configs leave saved data intact. |
| Theme references | Rename updates actual references; deleting an in-use preset explains the blocking scopes; unused deletion follows the recovery contract. |
| Theme editor | Colors, ANSI palette, font family/faces/weights/size, cursor/selection and raw config have real bindings and clear validation. Closing/cancelling restores preview. |
| Font selection | Actual available family and rendered fallback are truthful; selecting a family updates the rendered text, not just its label. |
| Font size and zoom | Fractional base size, stepper and reset; per-pane zoom and zoom reset remain distinct; UI text does not scale with terminal text. |
| Scope inheritance | Global/workspace/session/pane selection, live parent changes, child overrides, individual-field reset and whole-level reset. |
| Context menus | Appearance menu on workspace/session/pane and terminal content; selection, inherited reset, full catalog and editor route to the intended object. Existing terminal menu actions remain. |
| Shortcut recording | Select/search action, record modifiers and key, Escape cancellation, reset, conflict cancellation/reassignment. The recorded key must not execute the action. |
| General/input | Each exposed option persists and has its real consumer: safe paste, copy mode, cursor, close confirmation, shell integration and inherited directory/size. |
| Sidebar | Search and attention filters, workspace expansion/switching, session selection, plus menu, creation and close. Counters count unique panes and follow their visibility settings. |
| Canvas | Floating icon and reverse, maximize/restore, minimize/shelf restore, close/cancel, drag and all eight resize handles; retain Surface/PTY identity and preferred geometry. |
| Activity | Status visibility, animation and colors change real indicators; disabling presentation retains status/unread. Reduce Motion and occlusion stop animation work. |
| Quick Terminal | Position/autohide settings affect its actual window; show/hide returns focus correctly. App shortcuts are not mislabeled as system-wide hotkeys. |
| Agent setup | Detection refresh, explicit optional skill action, installed/error/absent outcomes; no hidden installation or provider restart. Use isolated fixtures. |
| Access | Passive refresh causes no prompt. Explicit actions invoke the matching native route; known/denied/unknown states stay distinct. Folder checks remain explicit. |
| Notifications | Explicit enable/manage/test; exact delivered receipt versus accepted/unconfirmed result. Never alter global suppression settings to force a banner. |
| First run | Five stages, all navigation buttons, skip/later/resume, optional steps, ready action; same existing terminal survives and regains focus. |
| Recovery | Relaunch preserves saved choices and the existing persistence contract; failure messages offer a real next action without silently creating replacements. |

External macOS authorization is recorded only when actually observed. Opening a
Settings page is not a grant. UI fixture state must be identified as a fixture,
and no test may infer rights for arbitrary child programs or remote hosts.

For each completed row, record test identifiers, candidate SHA, actual passed
count, result bundle and screenshot/video evidence. Keep the original captures;
pixel comparisons supplement AX, state, persistence and process assertions.
