# tinymux-direnv-instant hook for bash
__DIRENV_INSTANT_ENV_FILE=""
__DIRENV_INSTANT_STDERR_FILE=""

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

__tinymux_direnv_handler() {
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
}

__tinymux_direnv_run_instant() {
    export DIRENV_INSTANT_SHELL=bash
    export DIRENV_INSTANT_SHELL_PID=$$
    if [[ ${DIRENV_INSTANT_USE_CACHE:-1} == 1 && -n "$__DIRENV_INSTANT_ENV_FILE" && -f "$__DIRENV_INSTANT_ENV_FILE" ]]; then
        eval "$(<"$__DIRENV_INSTANT_ENV_FILE")"
    fi
    local previous_exit_status=$?
    trap -- '' SIGINT
    eval "$("$(__tinymux_direnv_instant_bin)" start)"
    trap - SIGINT
    return "$previous_exit_status"
}

__tinymux_direnv_enter_root() {
    local root="$1"
    local state code reason
    state=$(mktemp -d "${TMPDIR:-/tmp}/tinymux-direnv.XXXXXX") || return 1
    command tinymux handoff-capture --state "$state" --slot baseline || {
        command rm -rf -- "$state"
        return 1
    }
    command tinymux-direnv-instant child-init bash >"$state/bashrc" || {
        command rm -rf -- "$state"
        return 1
    }
    TINYMUX_DIRENV_ROOT="$root" TINYMUX_DIRENV_STATE="$state" command tinymux --seamless --handoff-state "$state" -- bash --rcfile "$state/bashrc" -i
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
    __TINYMUX_DIRENV_INSTANT_HOOKED=1
    __DIRENV_INSTANT_HOOKED=1
    trap '__tinymux_direnv_handler' USR1
    trap '__tinymux_direnv_exit_cleanup' EXIT
    if [[ ";${PROMPT_COMMAND[*]:-};" != *";__tinymux_direnv_hook;"* ]]; then
        if [[ "$(declare -p PROMPT_COMMAND 2>&1)" == "declare -a"* ]]; then
            PROMPT_COMMAND=(__tinymux_direnv_hook "${PROMPT_COMMAND[@]}")
        else
            PROMPT_COMMAND="__tinymux_direnv_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        fi
    fi
    __tinymux_direnv_hook
fi
