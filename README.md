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
| Unicode | 19.5 ±1% | 11.1 ±2% | 7.8 ±1% | **1.75x** | **2.50x** | 1.43x |
| UnicodeLarge | 46.0 ±1% | 31.6 ±3% | 26.7 ±1% | **1.46x** | **1.72x** | 1.18x |
| Time | 110 ±1% | 68.8 ±3% | 66.4 ±0% | **1.60x** | **1.66x** | 1.04x |
| Slice | 32.3 ±1% | 13.6 ±2% | 13.5 ±1% | **2.37x** | **2.40x** | 1.01x |
| SliceEscape | 63.1 ±11% | 17.3 ±2% | 17.1 ±0% | **3.64x** | **3.70x** | 1.02x |
| Json | 2,062 ±1% | 1,226 ±6% | 1,174 ±1% | **1.68x** | **1.76x** | 1.04x |
| SmallPayload | 53.4 ±1% | 34.3 ±4% | 20.7 ±2% | **1.56x** | **2.58x** | 1.65x |
| LargePayload | 2,751 ±0% | 1,373 ±2% | 1,023 ±1% | **2.00x** | **2.69x** | 1.34x |

Standard-library baselines (ns/op, B/op, allocs/op). Jingo/Jinzig are 0 B/op, 0 allocs/op on every row above.

| Baseline | Go encoding/json | Zig std.json | jingo vs encoding/json | jinzig fused vs std.json |
| --- | ---: | ---: | ---: | ---: |
| UnicodeStdLib | 158 / 112 B / 1 | 105 / 239 B / 2 | 8.1x | 13.5x |
| UnicodeLargeStdLib | 702 / 1281 B / 1 | 642 / 2426 B / 3 | 15.3x | 24.0x |
| TimeStdLib | 258 / 192 B / 1 | 215 / 642 B / 3 | 2.3x | 3.2x |
| SliceStdLib | 106 / 80 B / 1 | 81.6 / 201 B / 2 | 3.3x | 6.1x |
| StdJson | 4,454 / 4868 B / 1 | 3,333 / 12527 B / 8 | 2.2x | 2.8x |
| SmallPayloadStdLib | 217 / 144 B / 1 | 162 / 590 B / 3 | 4.1x | 7.8x |
| LargePayloadStdLib | 9,018 / 4868 B / 1 | 5,024 / 12028 B / 8 | 3.3x | 4.9x |

### Zig encoders, like for like

Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to
jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express
the payload (no custom-serialization hook, or no single-item pointer support). ✗ = wrong output, not timed.

| Payload | jinzig fused | jinzig interp | std.json | serde.zig | zerde | lalinsky-json | jaysan | zig-json | sakakibara-json | zserde | jsonz | fastest other | fused lead |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| Unicode | **7.2** | 10.0 | 90.6 | 97.9 | 55.1 | 25.3 | 17.7 | 161 | 51.8 | 136 | 33.0 | jaysan 17.7 | **2.47x** |
| UnicodeLarge | **25.8** | 30.4 | 584 | 202 | 512 | 68.0 | 36.7 | 540 | 138 | 2,066 | 103 | jaysan 36.7 | **1.42x** |
| Time | **65.8** | 67.7 | 189 | 159 | n/a | 69.1 | n/a | n/a | n/a | n/a | n/a | lalinsky-json 69.1 | **1.05x** |
| Slice | **12.5** | 12.7 | 63.5 | 66.1 | 40.1 | 43.3 | ✗ | 95.7 | 36.2 | 80.6 | 42.6 | sakakibara-json 36.2 | **2.90x** |
| Json | **1,166** | 1,238 | 3,150 | 2,617 | n/a | 1,459 | n/a | n/a | n/a | n/a | n/a | lalinsky-json 1,459 | **1.25x** |
| SmallPayload | **20.8** | 33.5 | 135 | 130 | 94.8 | 30.2 | 40.4 | 162 | 88.8 | 156 | 61.3 | lalinsky-json 30.2 | **1.45x** |
| LargePayload | **1,044** | 1,366 | 4,767 | 5,898 | 3,200 | 1,969 | 1,741 | 4,268 | n/a | 4,607 | n/a | jaysan 1,741 | **1.67x** |

