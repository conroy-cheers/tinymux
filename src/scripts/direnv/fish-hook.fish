# tinymux-direnv-instant hook for fish
set -g __DIRENV_INSTANT_ENV_FILE ""
set -g __DIRENV_INSTANT_STDERR_FILE ""

function __tinymux_direnv_instant_bin
    if set -q TINYMUX_DIRENV_INSTANT_BIN
        printf '%s\n' "$TINYMUX_DIRENV_INSTANT_BIN"
    else
        printf '%s\n' direnv-instant
    end
end

function __tinymux_direnv_restore_mux_path
    if set -q TINYMUX_SHIM_DIR; and not contains -- "$TINYMUX_SHIM_DIR" $PATH
        set -gx PATH "$TINYMUX_SHIM_DIR" $PATH
    end
end

function __tinymux_direnv_handler --on-signal USR1
    if test -n "$__DIRENV_INSTANT_STDERR_FILE" -a -f "$__DIRENV_INSTANT_STDERR_FILE"
        if test -s "$__DIRENV_INSTANT_STDERR_FILE"
            command cat "$__DIRENV_INSTANT_STDERR_FILE"
        end
        command rm -f "$__DIRENV_INSTANT_STDERR_FILE" 2>/dev/null; or true
        set -g __DIRENV_INSTANT_STDERR_FILE ""
    end
    if test -n "$__DIRENV_INSTANT_ENV_FILE" -a -f "$__DIRENV_INSTANT_ENV_FILE"
        source "$__DIRENV_INSTANT_ENV_FILE"
    end
    __tinymux_direnv_restore_mux_path
end

function __tinymux_direnv_run_instant
    set -gx DIRENV_INSTANT_SHELL fish
    set -gx DIRENV_INSTANT_SHELL_PID $fish_pid
    __tinymux_direnv_restore_mux_path
    if test "$DIRENV_INSTANT_USE_CACHE" != 0 -a -n "$__DIRENV_INSTANT_ENV_FILE" -a -f "$__DIRENV_INSTANT_ENV_FILE"
        source "$__DIRENV_INSTANT_ENV_FILE"
        __tinymux_direnv_restore_mux_path
    end
    set -l bin (__tinymux_direnv_instant_bin)
    $bin start | source
    __tinymux_direnv_restore_mux_path
end

function __tinymux_direnv_hook --on-event fish_prompt --on-variable PWD
    set -q __TINYMUX_DIRENV_INSTANT_RUNNING; and return
    set -g __TINYMUX_DIRENV_INSTANT_RUNNING 1
    __tinymux_direnv_run_instant
    set -e __TINYMUX_DIRENV_INSTANT_RUNNING
end

function __tinymux_direnv_exit_cleanup --on-event fish_exit
    set -l bin (__tinymux_direnv_instant_bin)
    $bin stop
end

if not set -q __TINYMUX_DIRENV_INSTANT_HOOKED
    set -g __TINYMUX_DIRENV_INSTANT_HOOKED 1
    set -g __DIRENV_INSTANT_HOOKED 1
    __tinymux_direnv_hook
end
