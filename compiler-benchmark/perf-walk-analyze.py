#!/usr/bin/env python3
"""Aggregate runs.tsv from perf-walk.sh into per-commit summaries and
print correlation statistics between wall-time delta and each hardware
counter delta across all commits.

Usage:
  perf-walk-analyze.py <runs.tsv> [--out-dir DIR]
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import statistics
import sys
from collections import defaultdict
from typing import Dict, List, Tuple


METRICS = [
    "wall_ms",
    "wall_total_ms",
    "wall_measured_ms",
    "cycles",
    "instructions",
    "branches",
    "branch_misses",
    "cache_misses",
    "cache_refs",
    "dtlb_load_misses",
]


def to_float(s: str) -> float:
    try:
        return float(s)
    except (TypeError, ValueError):
        return math.nan


def median(xs: List[float]) -> float:
    xs = [x for x in xs if not math.isnan(x)]
    return statistics.median(xs) if xs else math.nan


def stdev(xs: List[float]) -> float:
    xs = [x for x in xs if not math.isnan(x)]
    return statistics.pstdev(xs) if len(xs) > 1 else math.nan


def cv_pct(xs: List[float]) -> float:
    m = median(xs)
    s = stdev(xs)
    if math.isnan(m) or m == 0 or math.isnan(s):
        return math.nan
    return 100.0 * s / m


def welch_t(a: List[float], b: List[float]) -> float:
    """Two-sample Welch t (unequal variances).  Used as a rough
    significance proxy; we don't compute p-values here.
    """
    a = [x for x in a if not math.isnan(x)]
    b = [x for x in b if not math.isnan(x)]
    if len(a) < 2 or len(b) < 2:
        return math.nan
    ma, mb = statistics.mean(a), statistics.mean(b)
    va, vb = statistics.variance(a), statistics.variance(b)
    se = math.sqrt(va / len(a) + vb / len(b))
    if se == 0:
        return math.nan
    return (mb - ma) / se


def pearson(xs: List[float], ys: List[float]) -> float:
    pairs = [(x, y) for x, y in zip(xs, ys)
             if not math.isnan(x) and not math.isnan(y)]
    if len(pairs) < 3:
        return math.nan
    xs_, ys_ = zip(*pairs)
    mx, my = statistics.mean(xs_), statistics.mean(ys_)
    num = sum((x - mx) * (y - my) for x, y in pairs)
    dx = math.sqrt(sum((x - mx) ** 2 for x in xs_))
    dy = math.sqrt(sum((y - my) ** 2 for y in ys_))
    if dx == 0 or dy == 0:
        return math.nan
    return num / (dx * dy)


def spearman(xs: List[float], ys: List[float]) -> float:
    pairs = [(x, y) for x, y in zip(xs, ys)
             if not math.isnan(x) and not math.isnan(y)]
    if len(pairs) < 3:
        return math.nan
    n = len(pairs)
    xs_, ys_ = zip(*pairs)

    def ranks(vs):
        order = sorted(range(n), key=lambda i: vs[i])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and vs[order[j + 1]] == vs[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                r[order[k]] = avg
            i = j + 1
        return r

    rx, ry = ranks(xs_), ranks(ys_)
    return pearson(rx, ry)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("runs", help="runs.tsv from perf-walk.sh")
    p.add_argument("--out-dir", default=None)
    args = p.parse_args()

    runs_path = args.runs
    out_dir = args.out_dir or os.path.dirname(runs_path)
    summary_path = os.path.join(out_dir, "summary.tsv")
    md_path = os.path.join(out_dir, "summary.md")

    rows: List[dict] = []
    with open(runs_path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            rows.append(row)
    if not rows:
        print(f"no rows in {runs_path}", file=sys.stderr)
        return 1
    # Backwards compat: older runs.tsv files predate wall_measured_ms.
    # Drop it from the metric list if absent so the script still runs.
    available_metrics = [m for m in METRICS if m in reader.fieldnames]
    skipped = [m for m in METRICS if m not in reader.fieldnames]
    if skipped:
        print(f"note: missing columns ignored: {skipped}", file=sys.stderr)

    pairs: Dict[int, Dict[str, List[Dict[str, float]]]] = defaultdict(
        lambda: {"P": [], "C": []})
    pair_meta: Dict[int, Tuple[str, str]] = {}
    for row in rows:
        idx = int(row["pair_idx"])
        side = row["side"]
        pair_meta[idx] = (row["parent_short"], row["child_short"])
        rec = {m: to_float(row[m]) for m in available_metrics}
        pairs[idx][side].append(rec)

    with open(summary_path, "w") as out:
        header = ["pair", "parent", "child", "n_p", "n_c"]
        for m in available_metrics:
            header += [f"{m}_p", f"{m}_c", f"{m}_d_pct",
                       f"{m}_p_cv", f"{m}_c_cv", f"{m}_t"]
        out.write("\t".join(header) + "\n")

        commit_summary: Dict[int, Dict[str, float]] = {}
        for idx in sorted(pairs):
            ps, cs = pair_meta[idx]
            P = pairs[idx]["P"]
            C = pairs[idx]["C"]
            line = [str(idx), ps, cs, str(len(P)), str(len(C))]
            commit_row = {}
            for m in available_metrics:
                p_vals = [r[m] for r in P]
                c_vals = [r[m] for r in C]
                p_med = median(p_vals)
                c_med = median(c_vals)
                d_pct = 100.0 * (c_med / p_med - 1.0) if p_med else math.nan
                p_cv = cv_pct(p_vals)
                c_cv = cv_pct(c_vals)
                t = welch_t(p_vals, c_vals)
                line += [
                    f"{p_med:.0f}" if not math.isnan(p_med) else "NaN",
                    f"{c_med:.0f}" if not math.isnan(c_med) else "NaN",
                    f"{d_pct:+.3f}" if not math.isnan(d_pct) else "NaN",
                    f"{p_cv:.3f}" if not math.isnan(p_cv) else "NaN",
                    f"{c_cv:.3f}" if not math.isnan(c_cv) else "NaN",
                    f"{t:+.2f}" if not math.isnan(t) else "NaN",
                ]
                commit_row[f"{m}_d"] = d_pct
                commit_row[f"{m}_t"] = t
                commit_row[f"{m}_p_cv"] = p_cv
                commit_row[f"{m}_c_cv"] = c_cv
            out.write("\t".join(line) + "\n")
            commit_summary[idx] = commit_row

    print(f"per-pair summary -> {summary_path}")

    wall_d = [commit_summary[i]["wall_ms_d"] for i in sorted(commit_summary)]
    wall_t = [commit_summary[i]["wall_ms_t"] for i in sorted(commit_summary)]

    md_lines: List[str] = []
    md_lines.append(
        "# Wall-time vs hardware-counter signal across the optimization series")
    md_lines.append("")
    md_lines.append(
        "Each row is the per-pair (commit vs. its parent) "
        "delta as a percentage. Negative = improvement.\n")

    md_lines.append("## Per-pair deltas\n")
    cols = [m for m in available_metrics]
    short = {
        "wall_ms": "wall %",
        "wall_total_ms": "wall(tot) %",
        "wall_measured_ms": "wall(meas) %",
        "cycles": "cycles %",
        "instructions": "instr %",
        "branches": "branches %",
        "branch_misses": "br-miss %",
        "cache_misses": "$-miss %",
        "cache_refs": "$-ref %",
        "dtlb_load_misses": "dTLB-miss %",
    }
    head_cols = " | ".join(short[c] for c in cols)
    sep_cols = " | ".join(["--:"] * len(cols))
    md_lines.append(f"| # | parent | child | {head_cols} |")
    md_lines.append(f"| - | -- | -- | {sep_cols} |")
    for idx in sorted(commit_summary):
        r = commit_summary[idx]
        ps, cs = pair_meta[idx]

        def f(m):
            v = r.get(f"{m}_d", math.nan)
            return f"{v:+.2f}" if not math.isnan(v) else "—"

        body = " | ".join(f(c) for c in cols)
        md_lines.append(f"| {idx} | {ps[:7]} | {cs[:7]} | {body} |")

    md_lines.append("")
    md_lines.append("## Within-side noise (CV%)\n")
    md_lines.append(
        "Median across all 16 pairs of the within-side coefficient of "
        "variation (n="
        f"{statistics.median([len(pairs[i]['P']) for i in pairs])}"
        " runs per side per pair).  Lower = tighter signal.\n")
    md_lines.append("| metric | parent CV% | child CV% |")
    md_lines.append("| -- | --: | --: |")
    for m in available_metrics:
        p_cvs = [commit_summary[i][f"{m}_p_cv"]
                 for i in sorted(commit_summary)]
        c_cvs = [commit_summary[i][f"{m}_c_cv"]
                 for i in sorted(commit_summary)]
        p_cv = median(p_cvs)
        c_cv = median(c_cvs)
        md_lines.append(
            f"| {m} | {p_cv:.3f} | {c_cv:.3f} |"
            if not math.isnan(p_cv) and not math.isnan(c_cv)
            else f"| {m} | — | — |"
        )

    md_lines.append("")
    md_lines.append(
        "## Correlation of counter delta with wall-time delta\n")
    md_lines.append(
        "Across all 16 pairs.  A counter is a useful proxy for wall-time "
        "iff its delta is strongly correlated with wall-time delta. "
        "Spearman is rank-based and less sensitive to single outliers.\n")
    md_lines.append("| metric | Pearson r | Spearman ρ |")
    md_lines.append("| -- | --: | --: |")
    for m in available_metrics:
        if m == "wall_ms":
            continue
        deltas = [commit_summary[i][f"{m}_d"]
                  for i in sorted(commit_summary)]
        r = pearson(wall_d, deltas)
        rho = spearman(wall_d, deltas)
        md_lines.append(
            f"| {m} | {r:+.3f} | {rho:+.3f} |"
            if not (math.isnan(r) or math.isnan(rho))
            else f"| {m} | — | — |"
        )

    md_lines.append("")
    md_lines.append("## Sign agreement\n")
    md_lines.append(
        "Fraction of the 16 pairs where the counter's sign matches "
        "wall-time's sign.  A counter that 'predicts' wins should be "
        "above 50%; well above means it could replace wall-time as a "
        "go/no-go signal.\n")
    md_lines.append("| metric | agree / 16 | % |")
    md_lines.append("| -- | --: | --: |")
    for m in available_metrics:
        if m == "wall_ms":
            continue
        deltas = [commit_summary[i][f"{m}_d"]
                  for i in sorted(commit_summary)]
        agree = 0
        total = 0
        for w, d in zip(wall_d, deltas):
            if math.isnan(w) or math.isnan(d):
                continue
            if (w == 0) ^ (d == 0):
                continue
            total += 1
            if (w < 0 and d < 0) or (w > 0 and d > 0) or (w == 0 and d == 0):
                agree += 1
        if total == 0:
            md_lines.append(f"| {m} | 0/0 | — |")
        else:
            md_lines.append(
                f"| {m} | {agree}/{total} | {100.0 * agree / total:.1f} |")

    md_lines.append("")

    with open(md_path, "w") as f:
        f.write("\n".join(md_lines) + "\n")
    print(f"summary markdown -> {md_path}")
    print()
    print("\n".join(md_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
