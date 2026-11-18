//! slice_encoder.zig manages SliceEncoder and its responsibilities.
//! SliceEncoder follows the same principle of struct_encoder.zig in that every decision about the
//! element type is made at comptime, leaving a single loop over the elements at runtime. Slices are
//! of variable length, so unlike a struct the iteration itself can't be unrolled.

const std = @import("std");
const buffer = @import("buffer.zig");
const pc = @import("ptrconvert.zig");
const se = @import("struct_encoder.zig");

const Buffer = buffer.Buffer;
const Error = buffer.Error;
const Conv = pc.Conv;
const Time = pc.Time;
const EscapeString = se.EscapeString;

const Variant = enum {
    time,
    escape_string,
    slice,
    strct,
    string,
    other,
    ptr_time,
    ptr_escape_string,
    ptr_slice,
    ptr_strct,
    ptr_string,
    ptr_other,
};

/// SliceEncoder stores an instruction for building a JSON document from a slice at runtime.
pub fn SliceEncoder(comptime S: type) type {
    const info = @typeInfo(S);
    if (info != .pointer or info.pointer.size != .slice) @compileError("SliceEncoder requires a slice, got " ++ @typeName(S));
    const E = info.pointer.child;
    const Ptr = se.Indirect(E);

    // see if we can select based on a specific type, then on what type of encoding we need
    const variant: Variant = if (E == Time)
        .time
    else if (E == EscapeString)
        .escape_string
    else if (pc.isString(E))
        .string
    else if (Ptr) |C|
        (if (C == Time)
            .ptr_time
        else if (C == EscapeString)
            .ptr_escape_string
        else if (pc.isString(C))
            .ptr_string
        else if (isSlice(C))
            .ptr_slice
        else if (@typeInfo(C) == .@"struct")
            .ptr_strct
        else
            .ptr_other)
    else if (isSlice(E))
        .slice
    else if (@typeInfo(E) == .@"struct")
        .strct
    else
        .other;

    // EscapeString is a marker: the memory underneath is plain strings
    const Elem = switch (variant) {
        .escape_string => []const u8,
        .ptr_escape_string => ?*const []const u8,
        else => E,
    };
    const Child = if (Ptr) |C| (if (C == EscapeString) []const u8 else C) else Elem;

    const Nested = switch (variant) {
        .slice => SliceEncoder(E),
        .strct => se.StructEncoder(E),
        .ptr_slice => SliceEncoder(Child),
        .ptr_strct => se.StructEncoder(Child),
        else => void,
    };

    const conv: ?Conv = switch (variant) {
        .other => pc.typeconv(E) orelse @compileError("unsupported slice element type " ++ @typeName(E)),
        .ptr_other => pc.typeconv(Child) orelse @compileError("unsupported slice element type " ++ @typeName(E)),
        .escape_string, .ptr_escape_string => &pc.ptrEscapeStringToBuf,
        .string, .ptr_string => &pc.ptrStringToBuf,
        else => null,
    };

    return struct {
        /// Input is the slice type marshal accepts, i.e. []const []const u8 for []const EscapeString
        pub const Input = if (Elem == E) S else []const Elem;

        /// marshal writes the json document for a given slice to the buffer provided
        pub fn marshal(s: *const Input, w: *Buffer) Error!void {
            return marshalRaw(@ptrCast(s), w);
        }

        /// flat elements (plain or nullable strings, or structs that are a single run) let the whole slice
        /// reserve once and write through one cursor, instead of updating the buffer's length per element
        const flat = switch (variant) {
            .string, .ptr_string => true,
            .strct, .ptr_strct => Nested.flat,
            else => false,
        };

        fn putFlat(items: []const Elem, w: *Buffer) Error!void {
            var need: usize = 2;
            for (items) |*item| need += 1 + elemBound(item);
            var d = try w.reserve(need);
            d[0] = '[';
            d += 1;
            for (items, 0..) |*item, i| {
                if (i > 0) {
                    d[0] = ',';
                    d += 1;
                }
                d = putElem(item, d);
            }
            d[0] = ']';
            w.commit(d + 1);
        }

        inline fn elemBound(item: *const Elem) usize {
            return switch (variant) {
                .string => item.len + 2,
                .ptr_string => if (se.deref(Elem, @ptrCast(item))) |s| s.len + 2 else pc.null_lit.len,
                .strct => Nested.bound(item),
                .ptr_strct => if (se.deref(Elem, @ptrCast(item))) |s| Nested.bound(s) else pc.null_lit.len,
                else => comptime unreachable,
            };
        }

        inline fn putElem(item: *const Elem, d: [*]u8) [*]u8 {
            switch (variant) {
                .string => return putQuoted(item.*, d),
                .strct => return Nested.put(item, d),
                .ptr_string, .ptr_strct => {
                    const s = se.deref(Elem, @ptrCast(item)) orelse {
                        d[0..pc.null_lit.len].* = pc.null_lit.*;
                        return d + pc.null_lit.len;
                    };
                    return if (variant == .ptr_string) putQuoted(s.*, d) else Nested.put(s, d);
                },
                else => comptime unreachable,
            }
        }

        inline fn putQuoted(s: []const u8, d: [*]u8) [*]u8 {
            d[0] = '"';
            buffer.copy(d + 1, s);
            d[s.len + 1] = '"';
            return d + s.len + 2;
        }

        pub fn marshalRaw(v: *const anyopaque, w: *Buffer) Error!void {
            const sl: *const []const Elem = @ptrCast(@alignCast(v));
            const items = sl.*;
            if (flat) return putFlat(items, w);

            try w.writeByte('[');

            switch (variant) {
                .string, .escape_string => for (items, 0..) |*item, i| {
                    if (i == 0) try w.writeByte('"');
                    if (i > 0) try w.writeStatic("\",\"");

                    try conv.?(@ptrCast(item), w);

                    if (i == items.len - 1) try w.writeByte('"');
                },
                .slice, .strct => for (items, 0..) |*item, i| {
                    if (i > 0) try w.writeByte(',');
                    try Nested.marshalRaw(@ptrCast(item), w);
                },
                .other => for (items, 0..) |*item, i| {
                    if (i > 0) try w.writeByte(',');
                    try conv.?(@ptrCast(item), w);
                },
                .time => for (items, 0..) |*item, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.writeByte('"');
                    try pc.ptrTimeToBuf(@ptrCast(item), w);
                    try w.writeByte('"');
                },
                .ptr_slice, .ptr_strct, .ptr_string, .ptr_escape_string, .ptr_other, .ptr_time => for (items, 0..) |*item, i| {
                    if (i > 0) try w.writeByte(',');

                    const s = se.deref(Elem, @ptrCast(item)) orelse {
                        try w.writeStatic(pc.null_lit);
                        continue;
                    };
                    switch (variant) {
                        .ptr_slice, .ptr_strct => try Nested.marshalRaw(@ptrCast(s), w),
                        .ptr_string, .ptr_escape_string => {
                            try w.writeByte('"');
                            try conv.?(@ptrCast(s), w);
                            try w.writeByte('"');
                        },
                        .ptr_time => {
                            try w.writeByte('"');
                            try pc.ptrTimeToBuf(@ptrCast(s), w);
                            try w.writeByte('"');
                        },
                        else => try conv.?(@ptrCast(s), w),
                    }
                },
            }

            try w.writeByte(']');
        }
    };
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        else => false,
    };
}
