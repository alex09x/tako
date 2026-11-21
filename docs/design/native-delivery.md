# Native desktop implementation

The owner authorized native delivery of the existing desktop prototype on
2026-11-08. The frozen source and screenshots are in `desktop-reference/`.
The pre-change application is build 526, source `9785be25`.

## Product boundaries

The native interface uses actual terminal instances, settings, presets, agent
installation state and public permission observations. Browser fixture data,
prototype debug labels, speculative project execution and the hidden experimental
SSH/result workflow are not production functionality.

Application appearance is independent of terminal colors and typography.
Presentation settings must never clear status, unread information or permissions.
Session appearance is a requested extension to the existing workspace/pane model;
it requires a real persistent identity and migration, not copying parent values.
Terminal SDK padding stays zero. Any spacing taken from the desktop reference
belongs to the application layout and must be accounted for in terminal sizing.

## Interface language

Product-owned desktop copy is English throughout: settings, setup, permissions,
menus, tooltips, accessibility descriptions and errors. Terminal output and
user-provided workspace, session, pane and custom-theme names retain their Unicode
content. Frozen design archives remain historical evidence, not the product's
language specification.

The two contrast presets are named `High Contrast` and `High Contrast Light`.
Their previous names still resolve when reading saved configurations; no user
configuration rewrite is required. Their palette and typography remain unchanged.
The desktop-copy tests cover English wording, English plural forms and legacy
theme selection. The English UI journey visits every settings section and verifies
that Unicode terminal output and process identity survive the interaction.

The owner authorized rewriting only the unpublished desktop-design chain after
`9785be25`. Its previous tip is retained in the local recovery reference
`backup/native-desktop-before-english-20261109`. Earlier history and the unrelated
dirty canonical checkout are preserved.

English acceptance is cumulative: eight existing menu/setup/theme/workspace
journeys passed in `english-desktop.xcresult`; the new all-sections/Unicode journey
passed in `english-interface-final.xcresult` after correcting its use of AppKit's
`title` attribute for native menu captions. Earlier failed bundles are retained.
Focused native checks passed across the affected suites and their failed-scope
reruns. The toast observation test uses an unattached surface to avoid unrelated
window attachment/focus events acknowledging its manually injected status.

## Free-window behavior

The overlapping-windows control appears and hides with the other header controls.
In free mode its outline glyph has a quiet orange tint, without a selected fill
or border. Returning to the grid clears its selected state.

An explicitly free pane never proposes edge or peer docking. Grid-origin header
drags retain docking previews; releasing outside a target enters free mode.
Free panes form a separate layer above every grid pane in their own session,
including maximized grid panes. Focus raises panes only within their layer.
Minimize/restore preserves free membership, preferred rectangle and process
identity. These are application-internal panes, not globally floating macOS windows.

## Verification

Use the existing remote MacBook workflow with build/cache/evidence on its external
disk. Implement coherent changes before the final validation gate. Run only new
or directly affected checks; reuse unchanged successful evidence. Real providers
and unrelated suites are outside this visual delivery gate.

Required interaction coverage includes:

- Centered settings across sections, scopes, resizing and light/dark appearance.
- Theme duplication/editing/save/cancel; parent changes, child overrides and reset.
- Real font inventory, fractional base size and separate temporary zoom.
- Shortcut recording/cancel/conflict/reassignment/default reset without dispatching
  the captured key to the terminal.
- Tiled/floating/maximized/minimized transitions retaining the same Surface/PTY,
  preferred rectangle, process identity and keyboard focus.
- Sidebar selection/search/workspace actions and independently configurable counts.
- Optional first-run stages, resume/skip and final return to the existing terminal.
- Permission refresh without unsolicited prompts; explicit protected-folder checks;
  honest unknown/managed states and notification submission versus delivery.

## Visual evidence

Reference series A uses a 1440×900 CSS viewport at 2×. The app rectangle is
1400×880 points at x20/y0, so a full-window native capture compares with the
reference crop `40,0,2800,1760` in pixels. Series B covers a small window.
Use matching appearance, scale, dimensions, controlled terminal contents and
available fonts. Keep original screenshots and recorded interactions.

`scripts/compare-desktop-reference.py` produces an explicit sRGB pixel difference,
overlay and JSON measurements. It refuses mismatched dimensions rather than
resizing them. Any excluded dynamic content is listed and its fraction reported.
Do not hide a geometry/control defect behind an image tolerance. Different
font rasterization and animation phase require inspection; automated AX geometry
and behavior assertions are independent of visual similarity.

## Delivery

Review actual worker diffs and test logs, reconcile each integration result, then
run focused native GUI acceptance and inspect retained captures. Signing preserves
the existing helper-first manifest hashing order. A local application replacement
must preserve a fresh inventory of every persistent pane UUID, PID and process
birth timestamp. Keep a rollback bundle and remove only owned temporary test
runtime copies. Public publishing is not part of this delivery.

## Final scoped acceptance evidence

