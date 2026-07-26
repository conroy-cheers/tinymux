# Persistent Session Architecture

Tinymux owns one main PTY for the lifetime of a terminal tab. With no
auxiliary pane, main output is written directly to the outer terminal so the
terminal retains native scrolling and its normal output performance. A bounded
shadow journal advances the VT model in event-loop budgets and is fully caught
up before a split transition.

## State machine

```text
RAW -- pane.run --> SHADOW BARRIER --> COMPOSED(generation)
 ^                                         |
 +--------- IN-PLACE HANDOFF <-------------+
```

Opening a split drains ready main output, catches up the shadow model, creates
the auxiliary PTY, and resizes the main PTY to the reduced tmux-style geometry.
Tinymux then composes both panes on the outer terminal's current screen buffer.
It does not enter an alternate screen on behalf of the split.

Closing a split drains pre-resize output, destroys the auxiliary PTY, expands
the main PTY, and repaints every primary or alternate screen buffer touched by
composition. The repaint uses cursor-addressed writes inside synchronized
updates. It never replays history, emits linefeeds to manufacture native
scrollback, or waits for application-specific prompt markers. Once the main
terminal modes and screen state have been restored, future output resumes raw
passthrough.

The main application may enter or leave its own alternate screen while a split
is visible. Those application-owned switches are mirrored to the outer
terminal, and both touched buffers are reconciled before raw handoff.

Kitty graphics have the same ownership boundary. Before composition Tinymux
removes app-owned images from each outer screen using their application image
ID or image number, while retaining the decoded image in the shadow model.
Composition uses a private image-ID range and independent primary/alternate
screen caches. On close, those private images are deleted and the application
images and placements are restored under their original references before raw
passthrough resumes. The restored physical references are retained per screen
for the next ownership transition, including the distinct handling required
when an image number has multiple historical images. Implicit-ID images, which
have no stable protocol reference on the first transition, are removed by
their visible placement cell and thereafter use a remembered shadow-owned ID.

## Scrollback and host effects

Native scrollback is guaranteed in raw mode. While composed, Tinymux emits only
standard top-origin scrolling-region operations; terminals may retain those
lines in native history, but Tinymux's pane history is authoritative until the
split closes. Closing a split does not replay that history.

Main-pane BEL, title, OSC 7, and OSC 133 effects are forwarded while composed.
Auxiliary panes cannot publish host-level title, cwd, or prompt effects.

## Control API

The native surface is deliberately generic:

```text
tinymux pane run [--rows N] -- command ...
tinymux pane close GENERATION
tinymux pane status
```

There is one auxiliary slot. A busy `run` is rejected, and a stale generation
close is a successful no-op. Pane roles, replacement policies, argv inspection,
and direnv-specific lifecycle behavior are not part of the architecture. The
tmux `split-window` and `kill-pane` shim maps onto the same operations.

Malformed requests and normal busy/stale conditions are client errors. Once a
valid terminal transition begins, an inability to resize, render, or reconcile
is fatal: Tinymux performs best-effort terminal cleanup and exits nonzero rather
than continuing from an uncertain physical-terminal state.
