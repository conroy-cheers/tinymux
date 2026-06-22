printf '%s\n' started >"$TINYMUX_DIRENV_STATE/child_started"
__tinymux_direnv_child_inside_root() {
    [ "$TINYMUX_DIRENV_ROOT" = "/" ] && return 0
    case "$PWD/" in
        "$TINYMUX_DIRENV_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}
__tinymux_direnv_child_leave_root() {
    printf '%s\n' left-root >"$TINYMUX_DIRENV_STATE/exit_reason"
    command tinymux handoff-capture --state "$TINYMUX_DIRENV_STATE" --slot result
    exit
}
__tinymux_direnv_child_check_root() {
    __tinymux_direnv_child_inside_root || __tinymux_direnv_child_leave_root
}
PROMPT_COMMAND="__tinymux_direnv_child_check_root${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
__tinymux_direnv_child_check_root
