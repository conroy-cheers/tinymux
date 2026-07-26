#!/usr/bin/env python3
"""Compare raw-mode benchmark JSON against a known-good tinymux run."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_results(path: Path) -> dict[tuple[str, str, str], dict[str, Any]]:
    with path.open() as handle:
        payload = json.load(handle)
    return {
        (result["category"], result["name"], result["mode"]): result
        for result in payload["results"]
    }


def unhealthy(result: dict[str, Any]) -> bool:
    return any(sample["timed_out"] or sample["rc"] != 0 for sample in result["samples"])


def compare(
    baseline: dict[tuple[str, str, str], dict[str, Any]],
    candidate: dict[tuple[str, str, str], dict[str, Any]],
    max_throughput_regression: float,
    max_latency_regression_ms: float,
) -> tuple[list[str], list[str]]:
    reports: list[str] = []
    failures: list[str] = []
    selected = [
        key
        for key in baseline
        if key[2] == "raw" and key[0] in ("throughput", "terminal", "graphics", "latency")
    ]
    if not selected:
        return reports, ["baseline contains no raw throughput or latency results"]

    for key in sorted(selected):
        category, name, mode = key
        old = baseline[key]
        new = candidate.get(key)
        label = f"{category}/{name}/{mode}"
        if new is None:
            failures.append(f"{label}: missing from candidate")
            continue
        if unhealthy(new):
            failures.append(f"{label}: candidate timed out or exited nonzero")
            continue

        if category in ("throughput", "terminal", "graphics"):
            old_ms = float(old["median_s"]) * 1000
            new_ms = float(new["median_s"]) * 1000
            regression = new_ms / old_ms - 1
            reports.append(f"{label}: {old_ms:.1f}ms -> {new_ms:.1f}ms ({regression:+.1%})")
            if category == "throughput" and regression > max_throughput_regression:
                failures.append(
                    f"{label}: {regression:.1%} slower; limit is {max_throughput_regression:.1%}"
                )
        elif name == "cadence":
            field = "gap_max_ms"
            old_ms = float(old["extra"][field])
            new_ms = float(new["extra"][field])
            regression = new_ms - old_ms
            reports.append(f"{label}: max gap {old_ms:.1f}ms -> {new_ms:.1f}ms ({regression:+.1f}ms)")
            if regression > max_latency_regression_ms:
                failures.append(
                    f"{label}: max gap regressed {regression:.1f}ms; limit is {max_latency_regression_ms:.1f}ms"
                )
        elif name == "input-echo":
            field = "latency_max_ms"
            old_ms = float(old["extra"][field])
            new_ms = float(new["extra"][field])
            regression = new_ms - old_ms
            reports.append(f"{label}: max echo {old_ms:.1f}ms -> {new_ms:.1f}ms ({regression:+.1f}ms)")
            if regression > max_latency_regression_ms:
                failures.append(
                    f"{label}: max echo regressed {regression:.1f}ms; limit is {max_latency_regression_ms:.1f}ms"
                )

    return reports, failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-throughput-regression", type=float, default=0.05)
    parser.add_argument("--max-latency-regression-ms", type=float, default=2.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    reports, failures = compare(
        load_results(args.baseline),
        load_results(args.candidate),
        args.max_throughput_regression,
        args.max_latency_regression_ms,
    )
    for report in reports:
        print(report)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("raw-mode benchmark gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
