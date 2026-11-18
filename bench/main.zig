//! benchmarks mirroring jingo_test.go, printed in `go test -bench` format so results can be compared
//! side by side. usage: jinzig-bench [-count N] [-benchtime MS] [-filter SUBSTR] [-probe-escaping]
//!
//! built with -Dcompetitors=true it also runs the Zig/<payload>/<lib> suite: jinzig, std.json,
//! serde.zig and zerde each writing into one reused output buffer, so every library is measured
//! at steady state with zero allocations.

const std = @import("std");
const jz = @import("jinzig");
const p = @import("payloads");
const bench_options = @import("bench_options");
const zerde = if (bench_options.competitors) @import("zerde") else void;
const serde = if (bench_options.competitors) @import("serde") else void;
const lalinsky_json = if (bench_options.competitors) @import("lalinsky_json") else void;
const jaysan = if (bench_options.competitors) @import("jaysan") else void;
const zig_json = if (bench_options.competitors) @import("zig_json") else void;
const sakakibara_json = if (bench_options.competitors) @import("sakakibara_json") else void;
const zserde = if (bench_options.competitors) @import("zserde") else void;
const jsonz = if (bench_options.competitors) @import("jsonz") else void;

const Counting = struct {
    parent: std.mem.Allocator,
    allocs: u64 = 0,
    bytes: u64 = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.allocs += 1;
        c.bytes += len;
        return c.parent.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const ok = c.parent.rawResize(m, a, n, ra);
        if (ok and n > m.len) c.bytes += n - m.len;
        return ok;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const r = c.parent.rawRemap(m, a, n, ra);
        if (r != null and n > m.len) {
            c.allocs += 1;
            c.bytes += n - m.len;
        }
        return r;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.parent.rawFree(m, a, ra);
    }
};

var counting: Counting = .{ .parent = std.heap.smp_allocator };
var io: std.Io = undefined;
var benchtime_ns: u64 = 1 * std.time.ns_per_s;
var filter: []const u8 = "";

fn now() i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// bench calibrates n the way testing.B does, then reports the final run
fn bench(name: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) anyerror!void) !void {
    if (std.mem.indexOf(u8, name, filter) == null) return;
    try f(ctx); // warm the pool and caches

    var n: u64 = 1;
    while (true) {
        const a0 = counting.allocs;
        const b0 = counting.bytes;
        const t0 = now();
        for (0..n) |_| try f(ctx);
        const ns: u64 = @intCast(now() - t0);

        if (ns >= benchtime_ns or n >= 1_000_000_000) {
            const nsop = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
            std.debug.print("Benchmark{s}\t{d:>10}\t{d:>10.2} ns/op\t{d:>8} B/op\t{d:>6} allocs/op\n", .{
                name,                      n,                          nsop,
                (counting.bytes - b0) / n, (counting.allocs - a0) / n,
            });
            return;
        }

        // predict the iterations needed, growing at most 100x, as go does
        const per: u64 = @max(ns / n, 1);
        var next = benchtime_ns * 6 / 5 / per;
        next = @max(@min(next, n * 100), n + 1);
        n = next;
    }
}

fn Pooled(comptime Enc: type, comptime V: type) type {
    return struct {
        enc: *const Enc,
        v: *const V,

        fn run(s: @This()) anyerror!void {
            const b = try jz.Buffer.fromPool();
            try s.enc.marshal(s.v, b);
            std.mem.doNotOptimizeAway(b.bytes.items.ptr);
            b.returnToPool();
        }
    };
}

fn Reset(comptime Enc: type, comptime V: type) type {
    return struct {
        enc: *const Enc,
        v: *const V,
        b: *jz.Buffer,

        fn run(s: @This()) anyerror!void {
            try s.enc.marshal(s.v, s.b);
            std.mem.doNotOptimizeAway(s.b.bytes.items.ptr);
            s.b.reset();
        }
    };
}

fn StdJson(comptime V: type) type {
    return struct {
        v: *const V,

        fn run(s: @This()) anyerror!void {
            const gpa = counting.allocator();
            const out = try std.json.Stringify.valueAlloc(gpa, s.v.*, .{});
            std.mem.doNotOptimizeAway(out.ptr);
            gpa.free(out);
        }
    };
}

