# jinzig

A port of [jingo](../jingo) to Zig 0.17. It encodes Zig structs and slices to JSON using the same design as jingo. At construction time it compiles an *instruction set*: static chunks of keys and braces, fast paths for string and int fields, leap functions at field offsets, and closure-style functions for everything else. That instruction set is then executed on every `marshal`.

jingo builds its instruction set with `reflect` when `NewStructEncoder` runs. jinzig builds the same plan from `@typeInfo` at **comptime**, then gives you two ways to execute it, chosen with a build flag:

| `-Dmode=` | what `marshal` does |
| --- | --- |
| `interpreted` (default) | the faithful port. `init` copies the plan into a heap-allocated `[]Instruction`, and `marshal` walks it with jingo's dispatch loop: `static` → `string_field` → `int` → `leap_fun` → `fun(ctx, …)`, with nested encoders reached through `ctx` pointers, much as go closures capture `enc` |
| `fused` | the identical plan, unrolled with `inline for`. Every branch is resolved at compile time, so there is no dispatch loop, no indirect calls and no encoder state read at runtime |

Both modes run the exact same test suite, which includes byte-for-byte comparisons against real jingo output.

## Usage

```zig
const jz = @import("jinzig");

const MyPayload = struct {
    name: []const u8,
    age: isize,
    id: isize, // anything we don't tag doesn't get emitted

    // zig has no struct tags, so they're declared alongside the fields
    pub const json_tags = .{ .name = "name", .age = "age" };
};

// create an encoder once per type
const enc = try jz.StructEncoder(MyPayload).init(gpa);
defer enc.deinit();

const buf = try jz.Buffer.fromPool();
defer buf.returnToPool();

try enc.marshal(&.{ .name = "Mr Payload", .age = 33, .id = 1 }, buf);
// buf.string() == {"name":"Mr Payload","age":33}
```

`SliceEncoder` works the same way: `jz.SliceEncoder([]const []const u8).init(gpa)`, then `enc.marshal(&slice, buf)`.

## Mapping from jingo

