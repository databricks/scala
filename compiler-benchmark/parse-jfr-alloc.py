#!/usr/bin/env python3
"""Parse `jfr print --events ObjectAllocationSample` text output;
aggregate weight (allocated bytes) by class and by top allocation frame.

Usage:
    python3 parse-jfr-alloc.py <jfr-text-output>

The arg is the path to a text dump produced by:
    jfr print --events jdk.ObjectAllocationSample --stack-depth 128 \
        <profile.jfr> > /tmp/alloc.txt

`ObjectAllocationSample` is the cheap, low-overhead allocation profiler in
JDK 16+ -- enable it by adding `settings=profile` to your
`StartFlightRecording` flags (see README §6).  The sampler reports a
"weight" (estimated bytes allocated since the last sample) per stack
trace, and the totals reported here approximate per-method allocation
volume reasonably well; absolute values are noisier than wall-time but
relative ranking between sites is reliable.

Output: top 40 by `objectClass` (which type was allocated) and top 40 by
top frame (where the allocation occurred).  The first table is useful to
spot fundamental data-structure pressure (e.g. `$colon$colon`,
`Types$ClassArgsTypeRef`); the second to find specific lambda
allocation hotspots (`*$$Lambda$NNNN/0xHEX`-style frames).
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
    samples = parse(sys.argv[1])
    by_class = collections.Counter()
    by_frame = collections.Counter()
    for sm in samples:
        by_class[sm["cls"]] += sm["weight"]
        if sm["stack"]:
            by_frame[method_name(sm["stack"][0])] += sm["weight"]
    total = sum(by_class.values())
    print(f"Total weight: {total/1024/1024:.1f} MB across {len(samples)} samples\n")
    print("=== Top 40 by objectClass ===")
    for cls, w in by_class.most_common(40):
        print(f"  {w/1024/1024:8.1f} MB  {w*100/total:5.2f}%  {cls}")
    print("\n=== Top 40 by allocation site (top frame) ===")
    for frame, w in by_frame.most_common(40):
        print(f"  {w/1024/1024:8.1f} MB  {w*100/total:5.2f}%  {frame}")


if __name__ == "__main__":
    main()
