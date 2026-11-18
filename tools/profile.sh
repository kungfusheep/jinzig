#!/bin/bash
# profiles one benchmark with Instruments' Time Profiler and renders a flame graph, like
# `go test -cpuprofile` + `go tool pprof -http`. usage: tools/profile.sh FILTER
#   e.g. tools/profile.sh Esc/UnicodeLarge/jinzig
# side effects: builds zig-out, writes results/profiles/<name>.{trace,xml,svg}
set -Eeuo pipefail

cd "$(dirname "$0")/.."
filter="${1:?usage: tools/profile.sh FILTER}"
name="$(echo "$filter" | tr '/' '_')"
bin="zig-out/bin/jinzig-bench"
out="results/profiles/$name"
mkdir -p results/profiles

zig build -Dcompetitors=true -Doptimize=ReleaseFast
dsymutil "$bin" # zig leaves debug info in the object files; Instruments needs a dSYM

rm -rf "$out.trace"
xctrace record --template 'Time Profiler' --output "$out.trace" --launch -- "$bin" -filter "$filter" -benchtime 2000 >/dev/null
xctrace symbolicate --input "$out.trace" --dsym "$bin.dSYM" >/dev/null
xctrace export --input "$out.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$out.xml"

python3 tools/flame.py "$out.xml" "$out.svg" "jinzig: $filter"
echo "flame graph: $out.svg (or open $out.trace in Instruments)"
