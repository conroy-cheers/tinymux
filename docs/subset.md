# tinymux v1 Subset Specification

This document is the normative v1 contract for tinymux. Behavior marked
`REQUIRED` is part of the product surface and must be covered by the required
parity suite. Behavior marked `EXTENDED` may be tested for tmux compatibility
but is not required for v1.

## Layout

- `LAYOUT-001` REQUIRED: tinymux presents exactly two panes.
- `LAYOUT-002` REQUIRED: the main pane is always above the secondary pane.
- `LAYOUT-003` REQUIRED: the two panes are separated by one horizontal border.
- `LAYOUT-004` REQUIRED: the secondary pane defaults to 9 rows of content.
- `LAYOUT-005` REQUIRED: on small terminals, tinymux clamps pane heights to keep
  both panes visible whenever the terminal can fit one main row, one border row,
  and one secondary row.
- `LAYOUT-006` REQUIRED: v1 does not support creating, destroying, rearranging,
  or interactively resizing panes.

## Startup and Commands

- `CLI-001` REQUIRED: tinymux starts with `tinymux --main <cmd> --secondary <cmd>`.
- `CLI-002` REQUIRED: missing `--main` or `--secondary` is a usage error. tinymux
  exits nonzero and does not start the terminal UI.
- `CLI-003` REQUIRED: each command string is executed as `$SHELL -lc <cmd>`.
- `CLI-004` REQUIRED: if `$SHELL` is unset or empty, tinymux may use `/bin/sh`.
- `CLI-005` REQUIRED: both commands run immediately when the UI starts.

## Input and Focus

- `INPUT-001` REQUIRED: only one pane is focused at a time.
- `INPUT-002` REQUIRED: ordinary input bytes are forwarded unchanged to the
  focused pane.
- `INPUT-003` REQUIRED: `Ctrl-B Up` focuses the main pane.
- `INPUT-004` REQUIRED: `Ctrl-B Down` focuses the secondary pane.
- `INPUT-005` REQUIRED: no other tmux command prefix behavior is required in v1.

## Pane Lifecycle

- `LIFE-001` REQUIRED: if either pane's child process exits, the pane remains
  visible in an exited state.
- `LIFE-002` REQUIRED: after one pane exits, the other pane remains usable.
- `LIFE-003` REQUIRED: v1 does not require respawning exited pane commands.

## Terminal Behavior

- `TERM-001` REQUIRED: UTF-8 text is decoded and rendered consistently with tmux
  for the supported terminal surface.
- `TERM-002` REQUIRED: line wrapping and cursor position match tmux for ordinary
  shell output.
- `TERM-003` REQUIRED: `Ctrl-C` and `Ctrl-D` are forwarded to the focused pane.
- `TERM-004` REQUIRED: terminal resize events update pane geometry and propagate
  `SIGWINCH`/terminal size changes to child processes.
- `TERM-005` REQUIRED: raw mode input is forwarded to the focused pane without
  line-editing transformations by tinymux.
- `TERM-006` REQUIRED: alternate screen enter/exit behavior is supported inside
  panes.
- `TERM-007` REQUIRED: bracketed paste sequences are forwarded correctly.
- `TERM-008` REQUIRED: ANSI text attributes and 256-color/truecolor SGR output
  render consistently with tmux.
- `TERM-009` REQUIRED: mouse reporting sequences are forwarded consistently with
  tmux for focused terminal applications.
- `TERM-010` REQUIRED: sustained output and resize churn must not corrupt pane
  contents or route output to the wrong pane.

## Extended Compatibility

- `EXT-001` EXTENDED: copy-mode scrollback is not part of v1 required behavior.
- `EXT-002` EXTENDED: tmux sessions, windows, additional panes, arbitrary splits,
  command prompts, status bars, tmux configuration files, and tmux plugin
  compatibility are not part of v1 required behavior.
- `EXT-003` EXTENDED: exact outer-terminal private mode and title-protocol parity
  with tmux is not required unless it affects the visible pane behavior above.