Allocating at steady state: Zig/LargePayload/zig-json, Zig/Slice/zig-json, Zig/SmallPayload/zig-json, Zig/Unicode/zig-json, Zig/UnicodeLarge/zig-json

### Zig encoders, escaping every string (jinzig with `,escape` on all string fields)

Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to
jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express
the payload (no custom-serialization hook, or no single-item pointer support). ✗ = wrong output, not timed.

| Payload | jinzig fused | jinzig interp | std.json | serde.zig | zerde | lalinsky-json | jaysan | zig-json | sakakibara-json | zserde | jsonz | fastest other | fused lead |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| Unicode | **9.2** | 13.4 | 90.9 | 94.4 | 54.9 | 24.9 | n/a | 162 | 52.3 | 135 | 32.2 | lalinsky-json 24.9 | **2.73x** |
| UnicodeLarge | **48.7** | 56.9 | 597 | 206 | 512 | 68.9 | n/a | 537 | 133 | 2,055 | 104 | lalinsky-json 68.9 | **1.42x** |
| Slice | **16.1** | 15.8 | 65.2 | 67.1 | 40.3 | 43.4 | n/a | 95.8 | 36.2 | 81.1 | 42.0 | sakakibara-json 36.2 | **2.24x** |
| Json | **1,117** | 1,101 | 3,225 | 2,657 | n/a | 1,485 | n/a | n/a | n/a | n/a | n/a | lalinsky-json 1,485 | **1.33x** |
| SmallPayload | **24.9** | 35.5 | 136 | 131 | 91.4 | 30.6 | n/a | 164 | 88.1 | 155 | 61.0 | lalinsky-json 30.6 | **1.23x** |
| LargePayload | **1,079** | 1,559 | 4,819 | 5,773 | 3,277 | 1,971 | n/a | 4,279 | n/a | 4,648 | n/a | lalinsky-json 1,971 | **1.83x** |

Allocating at steady state: Esc/LargePayload/zig-json, Esc/Slice/zig-json, Esc/SmallPayload/zig-json, Esc/Unicode/zig-json, Esc/UnicodeLarge/zig-json

### Reading the numbers

- **Fused vs interpreted:** fused removes the dispatch loop. It wins most where a marshal runs many small instructions per struct (SmallPayload, LargePayload), and does nothing for single-slice payloads whose time is all in one element loop.
- **vs the other Zig encoders:** they reflect over fields at comptime too, but still decide commas and colons at runtime, re-escape constant keys on every call, scan every string, and format ints through `std.fmt`. jinzig makes those decisions when the encoder is compiled, and only escapes when a field opts in.
- **Escaping:** `,escape` screens 32 bytes per iteration with three vector compares (`"`, `\`, `< 0x20`) and one reduce. Only flagged blocks get the exact five-byte check, out of line, and the end of the string is covered by an overlapping block. Strings under 16 bytes use overlapping SWAR word loads. A clean string is one check plus one copy.
- **Closest rivals:** lalinsky/json.zig (comptime-specialised like jinzig) is within 5% on Time and 1.2–1.5x behind on the struct-heavy payloads. jaysan, which never escapes, comes closest on long strings.
- **Writer cost:** `std.Io.Writer`'s hot path is non-virtual (bounds check plus `memcpy`). A microbenchmark of the SmallPayload write sequence measured it about 11% slower than jinzig's `Buffer` when inlined, and about 28% slower across a non-inlined call. That's small next to the gaps above.
- **Short copies:** field values and digits are copied with overlapping word or vector stores (`copyShort`) instead of a libc `memcpy` call, and comptime-known chunks use fixed-size stores (`writeStatic`).
- **Allocation:** zero allocations at steady state for every encoder, and profiles show no allocator time in the hot loop.
