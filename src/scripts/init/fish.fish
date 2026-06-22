function tinymux-enter
    set -l state (mktemp -d -t tinymux-handoff.XXXXXX); or return 1
    command tinymux handoff-capture --state "$state" --slot baseline
    if test $status -ne 0
        rm -rf -- "$state"
        return 1
    end
    command tinymux --seamless --handoff-state "$state" -- fish -i -C 'function tinymux-exit; command tinymux handoff-capture --state "$TINYMUX_HANDOFF_STATE" --slot result; exit; end'
    set -l code $status
    source (command tinymux handoff-apply --shell fish --state "$state" | psub)
    rm -rf -- "$state"
    return $code
end
