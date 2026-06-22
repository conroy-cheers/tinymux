printf '%s\n' started > "$TINYMUX_DIRENV_STATE/child_started"
function __tinymux_direnv_child_inside_root
    test "$TINYMUX_DIRENV_ROOT" = /; and return 0
    string match -q "$TINYMUX_DIRENV_ROOT/*" "$PWD/"
end
function __tinymux_direnv_child_leave_root
    printf '%s\n' left-root > "$TINYMUX_DIRENV_STATE/exit_reason"
    command tinymux handoff-capture --state "$TINYMUX_DIRENV_STATE" --slot result
    exit
end
function __tinymux_direnv_child_check_root --on-variable PWD --on-event fish_prompt
    __tinymux_direnv_child_inside_root; or __tinymux_direnv_child_leave_root
end
__tinymux_direnv_child_check_root
