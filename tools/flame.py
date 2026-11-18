"""flame turns an xctrace time-profile export into a flame graph svg plus a self-time summary.

usage: python3 tools/flame.py export.xml out.svg [title]
"""

import html
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict


def load_stacks(path):
    root = ET.parse(path).getroot()
    by_id = {}
    for el in root.iter():
        if "id" in el.attrib:
            by_id[el.attrib["id"]] = el

    def resolve(el):
        return by_id[el.attrib["ref"]] if "ref" in el.attrib else el

    raw = Counter()
    for row in root.iter("row"):
        tagged = row.find("tagged-backtrace")
        if tagged is None:
            continue
        frames = []
        for f in resolve(tagged).findall("frame"):
            f = resolve(f)
            binary = f.find("binary")
            binary = resolve(binary) if binary is not None else None
            bin_key = (binary.attrib["path"], binary.attrib["load-addr"]) if binary is not None else None
            frames.append((f.attrib.get("name", "?"), f.attrib.get("addr"), bin_key))
        # frames are leaf-first; flame graphs grow from the root
        raw[tuple(reversed(frames))] += 1

    names = symbolicate(raw)
    stacks = Counter()
    for stack, n in raw.items():
        stacks[tuple(names.get((fr[1], fr[2][0]) if fr[2] else None, fr[0]) for fr in stack)] += n
    return stacks


def symbolicate(raw):
    """resolves frames xctrace left as bare addresses using atos and the binary's load address."""
    pending = defaultdict(set)
    for stack in raw:
        for name, addr, binary in stack:
            if binary and re.fullmatch(r"0x[0-9a-f]+", name):
                pending[binary].add(addr)
    names = {}
    for (path, load), addrs in pending.items():
        addrs = sorted(addrs)
        out = subprocess.run(["atos", "-o", path, "-l", load, *addrs], capture_output=True, text=True).stdout.splitlines()
        for addr, line in zip(addrs, out):
            # "fn (in binary) (file.zig:12)" -> "fn"
            names[(addr, path)] = line.split(" (in ")[0]
    return names


def build_tree(stacks):
    tree = lambda: {"n": 0, "kids": defaultdict(tree)}  # noqa: E731
    root = tree()
    for stack, n in stacks.items():
        node = root
        node["n"] += n
        for fr in stack:
            node = node["kids"][fr]
            node["n"] += n
    return root


def color(name):
    h = sum(map(ord, name)) % 60
    if name.startswith(("struct_encoder.", "slice_encoder.", "ptrconvert.", "buffer.")):
        return f"hsl({20 + h % 30},85%,60%)"  # jinzig: warm
    if name.startswith("main."):
        return f"hsl({200 + h % 30},60%,65%)"  # harness: cool
    return f"hsl(0,0%,{70 + h % 20}%)"  # everything else: grey


def render(root, title, width=1400, row=17):
    total = root["n"]
    rects = []
    depth_max = 0

    def walk(node, name, x, depth):
        nonlocal depth_max
        depth_max = max(depth_max, depth)
        w = node["n"] / total * width
        if w >= 0.3:
            pct = node["n"] / total * 100
            label = html.escape(name)
            text = label if w > 7 * 6 else ""
            if text and len(name) * 6.5 > w:
                text = html.escape(name[: max(int(w / 6.5) - 2, 0)]) + ".."
            rects.append((x, depth, w, label, pct, text, color(name)))
        cx = x
        for kname, kid in sorted(node["kids"].items(), key=lambda kv: -kv[1]["n"]):
            walk(kid, kname, cx, depth + 1)
            cx += kid["n"] / total * width

    walk(root, "all", 0, 0)
    height = (depth_max + 2) * row + 40
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" font-family="monospace" font-size="11">',
        f'<rect width="100%" height="100%" fill="#fff"/><text x="8" y="20" font-size="14">{html.escape(title)} ({total} samples)</text>',
    ]
    for x, depth, w, label, pct, text, fill in rects:
        y = height - (depth + 1) * row
        out.append(
            f'<g><title>{label} ({pct:.1f}%)</title><rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{row - 1}" fill="{fill}" rx="2"/>'
            f'<text x="{x + 3:.1f}" y="{y + row - 5}">{text}</text></g>'
        )
    out.append("</svg>")
    return "\n".join(out)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else src
    stacks = load_stacks(src)
    with open(dst, "w") as f:
        f.write(render(build_tree(stacks), title))

    total = sum(stacks.values())
    self_time = Counter()
    for stack, n in stacks.items():
        self_time[stack[-1]] += n
    print(f"{total} samples, top self time:")
    for name, n in self_time.most_common(12):
        print(f"  {n / total * 100:5.1f}%  {name}")


main()
