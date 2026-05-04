#!/usr/bin/env python3
"""Find the top callers of a given method in a JFR ExecutionSample text dump.

Usage:
    python3 find-jfr-callers.py <jfr-text-output> <target-substring> \
        [skip1,skip2,...]

The first arg is a text dump produced by:
    jfr print --events jdk.ExecutionSample --stack-depth 128 \
        <profile.jfr> > /tmp/run.txt

The second arg is a substring matched against each frame; the first frame
that contains it is treated as the "target" frame and the script reports
the first non-skipped frame above it as the caller.  The optional third
arg is a comma-separated list of substrings whose matching frames are
skipped when looking for the caller (useful to peel back through trivial
forwarders / synthetic methods).

Output: the count of samples reaching the target plus a top-N table of
callers.  Use this when `parse-jfr.py` flags a hot leaf (say
`mapConserve.loop`) and you want to know which of the dozens of
transformer call sites is responsible.
"""
import sys, re, collections


def parse(path):
    samples, current, in_stack = [], None, False
    for line in open(path):
        s = line.strip()
        if s.startswith("jdk.ExecutionSample {"):
            current = []
        elif s.startswith("jdk."):
            current = None
            in_stack = False
        elif s.startswith("stackTrace = [") and current is not None:
            in_stack = True
        elif in_stack:
            if s == "]":
                in_stack = False
            elif s == "...":
                pass
            else:
                current.append(s)
        elif s == "}":
            if current is not None:
                samples.append(current)
            current = None
    return samples


def method_name(frame):
    m = re.match(r"^([\w\.\$]+)\.([\w\$<>]+)\(", frame)
    return f"{m.group(1)}.{m.group(2)}" if m else frame[:80]


def main():
    target = sys.argv[2]
    skip = [s for s in (sys.argv[3] if len(sys.argv) > 3 else "").split(",") if s]
    samples = parse(sys.argv[1])
    callers = collections.Counter()
    total = 0
    for stk in samples:
        idx = next((i for i, f in enumerate(stk) if target in f), None)
        if idx is None:
            continue
        total += 1
        for j in range(idx + 1, min(idx + 12, len(stk))):
            name = method_name(stk[j])
            if any(s in name for s in skip):
                continue
            callers[name] += 1
            break
    print(f"Samples reaching {target!r}: {total}")
    print("Top callers (first non-skipped frame above target):")
    for name, c in callers.most_common(25):
        print(f"  {c:5d}  {name}")


if __name__ == "__main__":
    main()
