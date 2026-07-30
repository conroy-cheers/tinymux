# Terminal architecture

Tinymux has one authoritative terminal model per pane. PTY output always enters
that model before composed output is produced. The model is Ghostty's
`ghostty-vt` module, pinned by revision in `build.zig`, `build.zig.zon`, and
`flake.nix`; `tinymux --version` prints the compiled revision.

## Model boundary

`Pane` owns the PTY, VT parser, and terminal state. Every parser action checks
that Ghostty's cached cursor row and cell still agree with its authoritative
page pin before and after applying the action. A mismatch is repaired with
`cursorReload` and logged only through the opt-in diagnostic logger. This
per-action boundary is important: checking once per PTY read is insufficient
because one read can contain many actions.

Rows cached by the compositor are identified by page pointer, page generation,
and row offset. The generation prevents a recycled page allocation from being
mistaken for unchanged terminal content.

## Rendering contract

Raw mode remains byte-for-byte passthrough. Composed mode is different: it is
an absolute repaint of model snapshots. It does not forward child bytes
directly and it does not issue physical outer-terminal scroll commands.
Changed rows are painted with absolute cursor positions inside a synchronized
update. This makes correctness independent of predicted scrolls, PTY read
boundaries, alternate-screen transitions, and bottom-row updates.

The render scheduler coalesces while a PTY remains continuously readable, with
a bounded 50 ms maximum between frames. This avoids repeatedly formatting
intermediate snapshots during bulk output without starving a continuously
streaming application or delaying small interactive updates.

The regression oracle in `tests/spec/tinymux_contract.py` emulates the outer
terminal and verifies that a LazyGit-style loading indicator repeatedly drawn
on the last pane row leaves the top-row sentinel in place.

## Diagnostics

`TINYMUX_LOG=/path` records internal diagnostics without writing them into the
owned terminal.

`TINYMUX_VT_TRACE=/path` records exact PTY feed boundaries and resize events in
a bounded binary trace (magic `TMXVT1`, maximum 64 MiB, mode 0600). PTY output
can contain commands, paths, tokens, or other secrets; traces must be treated
as sensitive and should not be attached publicly without inspection.
