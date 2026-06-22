# tinymux-direnv-instant hook for zsh
typeset -g __DIRENV_INSTANT_ENV_FILE=""
typeset -g __DIRENV_INSTANT_STDERR_FILE=""

__tinymux_direnv_instant_bin() {
    printf '%s\n' "${TINYMUX_DIRENV_INSTANT_BIN:-direnv-instant}"
}

__tinymux_direnv_inside_tinymux() {
    [[ -n "${TINYMUX:-}" || -n "${TINYMUX_SEAMLESS:-}" ]]
}

__tinymux_direnv_other_mux() {
    __tinymux_direnv_inside_tinymux && return 1
    [[ -n "${TMUX:-}" || -n "${ZELLIJ:-}" || -n "${KITTY_LISTEN_ON:-}" || "${TERM_PROGRAM:-}" == "WezTerm" ]]
}

__tinymux_direnv_find_envrc() {
    local dir="$PWD"
    while :; do
        if [[ -f "$dir/.envrc" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
        [[ "$dir" == "/" ]] && return 1
        dir="${dir%/*}"
        [[ -n "$dir" ]] || dir="/"
    done
}

if (( $+functions[TRAPUSR1] )); then
    functions[__tinymux_direnv_orig_TRAPUSR1]="$functions[TRAPUSR1]"
fi
TRAPUSR1() {
    if [[ -n "$__DIRENV_INSTANT_STDERR_FILE" && -f "$__DIRENV_INSTANT_STDERR_FILE" ]]; then
        if [[ -s "$__DIRENV_INSTANT_STDERR_FILE" ]]; then
            printf '%s\n' "$(<"$__DIRENV_INSTANT_STDERR_FILE")"
        fi
        command rm -f "$__DIRENV_INSTANT_STDERR_FILE" 2>/dev/null || true
        __DIRENV_INSTANT_STDERR_FILE=""
    fi
    if [[ -n "$__DIRENV_INSTANT_ENV_FILE" && -f "$__DIRENV_INSTANT_ENV_FILE" ]]; then
        eval "$(<"$__DIRENV_INSTANT_ENV_FILE")"
    fi
    (( $+functions[__tinymux_direnv_orig_TRAPUSR1] )) && __tinymux_direnv_orig_TRAPUSR1 "$@"
    zle && zle .reset-prompt && zle -R
}

__tinymux_direnv_run_instant() {
    export DIRENV_INSTANT_SHELL=zsh
    export DIRENV_INSTANT_SHELL_PID=$$
    if [[ ${DIRENV_INSTANT_USE_CACHE:-1} == 1 && -n "$__DIRENV_INSTANT_ENV_FILE" && -f "$__DIRENV_INSTANT_ENV_FILE" ]]; then
        eval "$(<"$__DIRENV_INSTANT_ENV_FILE")"
    fi
    trap -- '' SIGINT
    eval "$("$(__tinymux_direnv_instant_bin)" start)"
    trap - SIGINT
}

__tinymux_direnv_enter_root() {
    local root="$1"
    local state code reason
    state=$(mktemp -d "${TMPDIR:-/tmp}/tinymux-direnv.XXXXXX") || return 1
    command tinymux handoff-capture --state "$state" --slot baseline || {
        command rm -rf -- "$state"
        return 1
    }
    command tinymux-direnv-instant child-init zsh >"$state/zshrc" || {
        command rm -rf -- "$state"
        return 1
    }
    mkdir -p "$state/zdotdir"
    mv "$state/zshrc" "$state/zdotdir/.zshrc"
    TINYMUX_DIRENV_ROOT="$root" TINYMUX_DIRENV_STATE="$state" TINYMUX_PARENT_ZDOTDIR="${ZDOTDIR:-$HOME}" command tinymux --seamless --handoff-state "$state" -- env ZDOTDIR="$state/zdotdir" zsh -i
    code=$?
    reason=$(command cat "$state/exit_reason" 2>/dev/null || true)
    if [[ "$reason" == "left-root" ]]; then
        eval "$(command tinymux handoff-apply --shell sh --state "$state")"
        command rm -rf -- "$state"
        return "$code"
    fi
    if [[ -f "$state/child_started" ]]; then
        command rm -rf -- "$state"
        exit "$code"
    fi
    command rm -rf -- "$state"
    return "$code"
}

__tinymux_direnv_maybe_enter() {
    [[ "${TINYMUX_DIRENV_DISABLE:-0}" == "1" ]] && return 1
    __tinymux_direnv_inside_tinymux && return 1
    __tinymux_direnv_other_mux && return 1
    local root
    root=$(__tinymux_direnv_find_envrc) || return 1
    __tinymux_direnv_enter_root "$root"
}

__tinymux_direnv_hook() {
    [[ -n "${__TINYMUX_DIRENV_INSTANT_RUNNING:-}" ]] && return
    __TINYMUX_DIRENV_INSTANT_RUNNING=1
    __tinymux_direnv_maybe_enter || true
    unset __TINYMUX_DIRENV_INSTANT_RUNNING
    __tinymux_direnv_run_instant
}

__tinymux_direnv_exit_cleanup() {
    "$(__tinymux_direnv_instant_bin)" stop
}

if [[ -z "${__TINYMUX_DIRENV_INSTANT_HOOKED:-}" ]]; then
    typeset -g __TINYMUX_DIRENV_INSTANT_HOOKED=1
    typeset -g __DIRENV_INSTANT_HOOKED=1
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __tinymux_direnv_hook
    add-zsh-hook chpwd __tinymux_direnv_hook
    add-zsh-hook zshexit __tinymux_direnv_exit_cleanup
    __tinymux_direnv_hook
fi
