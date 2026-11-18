//! ptrconvert.zig declares a number of primitive form -> buffer conversion
//! functions based on a type-erased pointer input, mirroring jingo's unsafe.Pointer converters.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Error = @import("buffer.zig").Error;

pub const Conv = *const fn (v: *const anyopaque, w: *Buffer) Error!void;

pub const null_lit = "null";

/// typeconv returns the converter for a primitive type, or null when it isn't one. it replaces
/// jingo's map[reflect.Kind] lookup with a comptime switch.
pub fn typeconv(comptime T: type) ?Conv {
    return switch (@typeInfo(T)) {
        .bool => &ptrBoolToBuf,
        .int => |i| if (i.bits <= 64) &PtrIntToBuf(T).conv else null,
        .float => |f| if (f.bits == 32 or f.bits == 64) &PtrFloatToBuf(T).conv else null,
        else => if (isString(T)) &ptrStringToBuf else null,
    };
}

/// isString reports whether T is a byte slice, zig's equivalent of a go string.
pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

inline fn as(comptime T: type, v: *const anyopaque) *const T {
    return @ptrCast(@alignCast(v));
}

pub fn ptrBoolToBuf(v: *const anyopaque, w: *Buffer) Error!void {
    try w.write(if (as(bool, v).*) "true" else "false");
}

pub fn PtrIntToBuf(comptime T: type) type {
    return struct {
        pub fn conv(v: *const anyopaque, w: *Buffer) Error!void {
            try appendInt(w, as(T, v).*);
        }
    };
}

pub fn PtrFloatToBuf(comptime T: type) type {
    return struct {
        pub fn conv(v: *const anyopaque, w: *Buffer) Error!void {
            var buf: [std.fmt.float.bufferSize(.decimal, T)]u8 = undefined;
            // shortest round-trip decimal form, identical to strconv.AppendFloat(.., 'f', -1, bits)
            const s = std.fmt.float.render(&buf, as(T, v).*, .{ .mode = .decimal }) catch unreachable;
            try w.write(s);
        }
    };
}

pub fn ptrStringToBuf(v: *const anyopaque, w: *Buffer) Error!void {
    try w.write(as([]const u8, v).*);
}

pub fn ptrTimeToBuf(v: *const anyopaque, w: *Buffer) Error!void {
    try as(Time, v).appendRfc3339Nano(w);
}

pub fn ptrEscapeStringToBuf(v: *const anyopaque, w: *Buffer) Error!void {
    try escapeString(w, as([]const u8, v).*);
}

const lanes = 16;
const Block = @Vector(lanes, u8);

/// hits flags the bytes jingo escapes: `"`, `\`, line feed, carriage return and tab.
inline fn hits(b: Block) @Vector(lanes, bool) {
    return (b == @as(Block, @splat('"'))) | (b == @as(Block, @splat('\\'))) |
        (b == @as(Block, @splat('\n'))) | (b == @as(Block, @splat('\r'))) | (b == @as(Block, @splat('\t')));
}

const Mask = @Int(.unsigned, lanes);

/// screen is a cheaper superset of hits (`"`, `\` and every control byte): three compares instead of
/// five. clean blocks only ever pay for the screen; flagged blocks get the exact check.
inline fn screen(b: Block) @Vector(lanes, bool) {
    return (b == @as(Block, @splat('"'))) | (b == @as(Block, @splat('\\'))) | (b < @as(Block, @splat(0x20)));
}

/// escapeString scans 32 bytes per iteration with a single reduce, then finishes with one or two
/// 16-byte blocks, the last overlapping the end. clean runs are only copied when an escape (or the
/// end) is reached, so a clean string is one write.
pub fn escapeString(w: *Buffer, bs: []const u8) Error!void {
    if (bs.len < lanes) return escapeShort(w, bs);

    var pos: usize = 0; // start of the pending clean run
    var i: usize = 0;
    while (i + 2 * lanes <= bs.len) : (i += 2 * lanes) {
        const a: Block = bs[i..][0..lanes].*;
        const b: Block = bs[i + lanes ..][0..lanes].*;
        if (!@reduce(.Or, screen(a) | screen(b))) continue;
        try escapeBlock(w, bs, &pos, i, a, 0);
        try escapeBlock(w, bs, &pos, i + lanes, b, 0);
    }
    while (i < bs.len) : (i += lanes) {
        const base = if (i + lanes <= bs.len) i else bs.len - lanes;
        const blk: Block = bs[base..][0..lanes].*;
        if (!@reduce(.Or, screen(blk))) continue;
        try escapeBlock(w, bs, &pos, base, blk, i - base);
    }

    if (pos < bs.len) try w.write(bs[pos..]);
}

