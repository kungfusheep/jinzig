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
