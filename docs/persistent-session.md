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

Mouse tracking and mouse encoding are each effective-state families, even
though applications manipulate them through separate DEC private mode bits.
During handoff Tinymux resets each family and then enables only the effective
state recorded by the VT model. This avoids changing the selected protocol when
an application, such as Crossterm, has enabled more than one family member in a
deliberate order.

The main application may enter or leave its own alternate screen while a split
is visible. Those application-owned switches are mirrored to the outer
terminal, and both touched buffers are reconciled before raw handoff.

Graphics cross a protocol-normalization boundary before raw passthrough or VT
modeling. Kitty file, temporary-file, and shared-memory transmissions are read
once and re-emitted as bounded direct Kitty pixel chunks. Static iTerm2 inline
PNG/JPEG and Sixel images are decoded into the same direct RGBA representation;
iTerm2 sizing/aspect options and the supported Sixel cursor, palette,
transparency, and raster modes are converted to explicit Kitty placement and
cursor operations. This gives the outer terminal and the shadow model identical
bytes, placement, and cursor semantics. Direct Kitty transfers stream through
without whole-image buffering, while static virtual placements are modeled and
replayed through the compositor.

Every completed graphics command records an ordered, screen-local ownership
effect. Explicitly referenced static images can be removed and restored
precisely. Fully modeled static images without an application reference mark
their active screen for an outer-only clear while retaining their decoded
shadow pixels. Native-only operations such as animations and relative
placements remain available during unsplit raw passthrough, but require both
outer and shadow graphics to be cleared before composition. Malformed,
oversized, or otherwise unsafe graphics fail closed immediately by deleting
images rather than creating an outer-terminal layer Tinymux cannot later
reconcile. Non-image OSC, DCS, and APC strings remain byte-for-byte passthrough.

Before composition Tinymux checks both application screen buffers. It emits a
delete-all safety barrier only for a screen containing raw graphics that cannot
be addressed precisely. If those graphics are fully modeled, the barrier is
outer-only and composition immediately redraws the retained pixels and
placements. If the screen contains native-only graphics, Tinymux feeds the same
deletion into the shadow model so unsupported state cannot be resurrected.
Precisely referenced app-owned images are instead removed using their
application image ID or image number while retaining decoded pixels in the
shadow model. Composition uses a private image-ID range and independent
primary/alternate screen caches. On close, those private images are deleted and
the application images and placements are restored before raw passthrough
resumes. An initially implicit image is restored under its shadow-assigned ID,
making subsequent ownership transitions precise. Existing physical references
are retained per screen, including the distinct handling required when an image
number has multiple historical images.

## Scrollback and host effects

Native scrollback is guaranteed in raw mode. While composed, Tinymux emits only
standard top-origin scrolling-region operations; terminals may retain those
lines in native history, but Tinymux's pane history is authoritative until the
split closes. Closing a split does not replay that history.

Main-pane BEL, title, OSC 7, and OSC 133 effects are forwarded while composed.
Auxiliary panes cannot publish host-level title, cwd, or prompt effects.

Raw passthrough distinguishes display traffic from terminal control-plane
transactions. Printable output and ordinary terminal commands still go
directly to the outer terminal. Queries that would generate terminal input are
answered from the main pane's shadow model, and in-band size-report mode 2048
is virtualized per pane rather than enabled on the outer terminal. Replies are
written only while the requesting foreground process group still owns a
non-echoing pane terminal.

Unsolicited outer-terminal size reports are discarded outside bracketed paste,
so a delayed reply cannot become shell input. Parser and library diagnostics
never write to the owned terminal. Set `TINYMUX_LOG` to an explicit file path
to retain those diagnostics; otherwise they are silent.

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
narrow Kitty remote-control `launch` shim maps onto `pane run` with a ten-row
bottom split, retained main-pane focus, and automatic close when the launched
process exits.

Malformed requests and normal busy/stale conditions are client errors. Once a
valid terminal transition begins, an inability to resize, render, or reconcile
is fatal: Tinymux performs best-effort terminal cleanup and exits nonzero rather
than continuing from an uncertain physical-terminal state.
