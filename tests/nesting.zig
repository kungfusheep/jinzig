//! nesting.zig stress tests nested encoders. randomly shaped struct types are generated at comptime,
//! filled with random values at runtime, and every document is checked against std.json, which
//! shares no code with jinzig. values stay inside what both encode identically: no floats (std.json
//! formats them differently), no fixed arrays (jingo's ", " spacing) and no characters that need escaping.

const std = @import("std");
const testing = std.testing;
const jz = @import("jinzig");

fn expectMatchesStdJson(comptime T: type, v: *const T) !void {
    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();

    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    try jz.StructEncoder(T).marshal(v, b);

    const want = try std.json.Stringify.valueAlloc(testing.allocator, v.*, .{});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, b.string());
}

/// mix is splitmix64, so every comptime choice is a pure function of its seed
fn mix(comptime x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// pick chooses a field type: a leaf, or (while depth remains) one of the ways to nest another Node
fn Pick(comptime seed: u64, comptime depth: u32) type {
    const leaves = [_]type{ isize, []const u8, bool, ?isize, i32, u16, ?[]const u8, u64, []const isize, []const []const u8, []const ?*const []const u8 };
    const r = mix(seed);
    if (depth == 0 or r % 3 != 0) return leaves[(r >> 8) % leaves.len];
    const N = Node(mix(seed ^ 0x5bd1e995), depth - 1);
    const nested = [_]type{ N, ?*const N, *const N, []const N, []const ?*const N, ?N, []const []const N };
    return nested[(r >> 16) % nested.len];
}

fn Node(comptime seed: u64, comptime depth: u32) type {
    return struct {
        a: Pick(seed +% 1, depth),
        b: Pick(seed +% 2, depth),
        c: Pick(seed +% 3, depth),
        d: Pick(seed +% 4, depth),
        e: Pick(seed +% 5, depth),
        f: Pick(seed +% 6, depth),
        pub const json_tags = .{ .a = "a", .b = "b", .c = "c", .d = "d", .e = "e", .f = "f" };
    };
}

const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.";

/// fill makes a random value of T. strings run to 100 bytes so every copy path (short, 33-64, memcpy) is hit
fn fill(comptime T: type, r: std.Random, a: std.mem.Allocator) !T {
    switch (@typeInfo(T)) {
        .int => return switch (r.uintLessThan(u8, 4)) {
            0 => std.math.minInt(T),
            1 => std.math.maxInt(T),
            2 => @intCast(r.uintLessThan(u8, 10)),
            else => r.int(T),
        },
        .bool => return r.boolean(),
        .optional => |o| return if (r.uintLessThan(u8, 3) == 0) null else try fill(o.child, r, a),
        .pointer => |p| switch (p.size) {
            .one => {
                const x = try a.create(p.child);
                x.* = try fill(p.child, r, a);
                return x;
            },
            .slice => {
                if (p.child == u8) {
                    const s = try a.alloc(u8, r.uintAtMost(usize, 100));
                    for (s) |*c| c.* = alnum[r.uintLessThan(usize, alnum.len)];
                    return s;
                }
                const s = try a.alloc(p.child, r.uintAtMost(usize, 4));
                for (s) |*x| x.* = try fill(p.child, r, a);
                return s;
            },
            else => @compileError("fill: " ++ @typeName(T)),
        },
        .@"struct" => |s| {
            var v: T = undefined;
            inline for (s.field_names, s.field_types) |name, F| @field(v, name) = try fill(F, r, a);
            return v;
        },
        else => @compileError("fill: " ++ @typeName(T)),
    }
}

test "random nested shapes match std.json" {
    @setEvalBranchQuota(1_000_000);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x6a696e7a6967);

    inline for (0..32) |i| {
        const T = Node(mix(i), 3);
        for (0..25) |_| {
            _ = arena.reset(.retain_capacity);
            const v = try fill(T, prng.random(), arena.allocator());
            try expectMatchesStdJson(T, &v);
        }
    }
}

fn Chain(comptime n: usize) type {
    if (n == 0) return struct {
        leaf: []const u8,
        pub const json_tags = .{ .leaf = "leaf" };
    };
    return struct {
        depth: isize,
        next: Chain(n - 1),
        opt: ?*const Chain(n - 1),
        many: []const Chain(n - 1),
        pub const json_tags = .{ .depth = "depth", .next = "next", .opt = "opt", .many = "many" };
    };
}

/// chain fills at most one of opt and many per level: fill's three-plus children per level would
/// make a twelve-deep value millions of nodes, and this test is about the depth of the type
fn chain(comptime n: usize, r: std.Random, a: std.mem.Allocator) !Chain(n) {
    if (n == 0) return .{ .leaf = "leaf" };
    const next = try chain(n - 1, r, a);
    const pick = r.uintLessThan(u8, 3);
    return .{
        .depth = n,
        .next = next,
        .opt = if (pick == 1) try chainPtr(n - 1, r, a) else null,
        .many = if (pick == 2) (try chainPtr(n - 1, r, a))[0..1] else &.{},
    };
}

fn chainPtr(comptime n: usize, r: std.Random, a: std.mem.Allocator) !*Chain(n) {
    const p = try a.create(Chain(n));
    p.* = try chain(n, r, a);
    return p;
}

test "a chain of twelve distinct nested types" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(12);
    const T = Chain(12);
    for (0..10) |_| {
        _ = arena.reset(.retain_capacity);
        const v = try chain(12, prng.random(), arena.allocator());
        try expectMatchesStdJson(T, &v);
    }
}

test "encoding allocates nothing once the buffer has room" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(12);
    const v = try chain(12, prng.random(), arena.allocator());

    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();
    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    _ = try b.reserve(1 << 20);

    jz.buffer.allocator = testing.failing_allocator;
    defer jz.buffer.allocator = testing.allocator;
    try jz.StructEncoder(Chain(12)).marshal(&v, b);
    try testing.expect(b.string().len > 1000);
}

const Rec = struct {
    name: []const u8,
    child: ?*const Rec,
    pub const json_tags = .{ .name = "name", .child = "child" };
};

test "self recursion ten thousand levels deep" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const depth = 10_000;
    var head: ?*const Rec = null;
    for (0..depth) |_| {
        const n = try a.create(Rec);
        n.* = .{ .name = "n", .child = head };
        head = n;
    }
    var want: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try want.appendSlice(a, "{\"name\":\"n\",\"child\":");
    try want.appendSlice(a, "null");
    for (0..depth) |_| try want.append(a, '}');

    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();
    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    try jz.StructEncoder(Rec).marshal(head.?, b);
    try testing.expectEqualStrings(want.items, b.string());
}

const MutualA = struct {
    name: []const u8,
    b: ?*const MutualB,
    bs: []const MutualB,
    pub const json_tags = .{ .name = "name", .b = "b", .bs = "bs" };
};

const MutualB = struct {
    n: isize,
    a: ?*const MutualA,
    pub const json_tags = .{ .n = "n", .a = "a" };
};

test "mutual recursion" {
    const leaf: MutualA = .{ .name = "leaf", .b = null, .bs = &.{} };
    const b1: MutualB = .{ .n = 1, .a = &leaf };
    const b2: MutualB = .{ .n = 2, .a = null };
    const mid: MutualA = .{ .name = "mid", .b = &b1, .bs = &.{ b1, b2 } };
    const top: MutualB = .{ .n = 0, .a = &mid };
    try expectMatchesStdJson(MutualB, &top);
}
