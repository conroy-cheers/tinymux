"" | save --force ($env.TINYMUX_DIRENV_STATE | path join "child_started")
def __tinymux_direnv_child_inside_root [] {
    if $env.TINYMUX_DIRENV_ROOT == "/" { return true }
    (($env.PWD + "/") | str starts-with ($env.TINYMUX_DIRENV_ROOT + "/"))
}
def --env __tinymux_direnv_child_leave_root [] {
    "left-root" | save --force ($env.TINYMUX_DIRENV_STATE | path join "exit_reason")
    ^tinymux handoff-capture --state $env.TINYMUX_DIRENV_STATE --slot result
    exit
}
def --env __tinymux_direnv_child_check_root [] {
    if not (__tinymux_direnv_child_inside_root) { __tinymux_direnv_child_leave_root }
}
$env.config.hooks.pre_prompt = (
    ($env.config.hooks.pre_prompt? | default []) | append { __tinymux_direnv_child_check_root }
)
$env.config.hooks.pre_execution = (
    ($env.config.hooks.pre_execution? | default []) | append { __tinymux_direnv_child_check_root }
)
__tinymux_direnv_child_check_root
