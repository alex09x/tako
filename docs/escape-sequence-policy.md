# Escape Sequence Policy

## Overview and Threat Model

A terminal emulator processes arbitrary, untrusted byte streams from local processes, remote SSH servers, Docker containers, and external commands. A malicious or compromised script must never be able to:
1. Exfiltrate private data (such as clipboard contents, passwords, or shell history) without explicit authorization.
2. Inject unauthorized input or execute arbitrary commands.
3. Overflow terminal buffers or launch denial-of-service attacks on the host OS / UI thread (e.g. through notification storms or infinite-loop escape sequences).
4. Spoof security boundaries or disguise destinations (e.g. via deceptive hyperlinks or title-based prompt spoofing).

This document specifies Tako's single, authoritative escape sequence policy, enforced directly in the Rust terminal engine and adhered to by the macOS/iOS host applications.

---

## 1. Window and Tab Titles (OSC 0, OSC 2)

- **Permitted Action**: A program may request to set the window or tab title.
- **Length Limit**: Titles are truncated to a maximum of 512 bytes.
- **Sanitization**: All C0 control characters (except tab) and C1 control characters are stripped. Newlines, carriage returns, escape characters (`\x1b`), and backspaces are eliminated to prevent control-sequence injection in window lists and UI dialogs.
- **Host Behavior**: The host may display the title in the tab bar or window title, but it is treated strictly as untrusted text and never interpreted as markup or shell input.

---

## 2. Clipboard Access (OSC 52, OSC 1337 Copy)

### 2.1 Clipboard Write (Set)
- **Sequences**:
  - `OSC 52 ; <targets> ; <base64> ST/BEL`
  - `OSC 1337 ; Copy=: <base64> ST/BEL`
- **Engine Rules**:
  - The payload must be valid Base64 and is capped at 1 MiB (1,048,576 bytes) of decoded text.
  - If `ClipboardPolicy::Disabled` is set, write events are suppressed.
- **Host Enforcement**:
  - If the user has enabled the clipboard write confirmation setting (`clipboard-confirm-write`), Tako prompts the user before placing the text onto the general system pasteboard.
  - When allowed, text is placed on the clipboard with standard newline normalization.

### 2.2 Clipboard Read (Query)
- **Sequence**: `OSC 52 ; <targets> ; ? ST/BEL`
- **Engine Rules**:
  - **Refused by Default**: The engine strictly enforces `ClipboardPolicy::WriteOnly` by default.
  - When `ClipboardPolicy::WriteOnly` or `ClipboardPolicy::Disabled` is active, the engine drops `OSC 52 ; ... ; ?` queries entirely without emitting a `ClipboardQuery` event.
  - `ClipboardQuery` events are only emitted if the host explicitly configures `ClipboardPolicy::ReadWrite`.
- **Host Enforcement**:
  - The host defaults `clipboard-read = false`. Unless the user explicitly enables clipboard read in configuration, any stray query event is dropped with a warning log and no clipboard content is ever sent to the PTY.

---

## 3. Desktop Notifications (OSC 9, OSC 777, OSC 99)

- **Sequences**:
  - ConEmu notification: `OSC 9 ; <message> ST/BEL`
  - Urxvt notification: `OSC 777 ; notify ; <title> ; <body> ST/BEL`
  - Structured notification: `OSC 99 ; [metadata] ; <title> ; <body> ST/BEL`
- **Length Bounds**:
  - Notification titles are capped at 128 characters.
  - Notification bodies are capped at 1024 characters.
  - Control characters (except standard whitespace) are sanitized.
- **Engine Rate-Limiting**:
  - The engine enforces a rate limit of **10 notification events per second** per terminal instance using a sliding window.
  - Any notification sequences exceeding this burst limit are discarded by the engine, preventing notification floods and UI starvation.
- **Host Rules**:
  - Respects macOS Focus / Do Not Disturb modes.
  - Notifications are only delivered to the system notification center when the originating tab/pane is unfocused, unless explicitly configured otherwise (`only_when_unfocused`).

