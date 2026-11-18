//! buffer.zig manages Buffer and its responsibilities.
//! Its existence is justified by the performance increase gained
//! over more general implementations and the fact that we allow
//! these buffers to be pooled, which reduces our allocation
//! profile quite significantly.

const std = @import("std");

pub const Error = std.mem.Allocator.Error;

/// allocator backing every pooled buffer. swap it before first use if you need to (e.g. to count allocations).
pub var allocator: std.mem.Allocator = std.heap.smp_allocator;

/// Buffer is used to pass on to the encoders marshal methods.
pub const Buffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    next: ?*Buffer = null, // intrusive pool link

    /// write a chunk of bytes to the buffer. short runtime-sized chunks (field values, digits) use
    /// copyShort's overlapping stores; long ones go straight to memcpy.
    pub inline fn write(b: *Buffer, v: []const u8) Error!void {
        try b.bytes.ensureUnusedCapacity(allocator, v.len);
        const n = b.bytes.items.len;
        b.bytes.items.len = n + v.len;
        const dst = b.bytes.items.ptr + n;
        if (v.len > 32) @memcpy(dst[0..v.len], v) else copyShort(dst, v);
    }

    /// writeStatic writes a comptime-known chunk (keys, braces, literals). its length is a constant,
    /// so the copy is a fixed-size store the compiler inlines; write can't know that about a slice.
    pub inline fn writeStatic(b: *Buffer, comptime v: []const u8) Error!void {
        try b.bytes.ensureUnusedCapacity(allocator, v.len);
        const n = b.bytes.items.len;
        b.bytes.items.len = n + v.len;
        b.bytes.items[n..][0..v.len].* = v[0..v.len].*;
    }

    /// writeByte writes a single byte into the output buffer
    pub inline fn writeByte(b: *Buffer, v: u8) Error!void {
        try b.bytes.append(allocator, v);
    }

    /// reset allows this to be reused by emptying
    pub fn reset(b: *Buffer) void {
        b.bytes.clearRetainingCapacity();
    }

    pub fn string(b: *const Buffer) []const u8 {
        return b.bytes.items;
    }

    /// writeTo writes the contents of our buffer to a std.Io.Writer
    pub fn writeTo(b: *const Buffer, w: *std.Io.Writer) std.Io.Writer.Error!usize {
        try w.writeAll(b.bytes.items);
        return b.bytes.items.len;
    }

    /// writer exposes the buffer as a std.Io.Writer for the duration of `f`, mirroring
    /// Buffer's io.Writer compatibility in jingo.
    pub fn withWriter(b: *Buffer, ctx: anytype, comptime f: fn (@TypeOf(ctx), *std.Io.Writer) std.Io.Writer.Error!void) Error!void {
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &b.bytes);
        defer b.bytes = aw.toArrayList();
        f(ctx, &aw.writer) catch return error.OutOfMemory;
    }

    /// fromPool returns a pointer to a zeroed Buffer. This may be retrieved from a
    /// pool. When you're done with it, call `returnToPool`.
    pub fn fromPool() Error!*Buffer {
        const b = pool orelse return newBuffer();
        pool = b.next;
        b.reset();
        return b;
    }

    /// fromPoolWithCap returns a pointer to a zeroed Buffer with its underlying
    /// capacity set. This may be retrieved from a pool. When you're done with it, call `returnToPool`.
    pub fn fromPoolWithCap(size: usize) Error!*Buffer {
        const b = try fromPool();
        try b.bytes.ensureTotalCapacity(allocator, size);
        return b;
    }

    /// returnToPool puts this instance back in the underlying pool. Reading from or using this instance
    /// in any way after calling this is invalid.
    pub fn returnToPool(b: *Buffer) void {
        b.next = pool;
        pool = b;
    }

    /// drainPool frees every buffer held by the calling thread's pool.
    pub fn drainPool() void {
        while (pool) |b| {
            pool = b.next;
            b.bytes.deinit(allocator);
            allocator.destroy(b);
        }
    }

    fn newBuffer() Error!*Buffer {
        const b = try allocator.create(Buffer);
        b.* = .{};
        return b;
    }
};

/// copyShort covers [0, len) for len <= 32 with at most two overlapping stores, never writing past len.
fn copyShort(dst: [*]u8, src: []const u8) void {
    const len = src.len;
    if (len >= 16) {
        const V = @Vector(16, u8);
        const head: V = src[0..16].*;
        const tail: V = src[len - 16 ..][0..16].*;
        dst[0..16].* = head;
        dst[len - 16 ..][0..16].* = tail;
    } else if (len >= 8) {
        const head = std.mem.readInt(u64, src[0..8], .little);
        const tail = std.mem.readInt(u64, src[len - 8 ..][0..8], .little);
        std.mem.writeInt(u64, dst[0..8], head, .little);
        std.mem.writeInt(u64, dst[len - 8 ..][0..8], tail, .little);
    } else if (len >= 4) {
        const head = std.mem.readInt(u32, src[0..4], .little);
        const tail = std.mem.readInt(u32, src[len - 4 ..][0..4], .little);
        std.mem.writeInt(u32, dst[0..4], head, .little);
        std.mem.writeInt(u32, dst[len - 4 ..][0..4], tail, .little);
    } else if (len > 0) {
        dst[0] = src[0];
        dst[len / 2] = src[len / 2];
        dst[len - 1] = src[len - 1];
    }
}

// per-thread free list plays the role of sync.Pool's per-P caches, without any locking
threadlocal var pool: ?*Buffer = null;