fn pooled(name: []const u8, comptime T: type, v: *const T) !void {
    const enc = try jz.StructEncoder(T).init(std.heap.smp_allocator);
    defer enc.deinit();
    try bench(name, Pooled(jz.StructEncoder(T), T){ .enc = enc, .v = v }, Pooled(jz.StructEncoder(T), T).run);
}

fn pooledSlice(name: []const u8, comptime S: type, v: *const jz.SliceEncoder(S).Input) !void {
    const Enc = jz.SliceEncoder(S);
    const enc = try Enc.init(std.heap.smp_allocator);
    defer enc.deinit();
    try bench(name, Pooled(Enc, Enc.Input){ .enc = enc, .v = v }, Pooled(Enc, Enc.Input).run);
}

fn reset(name: []const u8, comptime T: type, v: *const T) !void {
    const enc = try jz.StructEncoder(T).init(std.heap.smp_allocator);
    defer enc.deinit();
    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    try bench(name, Reset(jz.StructEncoder(T), T){ .enc = enc, .v = v, .b = b }, Reset(jz.StructEncoder(T), T).run);
}

fn stdjson(name: []const u8, comptime T: type, v: *const T) !void {
    try bench(name, StdJson(T){ .v = v }, StdJson(T).run);
}

const Lib = enum {
    std_json,
    serde_zig,
    zerde,
    lalinsky_json,
    jaysan,
    zig_json,
    sakakibara_json,
    zserde,
    jsonz,

    fn name(l: Lib) []const u8 {
        return switch (l) {
            .std_json => "std.json",
            .serde_zig => "serde.zig",
            .zerde => "zerde",
            .lalinsky_json => "lalinsky-json",
            .jaysan => "jaysan",
            .zig_json => "zig-json",
            .sakakibara_json => "sakakibara-json",
            .zserde => "zserde",
            .jsonz => "jsonz",
        };
    }

    /// supports reports whether the library can express a payload at all: only std.json, serde.zig
    /// and lalinsky/json.zig have custom-serialization hooks, and sakakibara/json-zig and jsonz reject
    /// single-item pointer fields.
    fn supports(l: Lib, needs: Needs) bool {
        return switch (l) {
            .std_json, .serde_zig, .lalinsky_json => true,
            .zerde, .zserde, .zig_json => !needs.hooks,
            .jaysan => !needs.hooks and !needs.escaping,
            .sakakibara_json, .jsonz => !needs.hooks and !needs.single_ptrs,
        };
    }
};

/// escaping marks the escape-everything suite; jaysan never escapes, so it can't take part.
const Needs = struct { hooks: bool = false, single_ptrs: bool = false, escaping: bool = false };

fn Reused(comptime lib: Lib, comptime V: type) type {
    return struct {
        v: *const V,
        out: *std.Io.Writer.Allocating,
        arena: *std.heap.ArenaAllocator,

        fn run(s: @This()) anyerror!void {
            s.out.clearRetainingCapacity();
            const w = &s.out.writer;
            switch (lib) {
                .std_json => try std.json.Stringify.value(s.v, .{}, w),
                .serde_zig => try serde.json.toWriter(w, s.v),
                .zerde => try zerde.serialize(zerde.json, w, s.v),
                .lalinsky_json => try lalinsky_json.encode(s.v.*, w),
                .jaysan => try jaysan.json.stringify(s.v.*, w),
                .zig_json => {
                    // zig-json only offers an allocating stringify (a yyjson document per call)
                    const gpa = counting.allocator();
                    const bytes = try zig_json.stringify(gpa, s.v.*);
                    defer gpa.free(bytes);
                    try w.writeAll(bytes);
                },
                .sakakibara_json => {
                    defer _ = s.arena.reset(.retain_capacity);
                    try sakakibara_json.encodeTyped(w, s.v.*, s.arena.allocator(), .{});
                },
                .zserde => try zserde.json.toWriter(s.v.*, w, .{}),
                .jsonz => try jsonz.typed.toWriter(w, s.v.*, .{}),
            }
            std.mem.doNotOptimizeAway(s.out.written().ptr);
        }
    };
}

