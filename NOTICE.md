# Notice

Third-party material in this repository. Copyright notices for code are in
[LICENSE](LICENSE).

The recorded PTY sessions under `tests/fixtures/ref/` come from
[Alacritty](https://github.com/alacritty/alacritty)'s reference test suite
(Apache License 2.0, © The Alacritty Project). Only the recordings and their
geometry are used, as test input; the expected screens beside them are ours.

The JetBrains Mono Nerd Font files under `swift/Resources/fonts/` are
© The JetBrains Mono Project Authors, patched by [Nerd Fonts](https://www.nerdfonts.com),
and distributed under the SIL Open Font License 1.1 (see
`swift/Resources/fonts/OFL.txt`).

The cases in `tests/expected_screens.rs` and `tests/cluster_edges.rs` are
adapted from the test suite of [x/vt](https://github.com/charmbracelet/x/tree/main/vt),
a terminal emulator library. Where this terminal deliberately behaves as xterm
does and the original case does not, the test says so in a comment.

`scripts/frame-diffs`, which generates `tests/fixtures/frame_diffs/`, uses the
[ultraviolet](https://github.com/charmbracelet/ultraviolet) renderer to produce
the frames and x/vt to confirm them. They are used only by that generator;
nothing of either is built into the terminal.

Both libraries are under the MIT License:

    Copyright (c) 2023-2025 Charmbracelet, Inc.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