/// escapeBlock writes the exact escapes in a block the screen flagged, ignoring the first `skip` lanes
/// (already scanned by the previous, overlapped block). out of line: flagged blocks are the rare path.
noinline fn escapeBlock(w: *Buffer, bs: []const u8, pos: *usize, base: usize, blk: Block, skip: usize) Error!void {
    var mask: Mask = @bitCast(hits(blk));
    mask &= ~((@as(Mask, 1) << @intCast(skip)) - 1);
    while (mask != 0) : (mask &= mask - 1) {
        const j = base + @ctz(mask);
        if (pos.* < j) try w.write(bs[pos.*..j]);
        try w.write(escapeSeq(bs[j]));
        pos.* = j + 1;
    }
}

/// swarHits reports whether any byte of x is one jingo escapes, using the exact "has zero byte" test
/// on x xor each target. zero padding never matches, since 0 xor c != 0 for every target.
inline fn swarHits(x: u64) bool {
    const ones: u64 = 0x0101010101010101;
    const highs: u64 = 0x8080808080808080;
    var acc: u64 = 0;
    inline for (.{ '"', '\\', '\n', '\r', '\t' }) |c| {
        const y = x ^ (ones * c);
        acc |= (y -% ones) & ~y & highs;
    }
    return acc != 0;
}

/// escapeShort handles strings shorter than one block, where a vector load would over-read. overlapping
/// word loads cover every byte without reading past the end, so a clean string costs one check and one write.
fn escapeShort(w: *Buffer, bs: []const u8) Error!void {
    const n = bs.len;
    const dirty = if (n >= 8)
        swarHits(std.mem.readInt(u64, bs[0..8], .little)) or swarHits(std.mem.readInt(u64, bs[n - 8 ..][0..8], .little))
    else if (n >= 4)
        swarHits(std.mem.readInt(u32, bs[0..4], .little) | @as(u64, std.mem.readInt(u32, bs[n - 4 ..][0..4], .little)) << 32)
    else blk: {
        var x: u64 = 0;
        for (bs, 0..) |c, i| x |= @as(u64, c) << @intCast(i * 8);
        break :blk swarHits(x);
    };
    if (!dirty) return w.write(bs);

    var pos: usize = 0;
    for (bs, 0..) |c, i| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => {},
            else => continue,
        }
        if (pos < i) try w.write(bs[pos..i]);
        try w.write(escapeSeq(c));
        pos = i + 1;
    }
    if (pos < bs.len) try w.write(bs[pos..]);
}

inline fn escapeSeq(c: u8) []const u8 {
    return switch (c) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        else => "\\t",
    };
}

const digit_pairs = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[i * 2] = '0' + i / 10;
        t[i * 2 + 1] = '0' + i % 10;
    }
    break :blk t;
};

/// max_int_len bounds putInt's output for any integer up to 64 bits: 20 digits, or "-" and 19.
pub const max_int_len = 20;

/// appendInt writes the base 10 form of any integer up to 64 bits.
pub fn appendInt(w: *Buffer, value: anytype) Error!void {
    w.commit(putInt(try w.reserve(max_int_len), value));
}

/// putInt writes the base 10 form of value at d, two digits at a time like strconv, and returns the
/// cursor past it. the caller guarantees max_int_len bytes of room.
pub inline fn putInt(d: [*]u8, value: anytype) [*]u8 {
    const T = @TypeOf(value);
    var out = d;
    var u: u64 = if (@typeInfo(T).int.signedness == .signed) @abs(value) else value;
    if (@typeInfo(T).int.signedness == .signed and value < 0) {
        out[0] = '-';
        out += 1;
    }
    if (u < 10) {
        out[0] = '0' + @as(u8, @intCast(u));
        return out + 1;
    }

    const n = digitCount(u);
    var i = n;
    while (u >= 100) {
        const p: usize = @intCast((u % 100) * 2);
        u /= 100;
        i -= 2;
        out[i..][0..2].* = digit_pairs[p..][0..2].*;
    }
    if (u >= 10) {
        out[0..2].* = digit_pairs[@as(usize, @intCast(u * 2))..][0..2].*;
    } else {
        out[0] = '0' + @as(u8, @intCast(u));
    }
    return out + n;
}

/// digitCount estimates the digits from the bit length (1233/4096 ≈ log10 2), then corrects by one.
inline fn digitCount(u: u64) usize {
    const bits = 64 - @as(usize, @clz(u));
    const guess = (bits * 1233) >> 12;
    return guess + 1 - @intFromBool(u < pow10[guess]);
}

