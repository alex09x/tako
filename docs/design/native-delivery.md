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

Forty desktop XCUI scenarios now have passing evidence across the focused runs.
This is cumulative coverage, not a claim that a single forty-test run passed.
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

The final five executed with zero failures and an explicit successful Xcode test
result. Retained videos and attachment manifests support the AX assertions.
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
