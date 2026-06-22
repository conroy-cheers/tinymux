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

function __tinymux_direnv_inside_tinymux
    set -q TINYMUX; or set -q TINYMUX_SEAMLESS
end

function __tinymux_direnv_other_mux
    __tinymux_direnv_inside_tinymux; and return 1
    set -q TMUX; and return 0
    set -q ZELLIJ; and return 0
    set -q KITTY_LISTEN_ON; and return 0
    test "$TERM_PROGRAM" = WezTerm; and return 0
    return 1
end

function __tinymux_direnv_find_envrc
    set -l dir "$PWD"
    while true
        if test -f "$dir/.envrc"
            printf '%s\n' "$dir"
            return 0
        end
        test "$dir" = /; and return 1
        set dir (dirname "$dir")
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
end

function __tinymux_direnv_run_instant
    set -gx DIRENV_INSTANT_SHELL fish
    set -gx DIRENV_INSTANT_SHELL_PID $fish_pid
    if test "$DIRENV_INSTANT_USE_CACHE" != 0 -a -n "$__DIRENV_INSTANT_ENV_FILE" -a -f "$__DIRENV_INSTANT_ENV_FILE"
        source "$__DIRENV_INSTANT_ENV_FILE"
    end
    set -l bin (__tinymux_direnv_instant_bin)
    $bin start | source
end

function __tinymux_direnv_enter_root
    set -l root "$argv[1]"
    set -l state (mktemp -d -t tinymux-direnv.XXXXXX); or return 1
    command tinymux handoff-capture --state "$state" --slot baseline; or begin
        command rm -rf -- "$state"
        return 1
    end
    command tinymux-direnv-instant child-init fish > "$state/config.fish"; or begin
        command rm -rf -- "$state"
        return 1
    end
    command env TINYMUX_DIRENV_ROOT="$root" TINYMUX_DIRENV_STATE="$state" tinymux --seamless --handoff-state "$state" -- fish -i -C "source $state/config.fish"
    set -l code $status
    set -l reason ""
    test -f "$state/exit_reason"; and set reason (command cat "$state/exit_reason")
    if test "$reason" = left-root
        source (command tinymux handoff-apply --shell fish --state "$state" | psub)
        command rm -rf -- "$state"
        return $code
    end
    if test -f "$state/child_started"
        command rm -rf -- "$state"
        exit $code
    end
    command rm -rf -- "$state"
    return $code
end

function __tinymux_direnv_maybe_enter
    test "$TINYMUX_DIRENV_DISABLE" = 1; and return 1
    __tinymux_direnv_inside_tinymux; and return 1
    __tinymux_direnv_other_mux; and return 1
    set -l root (__tinymux_direnv_find_envrc); or return 1
    __tinymux_direnv_enter_root "$root"
end

function __tinymux_direnv_hook --on-event fish_prompt --on-variable PWD
    set -q __TINYMUX_DIRENV_INSTANT_RUNNING; and return
    set -g __TINYMUX_DIRENV_INSTANT_RUNNING 1
    __tinymux_direnv_maybe_enter; or true
    set -e __TINYMUX_DIRENV_INSTANT_RUNNING
    __tinymux_direnv_run_instant
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
