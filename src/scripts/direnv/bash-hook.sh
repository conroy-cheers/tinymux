# tinymux-direnv-instant hook for bash
__DIRENV_INSTANT_ENV_FILE=""
__DIRENV_INSTANT_STDERR_FILE=""

__tinymux_direnv_instant_bin() {
    printf '%s\n' "${TINYMUX_DIRENV_INSTANT_BIN:-direnv-instant}"
}

__tinymux_direnv_restore_mux_path() {
    [[ -z "${TINYMUX_SHIM_DIR:-}" ]] && return
    case ":$PATH:" in
        *":$TINYMUX_SHIM_DIR:"*) ;;
        *) export PATH="$TINYMUX_SHIM_DIR:$PATH" ;;
    esac
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
    __tinymux_direnv_restore_mux_path
}

__tinymux_direnv_run_instant() {
    export DIRENV_INSTANT_SHELL=bash
    export DIRENV_INSTANT_SHELL_PID=$$
    __tinymux_direnv_restore_mux_path
    if [[ ${DIRENV_INSTANT_USE_CACHE:-1} == 1 && -n "$__DIRENV_INSTANT_ENV_FILE" && -f "$__DIRENV_INSTANT_ENV_FILE" ]]; then
        eval "$(<"$__DIRENV_INSTANT_ENV_FILE")"
        __tinymux_direnv_restore_mux_path
    fi
    local previous_exit_status=$?
    trap -- '' SIGINT
    eval "$("$(__tinymux_direnv_instant_bin)" start)"
    __tinymux_direnv_restore_mux_path
    trap - SIGINT
    return "$previous_exit_status"
}

__tinymux_direnv_hook() {
    [[ -n "${__TINYMUX_DIRENV_INSTANT_RUNNING:-}" ]] && return
    __TINYMUX_DIRENV_INSTANT_RUNNING=1
    __tinymux_direnv_run_instant
    unset __TINYMUX_DIRENV_INSTANT_RUNNING
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
