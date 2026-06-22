tinymux-enter() {
    _tinymux_state=$(mktemp -d "${TMPDIR:-/tmp}/tinymux-handoff.XXXXXX") || return 1
    command tinymux handoff-capture --state "$_tinymux_state" --slot baseline || {
        rm -rf -- "$_tinymux_state"
        return 1
    }
    cat >"$_tinymux_state/bashrc" <<'TINYMUX_BASHRC'
if [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
tinymux-exit() {
    command tinymux handoff-capture --state "$TINYMUX_HANDOFF_STATE" --slot result
    exit
}
TINYMUX_BASHRC
    command tinymux --seamless --handoff-state "$_tinymux_state" -- bash --rcfile "$_tinymux_state/bashrc" -i
    _tinymux_code=$?
    eval "$(command tinymux handoff-apply --shell sh --state "$_tinymux_state")"
    rm -rf -- "$_tinymux_state"
    return "$_tinymux_code"
}