Forty-two desktop XCUI scenarios now have passing evidence across the focused runs.
This is cumulative coverage, not a claim that a single forty-two-test run passed.
The external acceptance checkout retains the original failed bundles as well as
the successful reruns:

| Result bundle | Verified scope |
| --- | --- |
| `desktop-half.xcresult` | Fractional font input, including half points |
| `desktop-final.xcresult`, `desktop-plus.xcresult` | Settings, recorder, setup and anchored native plus menu; the menu correction passed in its focused rerun |
| `workflow-dock.xcresult`, `workspace-check.xcresult` | Real tiled docking, Option free drag, same pane/process identities and workspace creation |
| `controls-complete.xcresult` | Eight successful scenarios: search reveal, font inventory, header actions, scoped colors and inheritance, expanded themes, workspace protection and context zoom |
| `controls-retry.xcresult` | Three successful scenarios: complete header mode actions, workspace rename/collapse and temporary zoom/base-size reset |
| `final-workflows.xcresult` | Five successful scenarios: persistent pane names, custom-theme rename/delete protection, toast restore/focus and expiry |
| `sidebar-list-final.xcresult` | Three successful scenarios: search, session switch-back with process/focus continuity, and active-row visibility with sixteen sessions |
| `shelf-overlay-final.xcresult` | Overlay pill placement, full terminal height, normal grid reflow, bottom click/focus, maximize and process identity |
| `free-mode.xcresult` | Five passing scenarios: persistent selected-mode pixels, ordinary free drag without docking, grid docking, free/grid layering and free-sibling focus, minimize/restore with the same process |
| `free-mode-quiet-final.xcresult` | Owner's visual refinement: shared hover visibility, quiet outline-glyph tint without a selected border/fill, ordinary undocked drag and the same process |

The original final five executed with zero failures and an explicit successful Xcode test
result. Retained videos and attachment manifests support the AX assertions.
The later quiet-control check passed after two failed reproductions exposed stale
hover state following tracking-area replacement. Native button hover is now
reconciled with the physical pointer after layout, coalesced outside SwiftUI layout
and emitted only on a state change. A focused native test also verifies clearing
an entered tracking area without a matching exit event. The quiet-control result
supersedes the always-visible selected fill/border from the earlier free-mode run.
Theme assets contain twenty-four approved additional full presets, preserving
the ten existing presets. Focused native tests verify real loading, fractional
typography, complete ANSI palettes and visible dim ANSI text. The status-frame
test verifies a mounted terminal frame and that hiding presentation preserves
the underlying working state. A corrected 1280×700 fixture passed after the
original 400-point fixture could not contain the frame it was searching for.

Native settings were also measured through Accessibility at 820×700. Visual
review uses the frozen reference, the native theme-management recording and
the size/zoom recording. This is not a zero-pixel-difference claim: terminal
content, installed fonts, system rasterization and animation phase differ.

## Live performance follow-up

Build 568 exposed repeated filesystem catalog discovery in closed sidebar menus.
The menu metadata snapshot now refreshes on configuration/catalog changes rather
than terminal status ticks. Live resize defers hidden sibling window/PTY geometry
until the final size; native titlebar lookup caches weak hierarchy references.
Focused regressions verify both invalidation and bounded resize/lookup work.

The next change suspends expensive sidebar row composition and redundant event
relay in hidden tab windows. A per-window KVO presentation model survives SwiftUI
suspension. Header/search controls remain mounted, preserving the native field
and query. Initial mounting does not constitute a request to focus search.
The existing tab-selection policy still focuses the terminal. The active row is
scrolled into view after list remount. Three focused native visibility tests and
the three live scenarios above passed; successful GUI recordings are retained.
Signed build 571 (`c79bd3e8`) was installed with all twelve persistent pane UUID,
PID and process-birth identities preserved. Three five-second live CPU intervals
after settling measured 9.38%, 8.97%, 8.97% of one core; the initial build-568
interval measured 67.17%. These are live observations, not a controlled benchmark.
The final thirty-second sample no longer shows repeated theme-directory discovery
or recursive native-titlebar lookup in its hot paths. The independent macOS
`fseventsd` load is recorded separately and was not changed.

## Shelf overlay clarification, 2026-11-09

The owner's follow-up confirms that shelf pills overlay the field at 14 points
from its bottom/right edges, with no reserved strip. Existing canvas insets stay.
The work area is identical with and without minimized panes. Minimizing a tiled
pane still collapses that grid leaf, so neighbors fill its space; restoring the
pane restores the split. There is no empty reserved tile. Floating/maximized
neighbors lose no height simply because shelf cards appear.

Focused native tests verify full work area, rendered terminal height/rows, normal
tile reflow/restore, maximized geometry and pill coordinates. The live overlay
scenario passed in 33.173 seconds and checks input at the bottom of the terminal
with search previously focused, plus unchanged process identities. Successful
video and earlier failed development evidence remain on the external build disk.
