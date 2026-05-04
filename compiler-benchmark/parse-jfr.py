#!/usr/bin/env python3
"""Parse `jfr print --events ExecutionSample` text output; aggregate self/total time.

Usage:
    python3 parse-jfr.py <jfr-text-output> [STATE1,STATE2,...]

The first arg is the path to a text dump produced by:
    jfr print --events jdk.ExecutionSample <profile.jfr> > /tmp/run.txt
The optional second arg restricts the aggregation to samples in the given
JFR thread states (e.g. RUNNABLE).  When omitted, all states are included.
"""
import sys, re, collections


def parse(path, include_states=None):
    samples, current, in_stack = [], None, False
    for line in open(path):
        s = line.strip()
        if s.startswith("jdk.ExecutionSample {"):
            current = {"stack": []}
        elif s.startswith("jdk."):
            # Other jdk.* events (e.g. ObjectAllocationSample) when both event
            # types share a recording.  Skip until the next ExecutionSample.
            current = None
            in_stack = False
        elif current is None:
            pass
        elif s.startswith("state ="):
            current["state"] = s.split("=", 1)[1].strip().strip('"')
        elif s.startswith("stackTrace = ["):
            in_stack = True
        elif in_stack:
            if s == "]":
                in_stack = False
            elif s == "...":
                pass
            else:
                current["stack"].append(s)
        elif s == "}":
            if include_states is None or current.get("state") in include_states:
                samples.append(current)
            current = None
    return samples


def method_name(frame):
    m = re.match(r"^([\w\.\$]+)\.([\w\$<>]+)\(", frame)
    return f"{m.group(1)}.{m.group(2)}" if m else frame[:80]


def main():
    samples = parse(sys.argv[1],
                    set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None)
    print(f"Total samples: {len(samples)}", file=sys.stderr)
    self_c, total_c = collections.Counter(), collections.Counter()
    for s in samples:
        if not s["stack"]:
            continue
        self_c[method_name(s["stack"][0])] += 1
        for f in {method_name(f) for f in s["stack"]}:
            total_c[f] += 1
    total = sum(self_c.values())
    print("\n=== Top 40 methods by SELF time ===")
    for name, c in self_c.most_common(40):
        print(f"{c:6d}  {100.0*c/total:5.1f}%  {name}")
    print("\n=== Top 40 methods by TOTAL time (inclusive) ===")
    for name, c in total_c.most_common(40):
        print(f"{c:6d}  {100.0*c/total:5.1f}%  {name}")


if __name__ == "__main__":
    main()
