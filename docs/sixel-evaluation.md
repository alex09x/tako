# Evaluation of Sixel Graphics Support for Tako

This document evaluates whether Tako should implement the Sixel graphics protocol, assessing its architectural fit, memory impact, security posture, and ecosystem adoption relative to modern graphics protocols (Kitty Graphics Protocol and iTerm2 OSC 1337).

---

## 1. Executive Summary & Recommendation

**Recommendation**: **Do not implement Sixel in Tako (Not Planned)**.

Tako natively supports both the **Kitty Graphics Protocol** (APC `ESC _ G ... ESC \`) and the **iTerm2 Inline Images Protocol** (OSC `ESC ] 1337 ; File=... ST`). These two protocols cover the overwhelming majority of modern terminal image workflows on macOS and Linux with hardware-accelerated GPU caching, strict per-pane memory bounds, and structured lifecycle management.

Implementing Sixel would introduce substantial architectural baggage, severe memory exhaustion risks, and high parser complexity with minimal real-world benefit.

---

## 2. Protocol Comparison Matrix

| Dimension | Sixel (DEC VT240/VT340) | Kitty Graphics Protocol | iTerm2 Inline Images (OSC 1337) |
| :--- | :--- | :--- | :--- |
| **Origin & Era** | 1980s (DEC serial printers & terminals) | Modern (Kovid Goyal / Kitty, 2017+) | Modern (George Nachman / iTerm2) |
| **Data Encoding** | 6-pixel vertical bit-stripes, ASCII offset (+63) | Base64-encoded binary payload in APC chunks | Base64-encoded binary payload in OSC sequence |
| **Image Compression** | RLE only (uncompressed 6-bit scanlines) | PNG, RGB, RGBA (zlib/DEFLATE compression) | PNG, JPEG, GIF, WebP (standard image formats) |
| **Color Model** | Indexed palette (16–256 registers, stateful RGB) | TrueColor (24-bit RGB / 32-bit RGBA) | TrueColor (24-bit RGB / 32-bit RGBA) |
| **Memory Bounds** | Implicit (unbounded until ESC `\`) | Explicit dimensions (`s`, `v`, chunks, memory cap) | Explicit metadata (`size`, auto-detected header) |
| **GPU Texture Pipeline** | High-overhead CPU unspooling & pixel assembly | Direct zero-copy Metal texture upload (`MTLTexture`) | Direct ImageIO / CoreGraphics hardware decode |
| **Placement Lifecycle** | Inline stream insertion only; no deletion IDs | Explicit image IDs (`i`), placement IDs (`p`), delete (`a=d`) | Inline stream placement with cursor offset |

---

## 3. Detailed Architectural Evaluation

### 3.1. Memory Footprint and Denial-of-Service Risk

1. **Unbounded Scanline Accumulation**:
   Sixel transmits graphics in bands of 6 vertical pixels (`sixel` = six pixels). The terminal parser does not receive image width, height, or byte count upfront. The parser must dynamically reallocate and grow CPU raster buffers as characters arrive until a terminator (`ST` or `ESC \`) is encountered. A malicious or runaway process emitting infinite Sixel stripes can exhaust heap memory rapidly.

2. **Contrast with Tako's Memory Cap**:
   Tako enforces a deterministic per-pane memory limit (`max_memory_bytes`, defaulting to 64 MiB) backed by LRU eviction (by image generation) and chunked allocation limits. In Kitty APC and iTerm2 OSC 1337, dimensions and chunk sizes are bounded upfront, allowing Tako to reject or prune transfers before memory exhaustion occurs.

### 3.2. Rendering Architecture & Apple Silicon Metal Pipeline

1. **CPU Decoding Bottleneck**:
   Sixel decoding is CPU-bound: each incoming ASCII byte corresponds to 6 vertical bits whose active bits map to the currently selected color register index. The terminal must maintain a mutable 256-color palette, unpack vertical bit slices into horizontal pixel rows, and convert palette indices to 32-bit BGRA bytes.

2. **Hardware Acceleration in Tako (`MetalImageCache`)**:
   Tako's macOS rendering architecture feeds directly into Metal shaders via `MetalImageCache`. With Kitty and iTerm2 protocols:
   - Compressed PNG/JPEG/WebP payloads are decoded via macOS `ImageIO` (`CGImageSourceCreateWithData`) directly into premultiplied `BGRA8Unorm` buffers.
   - Textures are cached by unique image identifier and content hash, eliminating redundant decoding across frames or redraws.
   - Sixel provides no texture identifiers or content hashes, requiring costly frame-by-frame CPU raster re-generation.

### 3.3. Security & Parser Attack Surface

1. **Terminal Parser State Pollution**:
   Sixel uses Device Control Strings (DCS `ESC P ... ESC \`). Sixel encoding intersperses color definitions (`#<register>;2;<r>;<g>;<b>`), raster attributes (`"<pan>;<pad>;<ph>;<pv>`), and RLE repeat prefixes (`!<count><char>`) directly into the payload stream. Historical terminal implementations (xterm, mlterm, Mintty) have experienced dozens of buffer overflow vulnerabilities (CVE-2022-24130, CVE-2021-4209, etc.) in Sixel state machines.

2. **Simplicity of Tako's Engine**:
   Tako's parser delegates graphics strictly to isolated modules (`src/graphics.rs` for Kitty APC and dedicated OSC handlers for iTerm2). The payload bytes remain opaque until passed to validated parsers.

### 3.4. Ecosystem & Tool Adoption

A survey of popular command-line tools that render terminal images demonstrates that Sixel is obsolete for modern workflows:

- **`timg`**: Natively supports Kitty graphics protocol and iTerm2 inline images; prefers Kitty over Sixel.
- **`viu`**: Supports Kitty graphics and iTerm2 protocols natively.
- **`chafa`**: Automatically detects Kitty and iTerm2 protocols with truecolor and full 60 FPS animation support.
- **`kitten icat`**: Uses Kitty graphics protocol exclusively.
- **`wezterm imgcat`**: Uses iTerm2 and Kitty protocols.
- **`bat` / `delta` / `glow`**: Integrate Markdown/overlay viewers or ANSI half-blocks.

Tools falling back to Sixel generally do so only when targeting legacy terminals (e.g. DEC VT340 or unpatched xterm). Where neither Kitty nor iTerm2 is present, modern tools fall back to Unicode half-blocks (`▀` / `▄`), which render crisply and performantly across all terminal emulators without graphical protocol overhead.

---

## 4. Conclusion

Adding Sixel support would add significant lines of unsafe, CPU-intensive parsing code while increasing vulnerability to memory inflation attacks, for a protocol superseded by Kitty and iTerm2.

Tako's inline image architecture will remain focused on:
1. **Kitty Graphics Protocol** (full specification compliance, queries, and chunked transfers).
2. **iTerm2 Inline Images Protocol** (OSC 1337 `File=inline=1`).
3. **In-Terminal Artifact and Document Overlays** (Track D1, sandboxed WebKit preview for rich HTML, PDF, Markdown, and images).
