tinymux-enter() {
    _tinymux_state=$(mktemp -d "${TMPDIR:-/tmp}/tinymux-handoff.XXXXXX") || return 1
    command tinymux handoff-capture --state "$_tinymux_state" --slot baseline || {
        rm -rf -- "$_tinymux_state"
        return 1
    }
    mkdir -p "$_tinymux_state/zdotdir" || {
        rm -rf -- "$_tinymux_state"
        return 1
    }
    cat >"$_tinymux_state/zdotdir/.zshrc" <<'TINYMUX_ZSHRC'
if [ -n "$TINYMUX_PARENT_ZDOTDIR" ] && [ -r "$TINYMUX_PARENT_ZDOTDIR/.zshrc" ]; then source "$TINYMUX_PARENT_ZDOTDIR/.zshrc"; fi
tinymux-exit() {
    command tinymux handoff-capture --state "$TINYMUX_HANDOFF_STATE" --slot result
    exit
}
TINYMUX_ZSHRC
    TINYMUX_PARENT_ZDOTDIR="${ZDOTDIR:-$HOME}" command tinymux --seamless --handoff-state "$_tinymux_state" -- env ZDOTDIR="$_tinymux_state/zdotdir" zsh -i
    _tinymux_code=$?
    eval "$(command tinymux handoff-apply --shell sh --state "$_tinymux_state")"
    rm -rf -- "$_tinymux_state"
    return "$_tinymux_code"
}
