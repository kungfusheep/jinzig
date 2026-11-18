### jinzig vs Go jingo

Median ns/op over 3 runs each (±spread is half the min–max range as % of median).

| Benchmark | Go jingo | Zig jinzig | jinzig vs Go |
| --- | ---: | ---: | ---: |
| Unicode | 19.8 ±4% | 3.6 ±1% | **5.46x** |
| UnicodeLarge | 45.0 ±2% | 16.5 ±3% | **2.73x** |
| Time | 110 ±1% | 62.5 ±2% | **1.76x** |
| Slice | 32.4 ±2% | 5.8 ±1% | **5.58x** |
| SliceEscape | 69.7 ±1% | 17.3 ±0% | **4.03x** |
| Json | 2,081 ±1% | 315 ±0% | **6.61x** |
| SmallPayload | 53.6 ±1% | 5.8 ±0% | **9.20x** |
| LargePayload | 2,770 ±3% | 281 ±1% | **9.87x** |

Standard-library baselines (ns/op, B/op, allocs/op). Jingo/Jinzig are 0 B/op, 0 allocs/op on every row above.

| Baseline | Go encoding/json | Zig std.json | jingo vs encoding/json | jinzig vs std.json |
| --- | ---: | ---: | ---: | ---: |
| UnicodeStdLib | 158 / 112 B / 1 | 110 / 239 B / 2 | 8.0x | 30.3x |
| UnicodeLargeStdLib | 691 / 1281 B / 1 | 670 / 2426 B / 3 | 15.3x | 40.6x |
| TimeStdLib | 257 / 192 B / 1 | 211 / 642 B / 3 | 2.3x | 3.4x |
| SliceStdLib | 106 / 80 B / 1 | 80.4 / 201 B / 2 | 3.3x | 13.9x |
| StdJson | 4,565 / 4867 B / 1 | 3,248 / 12527 B / 8 | 2.2x | 10.3x |
| SmallPayloadStdLib | 216 / 144 B / 1 | 160 / 590 B / 3 | 4.0x | 27.5x |
| LargePayloadStdLib | 9,437 / 4867 B / 1 | 4,889 / 12028 B / 8 | 3.4x | 17.4x |

### Zig encoders, like for like

Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to
jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express
the payload (no custom-serialization hook, or no single-item pointer support). ✗ = wrong output, not timed.

| Payload | jinzig | std.json | serde.zig | zerde | lalinsky-json | jaysan | yyjson | zig-json | sakakibara-json | zserde | jsonz | fastest other | jinzig lead |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| Unicode | **3.2** | 90.7 | 104 | 55.9 | 25.1 | 16.9 | 44.1 | 163 | 50.8 | 133 | 31.5 | jaysan 16.9 | **5.23x** |
| UnicodeLarge | **15.8** | 596 | 201 | 519 | 67.8 | 36.2 | 232 | 555 | 123 | 1,976 | 101 | jaysan 36.2 | **2.30x** |
| Time | **59.2** | 186 | 153 | n/a | 69.6 | n/a | 107 | n/a | n/a | n/a | n/a | lalinsky-json 69.6 | **1.18x** |
| Slice | **5.2** | 62.1 | 69.6 | 39.6 | 44.5 | ✗ | 25.6 | 92.9 | 35.6 | 78.7 | 42.8 | yyjson 25.6 | **4.92x** |
| Json | **312** | 3,090 | 2,734 | n/a | 1,428 | n/a | 1,282 | n/a | n/a | n/a | n/a | yyjson 1,282 | **4.11x** |
| SmallPayload | **5.8** | 131 | 141 | 94.3 | 29.1 | 38.7 | 69.6 | 172 | 89.0 | 158 | 60.5 | lalinsky-json 29.1 | **4.98x** |
| LargePayload | **277** | 4,618 | 5,954 | 3,208 | 1,948 | 1,762 | 2,727 | 3,521 | n/a | 4,675 | n/a | jaysan 1,762 | **6.36x** |

Allocating at steady state: Zig/LargePayload/zig-json, Zig/Slice/zig-json, Zig/SmallPayload/zig-json, Zig/Unicode/zig-json, Zig/UnicodeLarge/zig-json

### Zig encoders, escaping every string (jinzig with `,escape` on all string fields)

Every library writes into one reused output buffer and is checked to emit jinzig's document (pinned to
jingo's golden output) before it is timed. Median ns/op; lower is better. n/a = the library can't express
the payload (no custom-serialization hook, or no single-item pointer support). ✗ = wrong output, not timed.

| Payload | jinzig | std.json | serde.zig | zerde | lalinsky-json | jaysan | yyjson | zig-json | sakakibara-json | zserde | jsonz | fastest other | jinzig lead |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| Unicode | **9.3** | 90.6 | 101 | 53.4 | 24.9 | n/a | 44.8 | 156 | 51.9 | 135 | 32.2 | lalinsky-json 24.9 | **2.68x** |
| UnicodeLarge | **50.5** | 599 | 197 | 517 | 67.7 | n/a | 232 | 518 | 129 | 1,979 | 101 | lalinsky-json 67.7 | **1.34x** |
| Slice | **16.6** | 62.2 | 69.6 | 39.9 | 44.3 | n/a | 25.4 | 94.7 | 35.9 | 79.6 | 42.4 | yyjson 25.4 | **1.53x** |
| Json | **1,053** | 3,211 | 2,811 | n/a | 1,447 | n/a | 1,275 | n/a | n/a | n/a | n/a | yyjson 1,275 | **1.21x** |
| SmallPayload | **13.7** | 132 | 137 | 93.5 | 29.2 | n/a | 70.8 | 160 | 86.6 | 153 | 59.0 | lalinsky-json 29.2 | **2.13x** |
| LargePayload | **1,143** | 4,613 | 6,320 | 3,194 | 1,951 | n/a | 2,744 | 3,557 | n/a | 4,616 | n/a | lalinsky-json 1,951 | **1.71x** |

Allocating at steady state: Esc/LargePayload/zig-json, Esc/Slice/zig-json, Esc/SmallPayload/zig-json, Esc/Unicode/zig-json, Esc/UnicodeLarge/zig-json
