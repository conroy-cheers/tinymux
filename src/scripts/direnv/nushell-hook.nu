# tinymux-direnv-instant hook for Nushell.
def __tinymux_direnv_instant_bin [] {
    $env.TINYMUX_DIRENV_INSTANT_BIN? | default "direnv-instant"
}

def --env __tinymux_direnv_restore_mux_path [] {
    let shim = ($env.TINYMUX_SHIM_DIR? | default "")
    if ($shim | is-empty) { return }
    let paths = ($env.PATH? | default [])
    if not ($shim in $paths) { $env.PATH = ($paths | prepend $shim) }
}

def __tinymux_direnv_load_file [path: string] {
    if ($path | is-empty) or not ($path | path exists) { return {} }
    open --raw $path | from json | default {}
}

def --env __tinymux_direnv_apply [data: record] {
    let to_load = (
        $data | items {|k v| {key: $k, val: $v} } | where val != null
        | reduce -f {} {|it acc| $acc | upsert $it.key $it.val }
    )
    let to_unset = ($data | items {|k v| if $v == null { $k } } | compact)
    for k in $to_unset { hide-env --ignore-errors $k }
    if not ($to_load | is-empty) { load-env $to_load }
}

def --env __tinymux_direnv_show_stderr [] {
    let f = ($env.__DIRENV_INSTANT_STDERR_FILE? | default "")
    if ($f | is-empty) or not ($f | path exists) { return }
    let content = (open --raw $f)
    if not ($content | is-empty) { print --stderr $content }
    rm --force $f
}

def --env __tinymux_direnv_run_instant [] {
    $env.DIRENV_INSTANT_SHELL = "nu"
    $env.DIRENV_INSTANT_SHELL_PID = ($nu.pid | into string)
    __tinymux_direnv_restore_mux_path
    let cached = (__tinymux_direnv_load_file ($env.__DIRENV_INSTANT_ENV_FILE? | default ""))
    let bin = (__tinymux_direnv_instant_bin)
    let raw = (run-external $bin start | str trim)
    let state = if ($raw | is-empty) { {} } else { $raw | from json }
    let next_file = ($state.__DIRENV_INSTANT_ENV_FILE? | default ($env.__DIRENV_INSTANT_ENV_FILE? | default ""))
    let fresh = (__tinymux_direnv_load_file $next_file)
    __tinymux_direnv_apply ($cached | merge $state | merge $fresh)
    __tinymux_direnv_restore_mux_path
    __tinymux_direnv_show_stderr
}

def --env __tinymux_direnv_hook [] {
    if (($env.__TINYMUX_DIRENV_INSTANT_RUNNING? | default "") != "") { return }
    $env.__TINYMUX_DIRENV_INSTANT_RUNNING = "1"
    __tinymux_direnv_run_instant
    hide-env --ignore-errors __TINYMUX_DIRENV_INSTANT_RUNNING
}

export-env {
    $env.config = ($env.config? | default {})
    $env.config.hooks = ($env.config.hooks? | default {})
    $env.config.hooks.pre_prompt = (
        ($env.config.hooks.pre_prompt? | default []) | append { __tinymux_direnv_hook }
    )
    $env.config.hooks.pre_execution = (
        ($env.config.hooks.pre_execution? | default []) | append { __tinymux_direnv_hook }
    )
}
