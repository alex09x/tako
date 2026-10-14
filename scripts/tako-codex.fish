# tako — Shell-scoped Codex launch without changing the vendor launcher
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

function codex
    if set -q TAKO_SOCKET; and set -q TAKO_SURFACE_ID; and test -x "$HOME/.local/bin/tako-codex"
        command "$HOME/.local/bin/tako-codex" $argv
    else
        command "$HOME/.local/bin/codex" $argv
    end
end
