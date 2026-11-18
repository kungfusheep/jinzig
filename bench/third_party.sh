#!/bin/bash
# fetches the third-party zig json encoders used for comparison benchmarks into bench/third_party/,
# pinned to exact commits, and applies the zig 0.17 compatibility patches in bench/patches/.
# side effects: creates/replaces bench/third_party/ (gitignored). delete it to drop the competitors.
set -Eeuo pipefail

cd "$(dirname "$0")"
dir=third_party
mkdir -p "$dir"

fetch() {
  local name=$1 url=$2 rev=$3
  rm -rf "${dir:?}/$name"
  git init -q "$dir/$name"
  git -C "$dir/$name" fetch -q --depth 1 "$url" "$rev"
  git -C "$dir/$name" checkout -q FETCH_HEAD
  if [ -f "patches/$name-zig-0.17.patch" ]; then
    git -C "$dir/$name" apply "../../patches/$name-zig-0.17.patch"
  fi
  echo "$name @ $rev"
}

# zerde targets zig 0.16; the patch is mechanical (`**` -> @splat, comptime shim for the new @typeInfo field layout)
fetch zerde https://github.com/leostera/zerde 718abd104a408f8ffa253044979cefcefce499ac
fetch serde.zig https://github.com/OrlovEvgeny/serde.zig 87425173b8807d5e2bbb6e15d09a4b14de91f217
fetch lalinsky-json https://github.com/lalinsky/json.zig 9d3d4d951507a73732ae2f49275ad8fefd4a3cf8
# jaysan targets zig 0.13; the patch renames @typeInfo tags, swaps AnyWriter for *std.Io.Writer and shims the
# field list. its own test suite passes on 0.17 with the patch applied
fetch jaysan https://github.com/lawrence-laz/jaysan 17b146a2985084cc8ed43764615da703588eaa1f
# zig-json: zig 0.17 removed @cImport, so yyjson.h is translated in build.zig instead
fetch zig-json https://github.com/blackboardsh/zig-json aa5a7479f25f7011c1aaec43ac13c9a246a9d46b
fetch sakakibara-json https://github.com/sakakibara/json-zig 65ca82571f2d0cecbba3b28e4baee5be36c838ac
fetch zserde https://github.com/entropyparadox-lab/zserde f980f6bf3beae7d7c28b80d3677efedea79aa5e7
fetch jsonz https://github.com/KercyDing/jsonz 06a1ca9483ba4dd16cf30b5ad1cd9146985301da
