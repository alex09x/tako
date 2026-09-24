# The two-line prompt from the design system.
#
#   ╭ tako-core git:(main) +3 ~2 −1 ⇡2 · 41.2s · ✓
#   ╰ ❯
#
# Duration and the status glyph appear only when a command ran longer than
# two seconds, so quick commands leave the prompt clean. Set
# TAKO_PROMPT=0 to keep your own prompt.

status --is-interactive; or exit 0
test "$TAKO_PROMPT" = 0; and exit 0
set -q MC_SID; and exit 0  # inside mc's subshell — leave its protocol intact
contains prompt (string split , $TAKO_SHELL_FEATURES); or exit 0

# Brand palette.
set -g __gp_ember F4581C
set -g __gp_claw FF7A3D
set -g __gp_dim 6a6a6a
set -g __gp_ok 9ece6a
set -g __gp_err f7768e
set -g __gp_git 7aa2f7

# Anything shorter than this is not worth reporting.
set -g __gp_min_duration 2000

function __gp_duration -a ms
    if test $ms -lt 1000
        printf '%dms' $ms
    else if test $ms -lt 60000
        printf '%.1fs' (math "$ms / 1000")
    else
        printf '%dm %02ds' (math -s0 "$ms / 60000") (math -s0 "$ms % 60000 / 1000")
    end
end

# `git:(branch*) +staged ~modified -deleted ⇡ahead`
function __gp_git
    set -l branch (command git symbolic-ref --short HEAD 2>/dev/null; or command git rev-parse --short HEAD 2>/dev/null)
    test -n "$branch"; or return

    set -l dirty ""
    command git diff --quiet --ignore-submodules HEAD 2>/dev/null; or set dirty "*"

    set_color $__gp_dim; printf 'git:('
    set_color $__gp_git; printf '%s' $branch
    set_color $__gp_err; printf '%s' $dirty
    set_color $__gp_dim; printf ')'

    # Counts, only when there is something to count.
    set -l staged (command git diff --cached --numstat 2>/dev/null | count)
    set -l modified (command git diff --numstat 2>/dev/null | count)
    set -l untracked (command git ls-files --others --exclude-standard 2>/dev/null | count)
    test $staged -gt 0; and begin; set_color $__gp_ok; printf ' +%d' $staged; end
    test $modified -gt 0; and begin; set_color $__gp_claw; printf ' ~%d' $modified; end
    test $untracked -gt 0; and begin; set_color $__gp_dim; printf ' ?%d' $untracked; end

    # Ahead of the upstream branch.
    set -l ahead (command git rev-list --count '@{u}..HEAD' 2>/dev/null)
    test -n "$ahead" -a "$ahead" != 0; and begin; set_color $__gp_claw; printf ' ⇡%s' $ahead; end
end

function fish_prompt
    set -l last_status $status
    set -l duration $CMD_DURATION

    set_color $__gp_dim; printf '╭ '

    # Over ssh the host replaces the plain directory, because which machine
    # you are on matters more than where on it.
    if set -q SSH_CONNECTION
        set_color $__gp_claw; printf '%s@%s' (whoami) (prompt_hostname)
        set_color $__gp_dim; printf ' ⇄ '
    end
    set_color -o $__gp_ember; printf '%s' (basename (pwd))
    set_color normal; printf ' '

    __gp_git

    if test -n "$duration" -a "$duration" -ge $__gp_min_duration
        set_color $__gp_dim; printf ' · %s · ' (__gp_duration $duration)
        if test $last_status -eq 0
            set_color $__gp_ok; printf '✓'
        else
            set_color $__gp_err; printf '✗ %d' $last_status
        end
    else if test $last_status -ne 0
        # A fast failure still has to be visible.
        set_color $__gp_dim; printf ' · '
        set_color $__gp_err; printf '✗ %d' $last_status
    end

    printf '\n'
    set_color $__gp_dim; printf '╰ '
    # The arrow carries the exit state when nothing else does.
    if test $last_status -eq 0
        set_color -o $__gp_ember
    else
        set_color -o $__gp_err
    end
    printf '❯ '
    set_color normal
end

# The right side stays empty: the design keeps everything on the left.
function fish_right_prompt
end