/// reused benchmarks a library writing into one reused buffer, but only after checking it emits the
/// same document as jinzig; a library that doesn't is reported as a MISMATCH rather than timed.
fn reused(name: []const u8, comptime lib: Lib, comptime V: type, v: *const V, want: []const u8) !void {
    if (std.mem.indexOf(u8, name, filter) == null) return;
    var out: std.Io.Writer.Allocating = .init(counting.allocator());
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(counting.allocator());
    defer arena.deinit();
    const ctx = Reused(lib, V){ .v = v, .out = &out, .arena = &arena };

    try Reused(lib, V).run(ctx);
    // the one known divergence: std.json widens f32 to f64 precision
    const widened = "\"propFloat32\":21.232425689697266,";
    const ok = std.mem.eql(u8, out.written(), want) or (lib == .std_json and
        std.mem.indexOf(u8, out.written(), widened) != null and out.written().len == want.len + widened.len - "\"propFloat32\":21.232426,".len);
    if (!ok) {
        const at = std.mem.indexOfDiff(u8, out.written(), want) orelse 0;
        const from = at -| 24;
        std.debug.print("Benchmark{s}\tMISMATCH at byte {d}: got \"{s}\" want \"{s}\"\n", .{
            name, at, out.written()[@min(from, out.written().len)..@min(at + 24, out.written().len)], want[@min(from, want.len)..@min(at + 24, want.len)],
        });
        return;
    }
    try bench(name, ctx, Reused(lib, V).run);
}

/// jinzigOutput renders the document jinzig produces for a payload; tests pin it to jingo's golden output.
fn jinzigOutput(comptime J: type, v: anytype) ![]u8 {
    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    if (comptime @typeInfo(J) == .pointer) {
        const enc = try jz.SliceEncoder(J).init(std.heap.smp_allocator);
        defer enc.deinit();
        try enc.marshal(v, b);
    } else {
        const enc = try jz.StructEncoder(J).init(std.heap.smp_allocator);
        defer enc.deinit();
        try enc.marshal(v, b);
    }
    return std.heap.smp_allocator.dupe(u8, b.string());
}

fn resetSlice(name: []const u8, comptime S: type, v: *const jz.SliceEncoder(S).Input) !void {
    const Enc = jz.SliceEncoder(S);
    const enc = try Enc.init(std.heap.smp_allocator);
    defer enc.deinit();
    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    try bench(name, Reset(Enc, Enc.Input){ .enc = enc, .v = v, .b = b }, Reset(Enc, Enc.Input).run);
}

/// zigSuite runs one payload through every zig encoder that can express it.
/// J is the type jinzig encodes with (a struct, or a slice type like []const EscapeString) and V the
/// value type every library receives; they only differ for SliceEncoder's EscapeString marker.
fn zigSuite(comptime suite: []const u8, comptime label: []const u8, comptime J: type, comptime V: type, v: *const V, comptime needs: Needs) !void {
    const prefix = suite ++ "/" ++ label ++ "/";
    if (comptime @typeInfo(J) == .pointer) {
        try resetSlice(prefix ++ "jinzig", J, v);
    } else {
        try reset(prefix ++ "jinzig", J, v);
    }

    const want = try jinzigOutput(J, v);
    defer std.heap.smp_allocator.free(want);
    inline for (comptime std.enums.values(Lib)) |lib| {
        if (comptime (lib == .std_json or bench_options.competitors) and lib.supports(needs)) {
            try reused(prefix ++ comptime lib.name(), lib, V, v, want);
        }
    }
}

