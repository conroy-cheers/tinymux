def --env tinymux-enter [] {
    let state = (^mktemp -d -t tinymux-handoff.XXXXXX | str trim)
    ^tinymux handoff-capture --state $state --slot baseline
    if $env.LAST_EXIT_CODE != 0 {
        ^rm -rf -- $state
        return
    }
    ^tinymux --seamless --handoff-state $state -- nu -i -e '$env.config.show_banner = false; def tinymux-exit [] { ^tinymux handoff-capture --state $env.TINYMUX_HANDOFF_STATE --slot result; exit }'
    let code = $env.LAST_EXIT_CODE
    let applied = (^tinymux handoff-apply --shell nu --state $state | from json)
    if $applied.cwd != null {
        cd $applied.cwd
    }
    load-env $applied.env
    ^rm -rf -- $state
}
