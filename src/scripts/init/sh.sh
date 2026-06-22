tinymux-enter() {
    _tinymux_state=$(mktemp -d "${TMPDIR:-/tmp}/tinymux-handoff.XXXXXX") || return 1
    command tinymux handoff-capture --state "$_tinymux_state" --slot baseline || {
        rm -rf -- "$_tinymux_state"
        return 1
    }
    cat >"$_tinymux_state/shenv" <<'TINYMUX_SHENV'
tinymux-exit() {
    command tinymux handoff-capture --state "$TINYMUX_HANDOFF_STATE" --slot result
    exit
}
TINYMUX_SHENV
    ENV="$_tinymux_state/shenv" command tinymux --seamless --handoff-state "$_tinymux_state" -- sh -i
    _tinymux_code=$?
    eval "$(command tinymux handoff-apply --shell sh --state "$_tinymux_state")"
    rm -rf -- "$_tinymux_state"
    return "$_tinymux_code"
}
