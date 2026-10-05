# Evaluation of Text Sizing Protocol (OSC 66) for Tako

This document evaluates the proposed **OSC 66 text sizing protocol** for Tako, analyzing current terminal tool adoption, architectural consequences on grid layout and rendering, and alternative mechanisms for formatted document presentation.

---

## 1. Executive Summary & Recommendation

**Recommendation**: **Do not implement OSC 66 in Tako (Closed as Not Planned)**.

While OSC 66 attempts to provide proportional text sizing and large headings within the terminal character grid, it suffers from negligible adoption across modern CLI tools and TUIs. Furthermore, supporting non-uniform cell heights and variable font sizes inside the core terminal grid fundamentally compromises grid addressing invariants, Metal rendering performance, selection geometry, and accessibility.

For documents requiring rich headings and proportional typography (e.g. reports, diffs, documentation, previews), Tako's **In-Terminal Artifact and Document Overlays (Track D1)** provide a sandboxed WebKit-based presentation without degrading the high-throughput terminal grid.

---

## 2. Background: The OSC 66 Protocol

The OSC 66 escape sequence (originally drafted by terminal developers in projects such as Foot and Contour) allows programs to request scaled character sizing within the grid:

```text
OSC 66 ; s=<scale> ; <text> ST
```

Where `s=<scale>` requests a multiplier (e.g. `s=2` for 2x scaling) to render headings or banner text directly inside the terminal window.

---

## 3. Detailed Architectural Evaluation

### 3.1. Ecosystem & Tool Adoption

A comprehensive review of modern command-line software indicates virtually zero adoption of OSC 66:

1. **TUI Frameworks**:
   - `ratatui` (Rust), `bubbletea` / `lipgloss` (Go), `textual` / `rich` (Python), and `ink` (JavaScript) do not support or generate OSC 66. They structure hierarchies using ANSI colors, font weights (bold, dim), borders, and box-drawing glyphs.

2. **Shells & Prompts**:
   - Neither standard shells (`zsh`, `bash`, `fish`) nor prompt engines (`starship`, `powerlevel10k`, `oh-my-posh`) emit OSC 66 sequences.

3. **Pagers & Development Tools**:
   - `bat`, `delta`, `less`, `glow`, and `mdcat` format headers using standard ANSI SGR attributes and borders, or fallback to plain text.

4. **Coding Agents & Headless CLI Tools**:
   - Agent CLIs (such as Claude Code, Gemini CLI, Aider, and Codex) output standard markdown and stream text using standard UTF-8 and ANSI colors.

No mainstream application depends on OSC 66 for usability or features.

### 3.2. Grid Engine Invariants and Performance Impact

Tako's terminal engine (`src/grid/`) and Metal renderer are designed around strict character cell invariants:

1. **Fixed-Stride Memory Architecture**:
   - Terminal cells are organized in contiguous row buffers with deterministic column indices. Standard characters occupy 1 column; CJK and emojis occupy 2 columns with an explicit spacer cell.
   - This fixed grid geometry allows `O(1)` cell lookups, constant-time buffer slicing, zero-copy dirty region tracking, and high-throughput Metal vertex buffer generation at 120 FPS.

2. **Grid Geometry Breakdown with Variable Text**:
   - Dynamically scaling font sizes within the grid causes rows to have non-uniform vertical heights or consume fractional cell strides.
   - Cursor navigation sequences (`CUP`, `CUU`, `CUD`, `CUB`, `CUF`), tabstops, horizontal margins (`DECSLRM`), and vertical scroll regions (`DECSTBM`) assume uniform cell dimensions.
   - Line wrapping, soft-wrap tracking, and reflow on window resize become non-deterministic when cells span varying pixel heights.

3. **Text Selection and Accessibility**:
   - Rectangular (block) selection and line selection rely on uniform row/column bounding boxes. Non-uniform cells create ragged selection artifacts.
   - macOS Accessibility (`NSAccessibility` / VoiceOver) expects a structured grid of text rows. Variable-sized embedded cells confuse screen readers and accessibility scrapers.

### 3.3. The Better Alternative: In-Terminal Overlays (Track D1)

Where rich headings, proportional typography, formatted tables, or rendered Markdown are desirable, Tako already provides **In-Terminal Artifact and Document Overlays (Track D1)**:

- `takoctl overlay open <file>` renders HTML, Markdown, PDF, and images in a sandboxed, hardware-accelerated webview positioned seamlessly beside or over terminal panes.
- Overlays maintain complete access to terminal theme variables (`--tako-bg`, `--tako-fg`, ANSI palette) while supporting full CSS typographic scale (`h1`, `h2`, `rem`).
- This cleanly separates high-performance, fixed-stride terminal text from proportional document presentation, keeping the terminal engine fast, predictable, and robust.

---

## 4. Conclusion & Roadmap Disposition

Because OSC 66:
1. Lacks adoption across active CLI tools,
2. Incurs immense architectural complexity on the terminal grid and Metal renderer, and
3. Is superseded by Tako's native sandboxed artifact overlays (Track D1),

**Track D5 is resolved and closed as Not Planned.**