const pow10 = blk: {
    var t: [20]u64 = undefined;
    t[0] = 1;
    for (1..20) |i| t[i] = t[i - 1] * 10;
    break :blk t;
};

/// Time is a minimal stand-in for go's time.Time: an instant plus a fixed zone offset, which is all
/// RFC3339Nano output needs.
pub const Time = struct {
    sec: i64, // seconds since the unix epoch
    nsec: u32 = 0,
    offset: i32 = 0, // seconds east of UTC

    /// date mirrors time.Date(.., time.UTC)
    pub fn date(year: i32, month: u8, day: u8, hour: u8, min: u8, sec: u8, nsec: u32) Time {
        const days = daysFromCivil(year, month, day);
        return .{ .sec = days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + sec, .nsec = nsec };
    }

    /// appendRfc3339Nano matches time.RFC3339Nano: "2006-01-02T15:04:05.999999999Z07:00"
    pub fn appendRfc3339Nano(t: Time, w: *Buffer) Error!void {
        var buf: [max_rfc3339_len]u8 = undefined;
        try w.write(t.formatRfc3339Nano(&buf));
    }

    pub const max_rfc3339_len = 48;

    /// formatRfc3339Nano renders into a caller-provided buffer, so no path needs to allocate.
    pub fn formatRfc3339Nano(t: Time, buf: *[max_rfc3339_len]u8) []const u8 {
        const local = t.sec + t.offset;
        const days = @divFloor(local, 86400);
        const secs: u32 = @intCast(local - days * 86400);
        const c = civilFromDays(days);

        var n: usize = 0;
        if (c.year >= 0 and c.year <= 9999) {
            put4(buf, &n, @intCast(c.year));
        } else {
            n += (std.fmt.bufPrint(buf[n..], "{d}", .{c.year}) catch unreachable).len;
        }
        buf[n] = '-';
        n += 1;
        put2(buf, &n, c.month);
        buf[n] = '-';
        n += 1;
        put2(buf, &n, c.day);
        buf[n] = 'T';
        n += 1;
        put2(buf, &n, secs / 3600);
        buf[n] = ':';
        n += 1;
        put2(buf, &n, secs / 60 % 60);
        buf[n] = ':';
        n += 1;
        put2(buf, &n, secs % 60);

        if (t.nsec != 0) {
            // .999999999 trims trailing zeros
            var frac: [9]u8 = undefined;
            var ns = t.nsec;
            var k: usize = 9;
            while (k > 0) {
                k -= 1;
                frac[k] = '0' + @as(u8, @intCast(ns % 10));
                ns /= 10;
            }
            var end: usize = 9;
            while (frac[end - 1] == '0') end -= 1;
            buf[n] = '.';
            n += 1;
            @memcpy(buf[n..][0..end], frac[0..end]);
            n += end;
        }

        if (t.offset == 0) {
            buf[n] = 'Z';
            n += 1;
        } else {
            buf[n] = if (t.offset < 0) '-' else '+';
            n += 1;
            const off: u32 = @abs(t.offset) / 60;
            put2(buf, &n, off / 60);
            buf[n] = ':';
            n += 1;
            put2(buf, &n, off % 60);
        }

        return buf[0..n];
    }

    /// jsonStringify lets std.json emit the same representation, for like-for-like benchmarks.
    pub fn jsonStringify(t: Time, jw: anytype) !void {
        var buf: [max_rfc3339_len]u8 = undefined;
        try jw.write(t.formatRfc3339Nano(&buf));
    }

    /// jsonWrite is lalinsky/json.zig's equivalent hook.
    pub fn jsonWrite(t: Time, encoder: anytype) !void {
        var buf: [max_rfc3339_len]u8 = undefined;
        try encoder.write(t.formatRfc3339Nano(&buf));
    }

    /// zerdeSerialize is serde.zig's equivalent hook.
    pub fn zerdeSerialize(t: Time, s: anytype) @TypeOf(s.*).Error!void {
        var buf: [max_rfc3339_len]u8 = undefined;
        try s.serializeString(t.formatRfc3339Nano(&buf));
    }
};

fn put2(buf: []u8, n: *usize, v: u32) void {
    buf[n.*..][0..2].* = digit_pairs[v * 2 ..][0..2].*;
    n.* += 2;
}

fn put4(buf: []u8, n: *usize, v: u32) void {
    put2(buf, n, v / 100);
    put2(buf, n, v % 100);
}

// howard hinnant's civil calendar algorithms, valid for the full proleptic gregorian range
fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { year: i64, month: u32, day: u32 };

fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}
