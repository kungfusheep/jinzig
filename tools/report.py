"""report turns go-format benchmark output into a markdown comparison of medians.

usage: python3 tools/report.py go.txt interpreted.txt fused.txt
"""

import re
import statistics
import sys

MISMATCH = re.compile(r"^Benchmark(\S+)\tMISMATCH")
LINE = re.compile(r"^Benchmark(\S+?)(?:-\d+)?\s+\d+\s+([\d.]+) ns/op\s+(\d+) B/op\s+(\d+) allocs/op")

# (benchmark, stdlib baseline) pairs, in jingo_test.go order
PAIRS = [
    ("Unicode", "UnicodeStdLib"),
    ("UnicodeLarge", "UnicodeLargeStdLib"),
    ("Time", "TimeStdLib"),
    ("Slice", "SliceStdLib"),
    ("SliceEscape", "SliceStdLib"),
    ("Json", "StdJson"),
    ("SmallPayload", "SmallPayloadStdLib"),
    ("LargePayload", "LargePayloadStdLib"),
]


mismatched = set()


def load(path):
    runs = {}
    with open(path) as f:
        for line in f:
            mm = MISMATCH.match(line)
            if mm:
                mismatched.add(mm[1])
                continue
            m = LINE.match(line.strip())
            if m:
                runs.setdefault(m[1], []).append((float(m[2]), int(m[3]), int(m[4])))
    return {
        k: (statistics.median(r[0] for r in v), (max(r[0] for r in v) - min(r[0] for r in v)) / statistics.median(r[0] for r in v) * 50, v[-1][1], v[-1][2], len(v))
        for k, v in runs.items()
    }


def fmt(ns):
    return f"{ns:,.1f}" if ns < 100 else f"{ns:,.0f}"


def zig_table(interp, fused, suite, rows, libs, title):
    print(f"\n### {title}\n")
    print("Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to")
    print("jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express")
    print("the payload (no custom-serialization hook, or no single-item pointer support). \u2717 = wrong output, not timed.\n")
    print("| Payload | jinzig fused | jinzig interp | " + " | ".join(libs) + " | fastest other | fused lead |")
    print("| --- | ---: | ---: | " + " | ".join("---:" for _ in libs) + " | --- | ---: |")
    for r in rows:
        ji = interp.get(f"{suite}/{r}/jinzig")
        jf = fused.get(f"{suite}/{r}/jinzig")
        cells, timed = [], {}
        for l in libs:
            key = f"{suite}/{r}/{l}"
            if key in mismatched:
                cells.append("\u2717")
            elif key in fused:
                cells.append(fmt(fused[key][0]))
                timed[l] = fused[key][0]
            else:
                cells.append("n/a")
        best = min(timed, key=timed.get)
        print(f"| {r} | **{fmt(jf[0])}** | {fmt(ji[0])} | " + " | ".join(cells) + f" | {best} {fmt(timed[best])} | **{timed[best] / jf[0]:.2f}x** |")
    allocs = sorted(k for k, v in fused.items() if k.startswith(suite + "/") and (v[2] or v[3]))
    if allocs:
        print(f"\nAllocating at steady state: {', '.join(allocs)}")


def main():
    go, interp, fused = (load(p) for p in sys.argv[1:4])
    n = next(iter(go.values()))[4]

    print(f"Median ns/op over {n} runs each (±spread is half the min–max range as % of median).\n")
    print("| Benchmark | Go jingo | Zig interpreted | Zig fused | interp vs Go | fused vs Go | fused vs interp |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, _ in PAIRS:
        g, i, f = go[name], interp[name], fused[name]
        print(
            f"| {name} | {fmt(g[0])} ±{g[1]:.0f}% | {fmt(i[0])} ±{i[1]:.0f}% | {fmt(f[0])} ±{f[1]:.0f}% "
            f"| **{g[0] / i[0]:.2f}x** | **{g[0] / f[0]:.2f}x** | {i[0] / f[0]:.2f}x |"
        )

    print("\nStandard-library baselines (ns/op, B/op, allocs/op). Jingo/Jinzig are 0 B/op, 0 allocs/op on every row above.\n")
    print("| Baseline | Go encoding/json | Zig std.json | jingo vs encoding/json | jinzig fused vs std.json |")
    print("| --- | ---: | ---: | ---: | ---: |")
    seen = set()
    for name, base in PAIRS:
        if base in seen:
            continue
        seen.add(base)
        g, z = go[base], fused[base]
        print(
            f"| {base} | {fmt(g[0])} / {g[2]} B / {g[3]} | {fmt(z[0])} / {z[2]} B / {z[3]} "
            f"| {g[0] / go[name][0]:.1f}x | {z[0] / fused[name][0]:.1f}x |"
        )

    zig_rows = ["Unicode", "UnicodeLarge", "Time", "Slice", "Json", "SmallPayload", "LargePayload"]
    libs = ["std.json", "serde.zig", "zerde", "lalinsky-json", "jaysan", "zig-json", "sakakibara-json", "zserde", "jsonz"]
    if any(f"Zig/{r}/std.json" in fused for r in zig_rows):
        zig_table(interp, fused, "Zig", zig_rows, libs, "Zig encoders, like for like")
    esc_rows = ["Unicode", "UnicodeLarge", "Slice", "Json", "SmallPayload", "LargePayload"]
    if any(f"Esc/{r}/std.json" in fused for r in esc_rows):
        zig_table(interp, fused, "Esc", esc_rows, libs, "Zig encoders, escaping every string (jinzig with `,escape` on all string fields)")

    for label, d in (("go", go), ("interpreted", interp), ("fused", fused)):
        nonzero = [k for k, _ in PAIRS if d[k][2] or d[k][3]]
        if nonzero:
            print(f"\nWARNING: {label} allocates in: {', '.join(nonzero)}")


main()
