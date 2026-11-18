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
