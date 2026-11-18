"""report turns go-format benchmark output into a markdown comparison of medians.

usage: python3 tools/report.py go.txt zig.txt
prints the full report, and rewrites the generated sections of README.md (summary) and
PERFORMANCE.md (full), which sit between <!-- bench:NAME --> and <!-- /bench:NAME --> markers.
"""

import contextlib
import io
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


def zig_table(zig, suite, rows, libs, title):
    print(f"\n### {title}\n")
    print("Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to")
    print("jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express")
    print("the payload (no custom-serialization hook, or no single-item pointer support). \u2717 = wrong output, not timed.\n")
    print("| Payload | jinzig | " + " | ".join(libs) + " | fastest other | jinzig lead |")
    print("| --- | ---: | " + " | ".join("---:" for _ in libs) + " | --- | ---: |")
    for r in rows:
        jf = zig.get(f"{suite}/{r}/jinzig")
        cells, timed = [], {}
        for l in libs:
            key = f"{suite}/{r}/{l}"
            if key in mismatched:
                cells.append("\u2717")
            elif key in zig:
                cells.append(fmt(zig[key][0]))
                timed[l] = zig[key][0]
            else:
                cells.append("n/a")
        best = min(timed, key=timed.get)
        print(f"| {r} | **{fmt(jf[0])}** | " + " | ".join(cells) + f" | {best} {fmt(timed[best])} | **{timed[best] / jf[0]:.2f}x** |")
    allocs = sorted(k for k, v in zig.items() if k.startswith(suite + "/") and (v[2] or v[3]))
    if allocs:
        print(f"\nAllocating at steady state: {', '.join(allocs)}")


SUMMARY_ROWS = ["SmallPayload", "LargePayload"]


def summary(go, zig, libs):
    """summary is the README's short tables: per payload, jinzig (plain and escaping every string, which is how the
    others always run), std.json, the two fastest other zig encoders, and go jingo for reference."""
    for r in SUMMARY_ROWS:
        base = zig[f"Zig/{r}/std.json"][0]
        others = sorted(
            (zig[f"Zig/{r}/{l}"][0], l) for l in libs
            if l != "std.json" and f"Zig/{r}/{l}" in zig and f"Zig/{r}/{l}" not in mismatched
        )[:2]
        rows = [("**jinzig**", zig[f"Zig/{r}/jinzig"]), ("jinzig, every string `,escape`", zig[f"Esc/{r}/jinzig"]), ("std.json", zig[f"Zig/{r}/std.json"])]
        rows += [(l + (" (never escapes)" if l == "jaysan" else ""), zig[f"Zig/{r}/{l}"]) for _, l in others]
        rows.append(("jingo (go, for reference)", go[r]))
        print(f"\n**{r}**\n")
        print("| Lib | ns/op | B/op | allocs/op | vs std.json |")
        print("| --- | ---: | ---: | ---: | ---: |")
        for name, v in rows:
            print(f"| {name} | {fmt(v[0])} | {v[2]} | {v[3]} | {base / v[0]:.1f}x |")


def splice(path, name, text):
    begin, end = f"<!-- bench:{name} -->", f"<!-- /bench:{name} -->"
    with open(path) as f:
        doc = f.read()
    i, j = doc.index(begin) + len(begin), doc.index(end)
    with open(path, "w") as f:
        f.write(doc[:i] + "\n" + text.strip("\n") + "\n" + doc[j:])


def main():
    go, zig = (load(p) for p in sys.argv[1:3])
    libs = ["std.json", "serde.zig", "zerde", "lalinsky-json", "jaysan", "yyjson", "zig-json", "sakakibara-json", "zserde", "jsonz"]

    full = io.StringIO()
    with contextlib.redirect_stdout(full):
        report(go, zig, libs)
    print(full.getvalue(), end="")
    splice("PERFORMANCE.md", "full", full.getvalue())

    short = io.StringIO()
    with contextlib.redirect_stdout(short):
        summary(go, zig, libs)
    splice("README.md", "summary", short.getvalue())


def report(go, zig, libs):
    n = next(iter(go.values()))[4]

    print("### jinzig vs Go jingo\n")
    print(f"Median ns/op over {n} runs each (±spread is half the min–max range as % of median).\n")
    print("| Benchmark | Go jingo | Zig jinzig | jinzig vs Go |")
    print("| --- | ---: | ---: | ---: |")
    for name, _ in PAIRS:
        g, f = go[name], zig[name]
        print(f"| {name} | {fmt(g[0])} ±{g[1]:.0f}% | {fmt(f[0])} ±{f[1]:.0f}% | **{g[0] / f[0]:.2f}x** |")

    print("\nStandard-library baselines (ns/op, B/op, allocs/op). Jingo/Jinzig are 0 B/op, 0 allocs/op on every row above.\n")
    print("| Baseline | Go encoding/json | Zig std.json | jingo vs encoding/json | jinzig vs std.json |")
    print("| --- | ---: | ---: | ---: | ---: |")
    seen = set()
    for name, base in PAIRS:
        if base in seen:
            continue
        seen.add(base)
        g, z = go[base], zig[base]
        print(
            f"| {base} | {fmt(g[0])} / {g[2]} B / {g[3]} | {fmt(z[0])} / {z[2]} B / {z[3]} "
            f"| {g[0] / go[name][0]:.1f}x | {z[0] / zig[name][0]:.1f}x |"
        )

    zig_rows = ["Unicode", "UnicodeLarge", "Time", "Slice", "Json", "SmallPayload", "LargePayload"]
    if any(f"Zig/{r}/std.json" in zig for r in zig_rows):
        zig_table(zig, "Zig", zig_rows, libs, "Zig encoders, like for like")
    esc_rows = ["Unicode", "UnicodeLarge", "Slice", "Json", "SmallPayload", "LargePayload"]
    if any(f"Esc/{r}/std.json" in zig for r in esc_rows):
        zig_table(zig, "Esc", esc_rows, libs, "Zig encoders, escaping every string (jinzig with `,escape` on all string fields)")

    for label, d in (("go", go), ("jinzig", zig)):
        nonzero = [k for k, _ in PAIRS if d[k][2] or d[k][3]]
        if nonzero:
            print(f"\nWARNING: {label} allocates in: {', '.join(nonzero)}")


main()
