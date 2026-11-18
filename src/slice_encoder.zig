//! slice_encoder.zig manages SliceEncoder and its responsibilities.
//! SliceEncoder follows the same principle of struct_encoder.zig in that it generates lightweight
//! instructions as part of its compile stage which are executed later during marshal. The
//! slight difference here is that instruction is singular rather than plural. This is due to the
//! need for slice iteration to be managed from the instruction itself (at 'runtime') as a result
//! of slices being of variable length.

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
        const Self = @This();

        instruction: *const fn (self: ?*const Self, v: *const anyopaque, w: *Buffer) Error!void,
        nested: ?*anyopaque,
        gpa: std.mem.Allocator,

        /// Input is the slice type marshal accepts, i.e. []const []const u8 for []const EscapeString
        pub const Input = if (Elem == E) S else []const Elem;

        /// init builds a new SliceEncoder
        pub fn init(gpa: std.mem.Allocator) Error!*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .instruction = &instr,
                .nested = if (Nested == void) null else try Nested.init(gpa),
                .gpa = gpa,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (Nested != void) @as(*Nested, @ptrCast(@alignCast(self.nested.?))).deinit();
            self.gpa.destroy(self);
        }

        /// marshal executes the instruction built up by init
        pub fn marshal(self: *const Self, s: *const Input, w: *Buffer) Error!void {
            return self.marshalRaw(@ptrCast(s), w);
        }

        pub fn marshalRaw(self: *const Self, v: *const anyopaque, w: *Buffer) Error!void {
            if (se.fused) return instr(null, v, w);
            return self.instruction(self, v, w);
        }

        pub fn marshalFused(v: *const anyopaque, w: *Buffer) Error!void {
            return instr(null, v, w);
        }

        inline fn nest(self: ?*const Self, item: *const anyopaque, w: *Buffer) Error!void {
            if (se.fused) return Nested.marshalFused(item, w);
            const n: *const Nested = @ptrCast(@alignCast(self.?.nested.?));
            return n.marshalRaw(item, w);
        }

        fn instr(self: ?*const Self, v: *const anyopaque, w: *Buffer) Error!void {
            const sl: *const []const Elem = @ptrCast(@alignCast(v));
            const items = sl.*;

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
                    try nest(self, @ptrCast(item), w);
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
                        .ptr_slice, .ptr_strct => try nest(self, @ptrCast(s), w),
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
