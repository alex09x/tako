# Syntax-highlighted `cat`, when bat is installed.
#
# The terminal itself cannot do this. It sees a byte stream, not files: it has
# no idea what language it is looking at, whether it is looking at code at
# all, or where one file's output ends and the next command's begins. And
# every program that already colours its own output -- vim, git diff, ls, the
# prompt above -- would be fighting it, while any TUI that paints an exact
# layout would simply be corrupted.
#
# What actually delivers "my code is coloured" is a pager that understands
# files. bat is that tool, so this wires it in and gets out of the way.
#
# Set TAKO_HIGHLIGHT=0, or drop `highlight` from TAKO_SHELL_FEATURES,
# to keep the plain one.

status --is-interactive; or exit 0
test "$TAKO_HIGHLIGHT" = 0; and exit 0
contains highlight (string split , $TAKO_SHELL_FEATURES); or exit 0
type -q bat; or exit 0

# The guard that makes this safe: only colour when a human is looking. The
# moment stdout is a pipe or a file, `cat` has to stay the byte-exact tool
# every script in the world assumes it is -- `cat f | grep x`, `cat a b > c`
# and `cat` reading stdin all pass straight through.
function cat --wraps cat --description "cat, highlighted when writing to a terminal"
    if not isatty stdout; or test (count $argv) -eq 0
        command cat $argv
        return
    end
    # --style=plain: no line numbers or git gutter, so the output still looks
    # like cat. --paging=never: cat does not page, and neither should this.
    command bat --style=plain --paging=never -- $argv
end
