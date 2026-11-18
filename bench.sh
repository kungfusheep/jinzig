#!/bin/bash
# runs jingo's go benchmarks and both jinzig modes sequentially, then prints a comparison table.
# side effects: writes results/{go,interpreted,fused}.txt and results/report.md, and fetches
# bench/third_party/ (zerde, serde.zig) on first run
set -Eeuo pipefail

cd "$(dirname "$0")"
count="${COUNT:-3}"
benchtime_ms="${BENCHTIME_MS:-300}"
jingo="${JINGO:-../jingo}"
mkdir -p results
rm -f results/report.md

[ -d bench/third_party/zerde ] && [ -d bench/third_party/serde.zig ] || bench/third_party.sh

for m in interpreted fused; do
  zig build -Dmode="$m" -Dcompetitors=true -Doptimize=ReleaseFast -p "zig-out/$m"
done

echo "go: jingo (count=$count, ${benchtime_ms}ms)" >&2
(cd "$jingo" && GO111MODULE=off go test -vet=off -run '^$' -bench . -benchmem -count "$count" -benchtime "${benchtime_ms}ms") > results/go.txt

for m in interpreted fused; do
  echo "zig: $m (count=$count, ${benchtime_ms}ms)" >&2
  "zig-out/$m/bin/jinzig-bench-$m" -count "$count" -benchtime "$benchtime_ms" 2> results/"$m".txt
done

python3 tools/report.py results/go.txt results/interpreted.txt results/fused.txt | tee results/report.md