/// probeEscaping prints what each library emits for a string that must be escaped.
fn probeEscaping() !void {
    if (!bench_options.competitors) return;
    const Probe = struct { s: []const u8 };
    const v: Probe = .{ .s = "a\"b\\c\nd" };
    inline for (comptime std.enums.values(Lib)) |lib| {
        var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
        defer out.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer arena.deinit();
        try Reused(lib, Probe).run(.{ .v = &v, .out = &out, .arena = &arena });
        std.debug.print("{s:<16} {s}\n", .{ lib.name(), out.written() });
    }
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    jz.buffer.allocator = counting.allocator();

    var count: usize = 1;
    var probe = false;
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-count")) {
            count = try std.fmt.parseInt(usize, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "-benchtime")) {
            benchtime_ns = try std.fmt.parseInt(u64, it.next() orelse return error.MissingValue, 10) * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, arg, "-probe-escaping")) {
            probe = true;
        } else if (std.mem.eql(u8, arg, "-filter")) {
            filter = it.next() orelse return error.MissingValue;
        } else return error.UnknownArgument;
    }

    std.debug.print("mode: {s}\n", .{@tagName(jz.mode)});
    if (probe) return probeEscaping();

    const slice_strings: []const []const u8 = &p.slice_strings;
    for (0..count) |_| {
        try pooled("Unicode", p.UnicodeObject, &p.unicode);
        try stdjson("UnicodeStdLib", p.UnicodeObject, &p.unicode);
        try pooled("UnicodeLarge", p.UnicodeObjectLarge, &p.unicode_large);
        try stdjson("UnicodeLargeStdLib", p.UnicodeObjectLarge, &p.unicode_large);
        try pooled("Time", p.TimeObject, &p.time_object);
        try stdjson("TimeStdLib", p.TimeObject, &p.time_object);
        try pooledSlice("Slice", []const []const u8, &slice_strings);
        try pooledSlice("SliceEscape", []const jz.EscapeString, &slice_strings);
        try stdjson("SliceStdLib", []const []const u8, &slice_strings);
        try pooled("Json", p.All, &p.fake);
        try stdjson("StdJson", p.All, &p.fake);
        try reset("SmallPayload", p.SmallPayload, &p.small_payload);
        try stdjson("SmallPayloadStdLib", p.SmallPayload, &p.small_payload);
        try reset("LargePayload", p.LargePayload, &p.large_payload);
        try stdjson("LargePayloadStdLib", p.LargePayload, &p.large_payload);

        if (bench_options.competitors) {
            try zigSuite("Zig", "Unicode", p.UnicodeObject, p.UnicodeObject, &p.unicode, .{});
            try zigSuite("Zig", "UnicodeLarge", p.UnicodeObjectLarge, p.UnicodeObjectLarge, &p.unicode_large, .{});
            try zigSuite("Zig", "Time", p.TimeObject, p.TimeObject, &p.time_object, .{ .hooks = true, .single_ptrs = true });
            try zigSuite("Zig", "Slice", []const []const u8, []const []const u8, &slice_strings, .{});
            try zigSuite("Zig", "Json", p.All, p.All, &p.fake, .{ .hooks = true, .single_ptrs = true });
            try zigSuite("Zig", "SmallPayload", p.SmallPayload, p.SmallPayload, &p.small_payload, .{});
            try zigSuite("Zig", "LargePayload", p.LargePayload, p.LargePayload, &p.large_payload, .{ .single_ptrs = true });

            // escaping on for every string: jinzig does the same escape scan the others always do
            const e = p.escaped;
            try zigSuite("Esc", "Unicode", e.UnicodeObject, e.UnicodeObject, &e.unicode, .{ .escaping = true });
            try zigSuite("Esc", "UnicodeLarge", e.UnicodeObjectLarge, e.UnicodeObjectLarge, &e.unicode_large, .{ .escaping = true });
            try zigSuite("Esc", "Slice", []const jz.EscapeString, []const []const u8, &slice_strings, .{ .escaping = true });
            try zigSuite("Esc", "Json", e.All, e.All, &e.fake, .{ .hooks = true, .single_ptrs = true, .escaping = true });
            try zigSuite("Esc", "SmallPayload", e.SmallPayload, e.SmallPayload, &e.small_payload, .{ .escaping = true });
            try zigSuite("Esc", "LargePayload", e.LargePayload, e.LargePayload, &e.large_payload, .{ .single_ptrs = true, .escaping = true });
        }
    }
}