---

## 4. Progress and Status Reporting (OSC 9;4, OSC 9;5, OSC 1337)

### 4.1 ConEmu Taskbar Progress (OSC 9;4)
- **Sequence**: `OSC 9 ; 4 ; <state> ; <value> ST/BEL`
- **Values**:
  - State: `0` = clear, `1` = normal, `2` = error, `3` = indeterminate, `4` = paused. Unrecognized states default to `0`.
  - Value: clamped to integer range `0..=100`.
- **Scope**: Progress is strictly scoped to the reporting pane and clears automatically when the process exits.

### 4.2 Pane Status (OSC 9;5, OSC 1337 SetStatus / ClearStatus)
- **Sequences**:
  - `OSC 9 ; 5 ; <status> [; <text>] ST/BEL`
  - `OSC 1337 ; SetStatus= <status> [; <text>] ST/BEL`
  - `OSC 9 ; 5 ; clear ST/BEL` or `OSC 1337 ; ClearStatus ST/BEL`
- **Normalization**:
  - Status strings are normalized against permitted values: `idle`, `running`, `working` (alias `thinking`), `waiting_for_input`, `needs_approval`, `done`, `error`, `unknown`, `clear`.
  - Explanatory status text is capped at 256 characters and sanitized of control codes.
  - Programs may only set the status of their own containing pane.

---

## 5. Hyperlinks (OSC 8)

- **Sequence**: `OSC 8 ; [id=ID] ; <URI> ST/BEL ... OSC 8 ; ; ST/BEL`
- **Scheme Allowlist**:
  - Permitted schemes: `http:`, `https:`, `file:`.
  - Non-standard, executable, or custom URL schemes (e.g. `javascript:`, `data:`, `applescript:`, `terminal:`) are rejected.
- **Target Verification & Visual Deception Protection (Track E8)**:
  - Tooltip/hover previews show the canonical target URL.
  - If visible text in the terminal resembles a URL that differs from the underlying target URI (e.g. text says `https://trusted.bank.com` but links to `https://evil.com`), the link is flagged as mismatched and requires explicit user confirmation before opening.

---

## 6. Context Hierarchy & Breadcrumbs (OSC 3008)

- **Sequence**: `OSC 3008 ; <push:kind:name[:tint[:elevated]] | pop | clear> ST/BEL`
- **Stack Bound**:
  - Maximum context depth is bounded to 16 frames (`MAX_CONTEXT_STACK_DEPTH = 16`).
  - When the stack is full, non-elevated ancestor frames are evicted while preserving root and elevated markers.
  - Labels are limited to 64 characters and sanitized.

---

## 7. Inline Graphics (Kitty Protocol & iTerm2 OSC 1337)

- **Supported Protocols**:
  - Kitty Graphics Protocol (`DCS _ G <payload> ST`)
  - iTerm2 File Transfer Protocol (`OSC 1337 ; File=inline=1;... : <base64> ST/BEL`)
- **Memory Caps & LRU Eviction**:
  - Enforced per-pane memory cap (`max_memory_bytes`, default 64 MiB).
  - Generation-based LRU eviction purges oldest off-screen images when the cap is reached.
- **Sixel**: Explicitly unsupported due to unchecked memory consumption and CPU vulnerabilities (documented in `docs/sixel-evaluation.md`).

---

## 8. Fuzzing and Engine Enforcement

- Every escape sequence implemented by Tako has a corresponding generator in `fuzz/src/streams.rs` (`EscapeToken`) and is continuously exercised under libFuzzer via `fuzz/fuzz_targets/escape_sequences.rs`.
- Fuzzing verifies that arbitrary, malformed, or boundary-breaking escape sequence payloads:
  1. Never cause panics, memory corruption, or undefined behavior.
  2. Do not allocate unbounded memory.
  3. Comply with all length and rate limits specified in this policy.
