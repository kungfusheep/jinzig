# jinzig

A fast JSON encoder for Zig structs and slices, ported from [jingo](https://github.com/bet365/jingo). The encoding plan is worked out
at compile time, so there's nothing to set up, nothing allocated once the buffer has room, and the output matches
jingo byte for byte (golden tests are generated from jingo itself).

```zig
const jz = @import("jinzig");

const MyPayload = struct {
    name: []const u8,
    age: isize,
    id: isize, // untagged fields aren't emitted

    // zig has no struct tags, so they're declared alongside the fields
    pub const json_tags = .{ .name = "name", .age = "age" };
};

const buf = try jz.Buffer.fromPool();
defer buf.returnToPool();

try jz.StructEncoder(MyPayload).marshal(&.{ .name = "Mr Payload", .age = 33, .id = 1 }, buf);
// buf.string() == {"name":"Mr Payload","age":33}
```

Slices work the same way: `try jz.SliceEncoder([]const []const u8).marshal(&slice, buf)`.

## Performance

Median ns/op on jingo's benchmark payloads. Every Zig encoder writes into one reused buffer and has its output
checked before it's timed. Apple M5 Max, Zig 0.17.0 `ReleaseFast`, Go 1.27.1. The full tables, the other libraries
and how it's all measured are in [PERFORMANCE.md](PERFORMANCE.md).

<!-- bench:summary -->
**SmallPayload**

| Lib | ns/op | B/op | allocs/op | vs std.json |
| --- | ---: | ---: | ---: | ---: |
| **jinzig** | 5.8 | 0 | 0 | 22.4x |
| jinzig, every string `,escape` | 13.7 | 0 | 0 | 9.5x |
| std.json | 131 | 0 | 0 | 1.0x |
| lalinsky-json | 29.1 | 0 | 0 | 4.5x |
| jaysan (never escapes) | 38.7 | 0 | 0 | 3.4x |
| jingo (go, for reference) | 53.6 | 0 | 0 | 2.4x |

**LargePayload**

| Lib | ns/op | B/op | allocs/op | vs std.json |
| --- | ---: | ---: | ---: | ---: |
| **jinzig** | 277 | 0 | 0 | 16.7x |
| jinzig, every string `,escape` | 1,143 | 0 | 0 | 4.0x |
| std.json | 4,618 | 0 | 0 | 1.0x |
| jaysan (never escapes) | 1,762 | 0 | 0 | 2.6x |
| lalinsky-json | 1,948 | 0 | 0 | 2.4x |
| jingo (go, for reference) | 2,770 | 0 | 0 | 1.7x |
<!-- /bench:summary -->

### Caveats

- **Strings aren't escaped unless you ask.** Like jingo, jinzig copies strings as they are, so a `"` or a newline in
  a field without `,escape` gives you invalid JSON. Every other library here escapes every string, always, except
  jaysan, which never does. The "every string `,escape`" rows are the like-for-like numbers: across every payload
  in [PERFORMANCE.md](PERFORMANCE.md), jinzig's lead over the next fastest escaping library is 1.2–2.7x rather
  than up to 6x.
- **The payloads are jingo's**: mostly strings and ints. Floats go through `std.fmt` as they do everywhere else, so
  float-heavy documents will narrow the gap.
- **They're microbenchmarks**: one payload in a hot loop. Real workloads could see different results.

## Tag options

Options follow the name, e.g. `.{ .when = "when,stringer" }`.

| Option | Effect |
| --- | --- |
| `,stringer` | writes the result of `pub fn string(self: *const T) []const u8`, quoted |
| `,encoder` | the field writes itself, via `pub fn jsonEncode(self: *const T, w: *jz.Buffer) jz.Error!void`, or `pub fn encodeJson(self: *const T, w: *std.Io.Writer) std.Io.Writer.Error!void` for a `std.Io.Writer` |
| `,raw` | writes a `[]const u8` as-is, with no quoting; empty (or not a byte slice) is `null` |
| `,escape` | escapes `"`, `\`, `\n`, `\r` and `\t`; works on strings and string slices. On its own, `SliceEncoder([]const jz.EscapeString)` escapes a `[]const []const u8` |

Strings are copied verbatim unless you ask for `,escape`, which is vectorised but still dearer than a plain copy.

## Buffers

`Buffer.fromPool()` (or `fromPoolWithCap(n)`) hands out a pooled buffer from a lock-free thread-local free list,
and `returnToPool()` gives it back; `Buffer.drainPool()` frees the lot. Buffers grow through `jz.buffer.allocator`
(`std.heap.smp_allocator` unless you swap it before first use), and `marshal` returns `error.OutOfMemory` if they
can't.

## How it works

jingo builds an instruction set with `reflect` when an encoder is created: static chunks for keys and braces, fast
paths for strings and ints, and functions at field offsets for everything else. jinzig builds the same plan from
`@typeInfo` at comptime and unrolls it, so `marshal` is straight-line code. Each run of keys, strings and ints
reserves its worst case once and writes through a cursor. Nested structs and slices call straight into their own
encoders, so recursion (direct or mutual) works at any depth.

## Limitations

- No maps, no omit-if-empty and no `,string` option (`,stringer` covers most uses).
- Unsupported field types are a `@compileError` naming the field.
- jingo's quirks are kept so the output stays identical: primitive arrays use `", "` separators, and `,stringer`
  on a null pointer writes `"null"` (quoted).

## Coming from jingo

| jingo | jinzig |
| --- | --- |
| `json:"name,opts"` | `pub const json_tags = .{ .field = "name,opts" }` |
| `NewStructEncoder(T{})` + `enc.Marshal(&v, buf)` | `try StructEncoder(T).marshal(&v, buf)` |
| `NewSliceEncoder([]T{})` + `enc.Marshal(&s, buf)` | `try SliceEncoder([]const T).marshal(&s, buf)` |
| `NewBufferFromPool`, `ReturnToPool` | `Buffer.fromPool`, `returnToPool` |
| `int`, `string`, `[]byte` | `isize`, `[]const u8`, `[]u8` |
| `*T` (nil → `null`) | `?*T` or `?T`, plus non-null `*T` with no null check |
| `time.Time` | `jz.Time`, built with `Time.date(...)`; RFC3339Nano output |

## Development

```sh
zig build test                          # unit, golden and nesting stress tests
GO111MODULE=off go run ./tools/golden   # regenerate tests/golden/*.json from ../jingo
./bench.sh                              # benchmarks; rewrites the tables here and in PERFORMANCE.md
```
