#!/bin/bash
# runs jingo's go benchmarks and then jinzig's, then prints a comparison table.
# side effects: writes results/{go,zig}.txt and results/report.md, and fetches
# bench/third_party/ (zerde, serde.zig) on first run
set -Eeuo pipefail

cd "$(dirname "$0")"
count="${COUNT:-3}"
benchtime_ms="${BENCHTIME_MS:-300}"
jingo="${JINGO:-../jingo}"
mkdir -p results
rm -f results/report.md

[ -d bench/third_party/zerde ] && [ -d bench/third_party/serde.zig ] || bench/third_party.sh

zig build -Dcompetitors=true -Doptimize=ReleaseFast

echo "go: jingo (count=$count, ${benchtime_ms}ms)" >&2
(cd "$jingo" && GO111MODULE=off go test -vet=off -run '^$' -bench . -benchmem -count "$count" -benchtime "${benchtime_ms}ms") > results/go.txt

echo "zig: jinzig (count=$count, ${benchtime_ms}ms)" >&2
zig-out/bin/jinzig-bench -count "$count" -benchtime "$benchtime_ms" 2> results/zig.txt

python3 tools/report.py results/go.txt results/zig.txt | tee results/report.md
