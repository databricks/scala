#!/usr/bin/env python3
"""Find callers of a given allocation site in a JFR ObjectAllocationSample
text dump.

Usage:
    python3 find-jfr-alloc-callers.py <jfr-text-output> <target-substring> \
        [depth=1]

The first arg is a text dump produced by:
    jfr print --events jdk.ObjectAllocationSample --stack-depth 128 \
        <profile.jfr> > /tmp/alloc.txt

The second arg is a substring matched against the *top frame* of each
allocation sample (i.e. the actual `new`-site).  The optional third arg
is the number of frames to skip above the top frame before identifying
the caller (default 1 = the immediate caller; use 2..3 to peel through
a thin wrapper such as a `<init>` chain or a `Function0.apply`).

Output: total weight reaching the target, the top object classes
allocated at that site, and the top calling methods at the requested
depth.  Use this when `parse-jfr-alloc.py` flags a class
(e.g. `Trees$$Lambda$691/...`, `scala.Some`) but doesn't tell you which
caller is driving the allocation.
"""
import sys, re, collections


_BYTES_RE = re.compile(r"weight = ([0-9.]+) (MB|kB|bytes)")


def to_bytes(amount, unit):
    amount = float(amount)
    if unit == "MB":
        return int(amount * 1024 * 1024)
    if unit == "kB":
        return int(amount * 1024)
    return int(amount)


def parse(path):
    samples, current, in_stack = [], None, False
    for line in open(path):
        s = line.strip()
        if s.startswith("jdk.ObjectAllocationSample {"):
            current = {"cls": None, "weight": 0, "stack": []}
        elif s.startswith("jdk."):
            current = None
            in_stack = False
        elif s.startswith("objectClass = ") and current is not None:
            current["cls"] = s.split(" = ", 1)[1].split(" (")[0]
        elif s.startswith("stackTrace = [") and current is not None:
            in_stack = True
        elif in_stack:
            if s == "]":
                in_stack = False
            elif s == "...":
                pass
            else:
                current["stack"].append(s)
        elif s == "}":
            if current is not None:
                samples.append(current)
            current = None
        elif current is not None:
            m = _BYTES_RE.search(s)
            if m:
                current["weight"] = to_bytes(m.group(1), m.group(2))
    return samples


def method_name(frame):
    m = re.match(r"^([\w\.\$]+)\.([\w\$<>]+)\(", frame)
    return f"{m.group(1)}.{m.group(2)}" if m else frame[:80]


def main():
    target = sys.argv[2]
    depth = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    samples = [s for s in parse(sys.argv[1])
               if s["stack"] and target in s["stack"][0]]
    by_cls = collections.Counter()
    by_caller = collections.Counter()
    for sm in samples:
        by_cls[sm["cls"]] += sm["weight"]
        if depth < len(sm["stack"]):
            by_caller[method_name(sm["stack"][depth])] += sm["weight"]
    total = sum(s["weight"] for s in samples)
    print(f"Total allocs at sites containing {target!r}: "
          f"{total/1024/1024:.1f} MB across {len(samples)} samples")
    print("\n=== Classes allocated ===")
    for cls, w in by_cls.most_common(10):
        print(f"  {w/1024/1024:8.1f} MB  {cls}")
    print(f"\n=== Top callers ({depth} frame{'s' if depth > 1 else ''} above) ===")
    for name, w in by_caller.most_common(20):
        print(f"  {w/1024/1024:8.1f} MB  {name}")


if __name__ == "__main__":
    main()