| jingo | jinzig |
| --- | --- |
| `json:"name,opts"` struct tag | `pub const json_tags = .{ .field = "name,opts" }` |
| `NewStructEncoder(T{})` / `NewSliceEncoder([]T{})` | `StructEncoder(T).init(gpa)` / `SliceEncoder([]const T).init(gpa)` (and `deinit`) |
| `Marshal(&v, buf)` | `try marshal(&v, buf)`, which returns `error.OutOfMemory` rather than panicking |
| `NewBufferFromPool`, `NewBufferFromPoolWithCap`, `ReturnToPool` | `Buffer.fromPool`, `Buffer.fromPoolWithCap`, `returnToPool`. The pool is a lock-free thread-local free list standing in for `sync.Pool`'s per-P caches; `Buffer.drainPool` frees it |
| `,stringer` → `String() string` | `pub fn string(self: *const T) []const u8` |
| `,encoder` → `JSONEncode(*Buffer)` | `pub fn jsonEncode(self: *const T, w: *Buffer) Error!void` |
| `,encoder` → `EncodeJSON(io.Writer)` | `pub fn encodeJson(self: *const T, w: *std.Io.Writer) std.Io.Writer.Error!void` |
| `,raw`, `,escape` | identical semantics |
| `int` / `uint` | `isize` / `usize` (`isize` gets jingo's `kindInt` fast path) |
| `string`, `[]byte` | `[]const u8` / `[]u8` |
| `*T` (nil → `null`) | `?*T` (null → `null`), plus `?T` optionals for any supported `T`, plus non-null `*T`, which skips the null check entirely |
| `time.Time` | `jz.Time{ .sec, .nsec, .offset }`, with `Time.date(...)` mirroring `time.Date(..., time.UTC)`. RFC3339Nano output |
| `[]jingo.EscapeString` | `SliceEncoder([]const jz.EscapeString)`, whose `marshal` takes `*const []const []const u8` |
| `panic("unsupported type …")` at runtime | `@compileError` naming the field |

jingo quirks are kept on purpose:
- primitive arrays use `", "` separators
- `,raw` on a non-byte field emits `null`
- `,stringer` on a nil pointer emits `"null"` (quoted)
- only *direct* self-recursion (`?*Self`) reuses the encoder

`std.json`-compatible `jsonStringify` hooks exist on the test payloads only so that the stdlib baselines produce the same documents.

## Building, testing, benchmarking

```sh
zig build test                    # interpreted
zig build test -Dmode=fused       # fused
./bench.sh                        # go jingo vs both zig modes vs std.json/serde.zig/zerde -> results/report.md
                                  # (COUNT=3, BENCHTIME_MS=300 by default; nothing allocates, so that's plenty)
bench/third_party.sh              # fetch zerde + serde.zig at pinned commits (bench.sh does this on first run)
zig build test -Dcompetitors=true # also verify the other encoders emit jingo's documents byte for byte
tools/profile.sh Esc/UnicodeLarge/jinzig fused   # Instruments Time Profiler -> flame graph svg + self-time summary
GO111MODULE=off go run ./tools/golden   # regenerate tests/golden/*.json from ../jingo
```

## Results

Apple M5 Max, macOS, Go 1.27.1, Zig 0.17.0 `ReleaseFast`, `./bench.sh`. Inputs are the jingo_test.go payloads.
Before a library is timed on a payload, the harness checks its output against jinzig's document (which the tests
pin to jingo's golden output). A library that emits anything else is marked ✗ and not timed. The one accepted
divergence is std.json, which writes the `f32` field with f64 precision.

| Library | Commit | Notes |
| --- | --- | --- |
| [zerde](https://github.com/leostera/zerde) | `718abd1` | [0.17 patch](bench/patches/zerde-zig-0.17.patch): `**` → `@splat`, field-list shim. No custom-serialization hook |
| [serde.zig](https://github.com/OrlovEvgeny/serde.zig) | `8742517` | unpatched (supports 0.17) |
| [lalinsky/json.zig](https://github.com/lalinsky/json.zig) | `9d3d4d9` | unpatched; payloads declare `jsonFormat` so nulls are emitted, as jingo does |
| [jaysan](https://github.com/lawrence-laz/jaysan) | `17b146a` | [0.17 patch](bench/patches/jaysan-zig-0.17.patch) for a zig 0.13 codebase; its own 9 tests pass. Never escapes strings, and writes strings inside arrays unquoted (✗ on Slice) |
| [zig-json](https://github.com/blackboardsh/zig-json) | `aa5a747` | [0.17 patch](bench/patches/zig-json-zig-0.17.patch): translate-c for yyjson.h, field-list shim. Allocating API only: it builds a yyjson document per call (libc mallocs aren't counted in B/op) |
| [sakakibara/json-zig](https://github.com/sakakibara/json-zig) | `65ca825` | unpatched; no single-item pointer fields |
| [zserde](https://github.com/entropyparadox-lab/zserde) | `f980f6b` | unpatched; no custom-serialization hook |
| [jsonz](https://github.com/KercyDing/jsonz) | `06a1ca9` | unpatched; no single-item pointer fields |

`jinzig-bench -probe-escaping` shows what each library does with `"`, `\` and newlines. Every library escapes except jaysan, so jaysan sits out the escaped suite.

Median ns/op over 3 runs each (±spread is half the min–max range as % of median).

| Benchmark | Go jingo | Zig interpreted | Zig fused | interp vs Go | fused vs Go | fused vs interp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Unicode | 20.5 ±3% | 11.0 ±2% | 3.6 ±1% | **1.87x** | **5.73x** | 3.06x |
| UnicodeLarge | 46.9 ±1% | 31.2 ±3% | 15.8 ±2% | **1.50x** | **2.96x** | 1.97x |
| Time | 116 ±1% | 70.5 ±1% | 67.7 ±2% | **1.65x** | **1.72x** | 1.04x |
| Slice | 34.1 ±1% | 13.4 ±2% | 5.8 ±2% | **2.54x** | **5.88x** | 2.32x |
| SliceEscape | 66.2 ±2% | 17.1 ±1% | 17.2 ±3% | **3.86x** | **3.84x** | 0.99x |
| Json | 2,110 ±1% | 1,189 ±1% | 1,140 ±2% | **1.78x** | **1.85x** | 1.04x |
| SmallPayload | 55.3 ±1% | 28.7 ±3% | 5.9 ±2% | **1.92x** | **9.44x** | 4.90x |
| LargePayload | 2,915 ±2% | 1,260 ±1% | 287 ±2% | **2.31x** | **10.17x** | 4.40x |

Standard-library baselines (ns/op, B/op, allocs/op). Jingo/Jinzig are 0 B/op, 0 allocs/op on every row above.

| Baseline | Go encoding/json | Zig std.json | jingo vs encoding/json | jinzig fused vs std.json |
| --- | ---: | ---: | ---: | ---: |
| UnicodeStdLib | 163 / 112 B / 1 | 102 / 239 B / 2 | 7.9x | 28.6x |
| UnicodeLargeStdLib | 737 / 1281 B / 1 | 642 / 2426 B / 3 | 15.7x | 40.6x |
| TimeStdLib | 272 / 192 B / 1 | 209 / 642 B / 3 | 2.3x | 3.1x |
| SliceStdLib | 111 / 80 B / 1 | 80.0 / 201 B / 2 | 3.3x | 13.8x |
| StdJson | 4,727 / 4868 B / 1 | 3,235 / 12527 B / 8 | 2.2x | 2.8x |
| SmallPayloadStdLib | 224 / 144 B / 1 | 160 / 590 B / 3 | 4.0x | 27.4x |
| LargePayloadStdLib | 9,582 / 4868 B / 1 | 4,933 / 12028 B / 8 | 3.3x | 17.2x |

### Zig encoders, like for like

Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to
jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express
the payload (no custom-serialization hook, or no single-item pointer support). ✗ = wrong output, not timed.

| Payload | jinzig fused | jinzig interp | std.json | serde.zig | zerde | lalinsky-json | jaysan | zig-json | sakakibara-json | zserde | jsonz | fastest other | fused lead |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| Unicode | **3.2** | 9.5 | 92.7 | 92.1 | 56.7 | 24.7 | 16.6 | 179 | 51.8 | 131 | 31.2 | jaysan 16.6 | **5.21x** |
| UnicodeLarge | **15.2** | 31.2 | 663 | 197 | 519 | 70.1 | 36.6 | 561 | 143 | 2,005 | 102 | jaysan 36.6 | **2.41x** |
| Time | **64.7** | 69.7 | 188 | 155 | n/a | 68.6 | n/a | n/a | n/a | n/a | n/a | lalinsky-json 68.6 | **1.06x** |
| Slice | **5.2** | 12.7 | 65.5 | 65.2 | 40.1 | 44.3 | ✗ | 95.9 | 36.6 | 80.4 | 41.7 | sakakibara-json 36.6 | **6.97x** |
| Json | **1,151** | 1,185 | 3,161 | 2,870 | n/a | 1,458 | n/a | n/a | n/a | n/a | n/a | lalinsky-json 1,458 | **1.27x** |
| SmallPayload | **6.0** | 28.5 | 132 | 133 | 92.8 | 29.5 | 39.5 | 158 | 88.0 | 150 | 59.3 | lalinsky-json 29.5 | **4.90x** |
| LargePayload | **280** | 1,285 | 4,600 | 5,794 | 3,180 | 1,941 | 1,714 | 3,434 | n/a | 4,560 | n/a | jaysan 1,714 | **6.13x** |

Allocating at steady state: Zig/LargePayload/zig-json, Zig/Slice/zig-json, Zig/SmallPayload/zig-json, Zig/Unicode/zig-json, Zig/UnicodeLarge/zig-json

### Zig encoders, escaping every string (jinzig with `,escape` on all string fields)

Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to
jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express
the payload (no custom-serialization hook, or no single-item pointer support). ✗ = wrong output, not timed.

| Payload | jinzig fused | jinzig interp | std.json | serde.zig | zerde | lalinsky-json | jaysan | zig-json | sakakibara-json | zserde | jsonz | fastest other | fused lead |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| Unicode | **9.3** | 13.5 | 86.6 | 88.2 | 52.2 | 24.6 | n/a | 178 | 51.8 | 132 | 30.7 | lalinsky-json 24.6 | **2.64x** |
| UnicodeLarge | **48.8** | 58.1 | 568 | 196 | 510 | 72.6 | n/a | 539 | 146 | 2,004 | 105 | lalinsky-json 72.6 | **1.49x** |
| Slice | **16.9** | 16.0 | 64.1 | 64.0 | 39.1 | 44.0 | n/a | 92.5 | 35.7 | 78.7 | 41.2 | sakakibara-json 35.7 | **2.11x** |
| Json | **1,075** | 1,169 | 3,114 | 2,770 | n/a | 1,444 | n/a | n/a | n/a | n/a | n/a | lalinsky-json 1,444 | **1.34x** |
| SmallPayload | **13.9** | 29.9 | 133 | 133 | 94.8 | 29.6 | n/a | 158 | 90.6 | 152 | 62.4 | lalinsky-json 29.6 | **2.13x** |
| LargePayload | **1,056** | 1,445 | 4,644 | 5,931 | 3,170 | 1,948 | n/a | 3,411 | n/a | 4,609 | n/a | lalinsky-json 1,948 | **1.85x** |

Allocating at steady state: Esc/LargePayload/zig-json, Esc/Slice/zig-json, Esc/SmallPayload/zig-json, Esc/Unicode/zig-json, Esc/UnicodeLarge/zig-json

### Reading the numbers

- **Fused vs interpreted:** fused removes the dispatch loop, and it groups each run of keys, plain strings and plain ints into one write. A run adds up its upper bound (the static bytes, 20 per int and the string lengths), reserves it with one capacity check, writes through a cursor held in a register and sets the length once. Updating the buffer's length on every write was the real cost: a byte store may alias it, so each write had to reload it and wait on the last one. A slice of plain strings, or of structs that are one run (LargePayload's users and topics), reserves once for every element.
- **vs the other Zig encoders:** they reflect over fields at comptime too, but still decide commas and colons at runtime, re-escape constant keys on every call, scan every string, and format ints through `std.fmt`. jinzig makes those decisions when the encoder is compiled, and only escapes when a field opts in.
- **Escaping:** `,escape` screens 32 bytes per iteration with three vector compares (`"`, `\`, `< 0x20`) and one reduce. Only flagged blocks get the exact five-byte check, out of line, and the end of the string is covered by an overlapping block. Strings under 16 bytes use overlapping SWAR word loads. A clean string is one check plus one copy.
- **Closest rivals:** lalinsky/json.zig (comptime-specialised like jinzig) is within 5% on Time and about 1.2x behind on Json, where floats, times and custom encoders keep jinzig off the cursor path. On plain structs and slices it is 5–7x behind. jaysan, which never escapes, comes closest on long strings.
- **Writer cost:** `std.Io.Writer`'s hot path is non-virtual (bounds check plus `memcpy`). A microbenchmark of the SmallPayload write sequence measured it about 11% slower than jinzig's `Buffer` when inlined, and about 28% slower across a non-inlined call. That's small next to the gaps above.
- **Short copies:** field values up to 64 bytes are copied with overlapping word or vector stores instead of a libc `memcpy` call, ints are written straight into the output two digits at a time, and comptime-known chunks use fixed-size stores.
- **Allocation:** zero allocations at steady state for every encoder, and profiles show no allocator time in the hot loop.
