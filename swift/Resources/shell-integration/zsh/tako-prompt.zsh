# The two-line prompt from the design system, for zsh.
#
#   ╭ tako-core git:(main) +3 ~2 · 41.2s · ✓
#   ╰ ❯
#
# Source this from your .zshrc:
#
#   source "$TAKO_RESOURCES_DIR/shell-integration/zsh/tako-prompt.zsh"

[[ -o interactive ]] || return 0
[[ "$TAKO_PROMPT" == 0 ]] && return 0

autoload -Uz add-zsh-hook

# Exactly the colours the design assigns to each part of the prompt.
__gp_ember=$'\e[38;2;244;88;28m'
__gp_claw=$'\e[38;2;255;122;61m'
__gp_dim=$'\e[38;2;138;127;118m'
__gp_ok=$'\e[38;2;123;216;143m'
__gp_err=$'\e[38;2;213;78;83m'
__gp_git=$'\e[38;2;178;148;187m'
__gp_modified=$'\e[38;2;240;198;116m'
__gp_ahead=$'\e[38;2;138;190;183m'
__gp_reset=$'\e[0m'
__gp_bold=$'\e[1m'

# Anything under two seconds is not worth reporting.
__gp_min_duration=2

__gp_preexec() { __gp_started=$SECONDS }
__gp_precmd() {
  __gp_status=$?
  if [[ -n "$__gp_started" ]]; then
    __gp_elapsed=$(( SECONDS - __gp_started ))
    unset __gp_started
  else
    __gp_elapsed=0
  fi
}
add-zsh-hook preexec __gp_preexec
add-zsh-hook precmd __gp_precmd

__gp_git_segment() {
  local branch
  branch=$(command git symbolic-ref --short HEAD 2>/dev/null) \
    || branch=$(command git rev-parse --short HEAD 2>/dev/null) || return
  local dirty=""
  command git diff --quiet --ignore-submodules HEAD 2>/dev/null || dirty="*"
  print -n "${__gp_dim}git:(${__gp_git}${branch}${__gp_err}${dirty}${__gp_dim})"

  local staged modified untracked ahead
  staged=$(command git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  modified=$(command git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(command git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  (( staged ))    && print -n " ${__gp_ok}+${staged}"
  (( modified ))  && print -n " ${__gp_modified}~${modified}"
  (( untracked )) && print -n " ${__gp_dim}?${untracked}"
  ahead=$(command git rev-list --count '@{u}..HEAD' 2>/dev/null)
  [[ -n "$ahead" && "$ahead" != 0 ]] && print -n " ${__gp_ahead}⇡${ahead}"
}

__gp_line_one() {
  print -n "\n${__gp_dim}╭ "
  if [[ -n "$SSH_CONNECTION" ]]; then
    print -n "${__gp_ahead}${USER}@${HOST%%.*}${__gp_dim} ⇄ "
  fi
  print -n "${__gp_bold}${__gp_ember}${PWD:t}${__gp_reset} "
  __gp_git_segment
  if (( __gp_elapsed >= __gp_min_duration )); then
    local shown
    if (( __gp_elapsed < 60 )); then shown="${__gp_elapsed}s"
    else shown="$(( __gp_elapsed / 60 ))m $(printf %02d $(( __gp_elapsed % 60 )))s"; fi
    print -n "${__gp_dim} · ${shown} · "
    if (( __gp_status == 0 )); then print -n "${__gp_ok}✓"
    else print -n "${__gp_err}✘ ${__gp_status}"; fi
  elif (( __gp_status != 0 )); then
    print -n "${__gp_dim} · ${__gp_err}✗ ${__gp_status}"
  fi
  print -n "${__gp_reset}"
}

setopt prompt_subst
PROMPT='$(__gp_line_one)
${__gp_dim}╰ %(?.${__gp_bold}${__gp_ember}.${__gp_bold}${__gp_err})❯ ${__gp_reset}'
RPROMPT=''
