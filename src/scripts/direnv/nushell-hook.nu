# tinymux-direnv-instant hook for Nushell.
def __tinymux_direnv_instant_bin [] {
    $env.TINYMUX_DIRENV_INSTANT_BIN? | default "direnv-instant"
}

def __tinymux_direnv_inside_tinymux [] {
    (($env.TINYMUX? | default "") != "") or (($env.TINYMUX_SEAMLESS? | default "") != "")
}

def __tinymux_direnv_other_mux [] {
    if (__tinymux_direnv_inside_tinymux) { return false }
    (($env.TMUX? | default "") != "") or (($env.ZELLIJ? | default "") != "") or (($env.KITTY_LISTEN_ON? | default "") != "") or (($env.TERM_PROGRAM? | default "") == "WezTerm")
}

def __tinymux_direnv_find_envrc [] {
    mut dir = (pwd)
    loop {
        if (($dir | path join ".envrc") | path exists) { return $dir }
        let parent = ($dir | path dirname)
        if $parent == $dir { return "" }
        $dir = $parent
    }
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
    let cached = (__tinymux_direnv_load_file ($env.__DIRENV_INSTANT_ENV_FILE? | default ""))
    let bin = (__tinymux_direnv_instant_bin)
    let raw = (run-external $bin start | str trim)
    let state = if ($raw | is-empty) { {} } else { $raw | from json }
    let next_file = ($state.__DIRENV_INSTANT_ENV_FILE? | default ($env.__DIRENV_INSTANT_ENV_FILE? | default ""))
    let fresh = (__tinymux_direnv_load_file $next_file)
    __tinymux_direnv_apply ($cached | merge $state | merge $fresh)
    __tinymux_direnv_show_stderr
}

def --env __tinymux_direnv_enter_root [root: string] {
    let state = (^mktemp -d -t tinymux-direnv.XXXXXX | str trim)
    ^tinymux handoff-capture --state $state --slot baseline
    if $env.LAST_EXIT_CODE != 0 {
        ^rm -rf -- $state
        return
    }
    let init = ($state | path join "child.nu")
    ^tinymux-direnv-instant child-init nu | save --force $init
    with-env { TINYMUX_DIRENV_ROOT: $root, TINYMUX_DIRENV_STATE: $state } {
        ^tinymux --seamless --handoff-state $state -- nu --no-history -i -e $"source ($init)"
    }
    let code = $env.LAST_EXIT_CODE
    let reason_path = ($state | path join "exit_reason")
    let reason = if ($reason_path | path exists) { open --raw $reason_path | str trim } else { "" }
    if $reason == "left-root" {
        let applied = (^tinymux handoff-apply --shell nu --state $state | from json)
        if $applied.cwd != null { cd $applied.cwd }
        load-env $applied.env
        ^rm -rf -- $state
        return
    }
    let started = (($state | path join "child_started") | path exists)
    ^rm -rf -- $state
    if $started { exit $code }
}

def --env __tinymux_direnv_maybe_enter [] {
    if (($env.TINYMUX_DIRENV_DISABLE? | default "0") == "1") { return }
    if (__tinymux_direnv_inside_tinymux) { return }
    if (__tinymux_direnv_other_mux) { return }
    let root = (__tinymux_direnv_find_envrc)
    if not ($root | is-empty) { __tinymux_direnv_enter_root $root }
}

def --env __tinymux_direnv_hook [] {
    if (($env.__TINYMUX_DIRENV_INSTANT_RUNNING? | default "") != "") { return }
    $env.__TINYMUX_DIRENV_INSTANT_RUNNING = "1"
    __tinymux_direnv_maybe_enter
    hide-env --ignore-errors __TINYMUX_DIRENV_INSTANT_RUNNING
    __tinymux_direnv_run_instant
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
