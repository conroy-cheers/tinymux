# tinymux-direnv-instant hook for zsh
typeset -g __DIRENV_INSTANT_ENV_FILE=""
typeset -g __DIRENV_INSTANT_STDERR_FILE=""

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
    __tinymux_direnv_restore_mux_path
    (( $+functions[__tinymux_direnv_orig_TRAPUSR1] )) && __tinymux_direnv_orig_TRAPUSR1 "$@"
    zle && zle .reset-prompt && zle -R
}

__tinymux_direnv_run_instant() {
    export DIRENV_INSTANT_SHELL=zsh
    export DIRENV_INSTANT_SHELL_PID=$$
    __tinymux_direnv_restore_mux_path
    if [[ ${DIRENV_INSTANT_USE_CACHE:-1} == 1 && -n "$__DIRENV_INSTANT_ENV_FILE" && -f "$__DIRENV_INSTANT_ENV_FILE" ]]; then
        eval "$(<"$__DIRENV_INSTANT_ENV_FILE")"
        __tinymux_direnv_restore_mux_path
    fi
    trap -- '' SIGINT
    eval "$("$(__tinymux_direnv_instant_bin)" start)"
    __tinymux_direnv_restore_mux_path
    trap - SIGINT
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
    typeset -g __TINYMUX_DIRENV_INSTANT_HOOKED=1
    typeset -g __DIRENV_INSTANT_HOOKED=1
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __tinymux_direnv_hook
    add-zsh-hook chpwd __tinymux_direnv_hook
    add-zsh-hook zshexit __tinymux_direnv_exit_cleanup
    __tinymux_direnv_hook
fi
