# tinymux Benchmarks

The benchmark suite lives at `tests/benchmarks/tinymux_bench.py` and is exposed
through Zig build steps:

```sh
zig build bench
zig build bench-full
```

`bench` runs a quick profile suitable for iteration. `bench-full` increases the
throughput payload and sample count for slower, more stable measurements.

The suite compares these execution modes when available:

- `direct`: run the child command directly under the benchmark PTY.
- `raw`: run the child through `tinymux --`, with no split compositor.
- `split`: run the child in the main pane with a live sleeping split pane.
- `tmux-split`: run the same shape through tmux when `tmux` is on `PATH`.

The default mode set is `auto`, which skips tmux modes if tmux is unavailable.
Use `--modes direct,raw,split` or `--modes split,tmux-split` to choose an exact
set.

## Workloads

The command workloads are:

- `bulk-plain`: line-oriented plain output, expected to exercise the scroll
  fast path.
- `bulk-ansi`: SGR-heavy output with color resets on every line.
- `wide-wrap`: long wrapped lines that stress row-cache and viewport pin churn.
- `alt-screen`: alternate-screen enter, repaint, clear, and exit churn.
- `kitty-placement`: Kitty graphics upload and placement refresh behavior.

The interactive workloads are:

- `cadence`: small flushed writes with 8 ms spacing, reporting observed gaps.
- `input-echo`: parent input to child line echo round-trip.
- `resize-storm`: repeated `TIOCSWINSZ` changes while the UI is live.

Each result reports elapsed time plus compositor counters:

- `frames`: synchronized-update frames emitted by tinymux.
- `scrolls`: `CSI S` scroll-region operations emitted to the outer terminal.
- `place`: Kitty placement operations.
- `delp`: Kitty placement deletion operations.

Frame count alone is not enough to judge performance. For scroll-heavy output,
use `scrolls` with elapsed time to distinguish the fast path from repaint churn.

## Output Files

The suite can write JSON and Markdown reports:

```sh
zig build bench -- --json target/bench/quick.json --markdown target/bench/quick.md
zig build bench-full -- --json target/bench/full.json
```

The JSON schema includes per-sample metrics, environment metadata, ratios, and
latency distributions. It is intended to be checked into benchmark artifacts or
compared by local scripts, not used as a stable public API.

## Threshold Mode

Thresholds are opt-in because benchmark machines vary:

```sh
zig build bench -- --assert-thresholds
```

Useful knobs:

- `--max-raw-direct-ratio`: max `raw / direct` median ratio.
- `--max-split-raw-ratio`: max `split / raw` median ratio.
- `--min-split-scrolls`: minimum scroll fast-path count for throughput cases.
- `--max-cadence-gap-ms`: max observed gap for the cadence workload.
- `--max-echo-latency-ms`: max parent-input to child-echo latency.

The ratio and minimum-scroll checks are disabled unless their flags are set,
because they should be calibrated from a known-good run on the same machine.
Timeouts, nonzero exits, cadence, and echo latency are checked whenever
`--assert-thresholds` is enabled.

Use threshold mode for local regression detection after recording a known-good
baseline on the same machine.

## Before/After Raw-Mode Gate

Architectural changes to the raw path should be measured against the previous
binary on the same machine. Record both runs with identical full-profile
arguments, then compare them:

```sh
python3 tests/benchmarks/tinymux_bench.py --tinymux ./tinymux-before \
  --profile full --modes raw --json /tmp/tinymux-before.json
python3 tests/benchmarks/tinymux_bench.py --tinymux ./tinymux-after \
  --profile full --modes raw --json /tmp/tinymux-after.json
python3 tests/benchmarks/compare_raw.py \
  /tmp/tinymux-before.json /tmp/tinymux-after.json
```

The gate rejects a raw throughput median more than 5% slower than baseline, or
a worst cadence gap/input-echo latency more than 2 ms above baseline. Both JSON
files must contain the same raw workloads; missing candidate results also fail.
