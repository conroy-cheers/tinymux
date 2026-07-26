# tinymux v1 Subset Specification

This document is the normative v1 contract for tinymux. Behavior marked
`REQUIRED` is part of the product surface and must be covered by the required
parity suite. Behavior marked `EXTENDED` may be tested for tmux compatibility
but is not required for v1.

The fixed two-pane CLI described below is the original v1 surface. Persistent
`tinymux session` operation starts with one raw-passthrough main pane and creates
one auxiliary pane through the control API. Its composition and handoff
contract is defined in `persistent-session.md`.

## Layout

- `LAYOUT-001` REQUIRED: tinymux starts with exactly two panes.
- `LAYOUT-002` REQUIRED: the main pane is always above the secondary pane.
- `LAYOUT-003` REQUIRED: while both panes are alive, the two panes are
  separated by one horizontal border.
- `LAYOUT-004` REQUIRED: the secondary pane defaults to 9 rows of content.
- `LAYOUT-005` REQUIRED: on small terminals, tinymux clamps pane heights to keep
  both live panes visible whenever the terminal can fit one main row, one border
  row, and one secondary row.
- `LAYOUT-006` REQUIRED: v1 does not support creating, rearranging, or
  interactively resizing panes. Panes are destroyed only when their child
  process exits.

## Startup and Commands

- `CLI-001` REQUIRED: tinymux starts with `tinymux --main <cmd> --secondary <cmd>`.
- `CLI-002` REQUIRED: missing `--main` or `--secondary` is a usage error. tinymux
  exits nonzero and does not start the terminal UI.
- `CLI-003` REQUIRED: each command string is executed as `$SHELL -lc <cmd>`.
- `CLI-004` REQUIRED: if `$SHELL` is unset or empty, tinymux may use `/bin/sh`.
- `CLI-005` REQUIRED: both commands run immediately when the UI starts.
- `CLI-006` REQUIRED: `--terminal-profile <TERM>` selects the `TERM` value
  advertised to pane processes. The default is `auto`.

## Input and Focus

- `INPUT-001` REQUIRED: only one pane is focused at a time.
- `INPUT-002` REQUIRED: ordinary input bytes are forwarded unchanged to the
  focused pane.
- `INPUT-003` REQUIRED: `Ctrl-B Up` focuses the main pane.
- `INPUT-004` REQUIRED: `Ctrl-B Down` focuses the secondary pane.
- `INPUT-005` REQUIRED: no other tmux command prefix behavior is required in v1.

## Pane Lifecycle

- `LIFE-001` REQUIRED: if either pane's child process exits, that pane is
  removed from the layout.
- `LIFE-002` REQUIRED: after one pane exits, the other pane remains usable and
  expands to the full terminal.
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
- `TERM-011` REQUIRED: both panes retain scrollback and can be scrolled without
  leaking wheel input to child shells when mouse reporting is disabled.
- `TERM-012` REQUIRED for persistent sessions: opening or closing an auxiliary
  pane does not create or destroy an outer alternate screen for that pane;
  application-owned primary/alternate transitions remain mirrored.
- `TERM-013` REQUIRED for persistent sessions: closing an auxiliary pane uses
  cursor-addressed reconciliation and does not replay pane history or emit
  linefeeds to manufacture outer scrollback.

## Terminal Profiles

- `PROFILE-001` REQUIRED: `--terminal-profile auto` inspects the outer
  terminal's `$TERM` and advertises the richest common terminfo profile that is
  both supported by the outer terminal and implemented by tinymux.
- `PROFILE-002` REQUIRED: tinymux does not translate between incompatible
  terminal protocols. A forced profile is a startup error if the outer terminal
  does not advertise the required features.
- `PROFILE-003` REQUIRED: a forced profile is a startup error if it requires
  protocol behavior that tinymux does not emulate yet.
- `PROFILE-004` REQUIRED: common profiles include the vt100/ansi/linux,
  xterm/xterm-256color/xterm-direct, screen, tmux, alacritty, foot, wezterm,
  xterm-kitty, xterm-ghostty, rio, contour, st, rxvt, putty, gnome, konsole,
  iTerm2, vte, and cygwin families.
- `PROFILE-005` REQUIRED: pane processes inherit the parent terminfo search path
  so host-specific terminfo entries remain discoverable inside panes.
- `PROFILE-006` REQUIRED: xterm-kitty and xterm-ghostty profiles remain
  available in `auto` mode when the outer terminal advertises their required
  protocols, including synchronized updates, the kitty keyboard protocol, and
  kitty graphics passthrough.
- `PROFILE-007` EXPERIMENTAL: `--experimental-bottom-primary` may advertise
  richer host protocols to the secondary pane while downgrading the main pane to
  a non-graphics xterm-compatible profile. Secondary-pane output is interposed
  so full-screen commands are localized to the lower pane where practical.

## Extended Compatibility

- `EXT-001` EXTENDED: full tmux copy-mode selection, search, and buffer commands
  are not part of v1 required behavior.
- `EXT-002` EXTENDED: tmux sessions, windows, additional panes, arbitrary splits,
  command prompts, status bars, tmux configuration files, and tmux plugin
  compatibility are not part of v1 required behavior.
- `EXT-003` EXTENDED: exact outer-terminal private mode and title-protocol parity
  with tmux is not required unless it affects the visible pane behavior above.
- `EXT-004` EXTENDED: experimental bottom-primary mode does not guarantee image
  persistence across host-terminal resize; resize behavior is delegated to the
  host terminal and the pane application.
