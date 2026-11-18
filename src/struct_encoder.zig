//! struct_encoder.zig manages StructEncoder and its responsibilities.
//! The general goal of the approach is to do as much of the necessary work as possible inside
//! the 'compile' stage. In jingo that happens at runtime via reflect; here the instruction set is
//! compiled from @typeInfo at comptime and `init` materialises it into a runtime instruction slice.
//!
//! With -Dmode=interpreted (the default) marshal walks that slice exactly as jingo's Marshal does.
//! With -Dmode=fused the same comptime plan is unrolled with `inline for`, removing the dispatch loop.

const std = @import("std");
const build_options = @import("build_options");
const buffer = @import("buffer.zig");
const pc = @import("ptrconvert.zig");
const SliceEncoder = @import("slice_encoder.zig").SliceEncoder;

const Buffer = buffer.Buffer;
const Error = buffer.Error;
const Conv = pc.Conv;
const Time = pc.Time;

pub const fused = build_options.mode == .fused;

pub const Fun = *const fn (ctx: ?*const anyopaque, v: [*]const u8, w: *Buffer) Error!void;

pub const Kind = enum(u8) { normal, string_field, static, int };

/// Instruction describes the different ways we can execute a single instruction at runtime.
/// static, leap_fun/offset, fun are mutually exclusive. ctx stands in for whatever a go closure
/// would have captured at runtime (a nested encoder).
pub const Instruction = struct {
    static: []const u8 = "", // fast path for writing static chunks without needing an instruction function
    kind: Kind = .normal, // used to switch special paths in marshal, like string fast path
    offset: usize = 0, // used in conjunction with leap_fun
    leap_fun: ?Conv = null, // fast path for simple write & avoids wrapping function to capture offset
    fun: ?Fun = null, // full instruction function for when the approaches above fail
    ctx: ?*const anyopaque = null,
};

/// JSONEncoder works with the `,encoder` option: declare `pub fn jsonEncode(self: *const T, w: *Buffer) Error!void`.
/// JSONMarshaler works with the `,encoder` option: declare `pub fn encodeJson(self: *const T, w: *std.Io.Writer) std.Io.Writer.Error!void`.
/// Stringers work with the `,stringer` option: declare `pub fn string(self: *const T) []const u8`.
///
/// Tags are declared on the struct, as zig has no struct tags:
///     pub const json_tags = .{ .name = "name", .age = "age,stringer" };
/// Anything without a tag doesn't get emitted.
pub fn StructEncoder(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("StructEncoder requires a struct, got " ++ @typeName(T));

    return struct {
        const Self = @This();

        instructions: []Instruction, // the instruction set to be executed during marshal
        gpa: std.mem.Allocator,

        pub const plan: []const Op = compile(T);

        /// init builds the runtime instruction set for T, creating any nested encoders it needs.
        pub fn init(gpa: std.mem.Allocator) Error!*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const instructions = try gpa.alloc(Instruction, plan.len);
            self.* = .{ .instructions = instructions, .gpa = gpa };

            inline for (plan, 0..) |op, i| {
                instructions[i] = op.ins;
                if (op.nested) |Enc| {
                    // handle recursive structs by re-using the current encoder
                    instructions[i].ctx = if (Enc == Self) self else try Enc.init(gpa);
                }
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            inline for (plan, 0..) |op, i| {
                if (op.nested) |Enc| if (Enc != Self) {
                    const n: *Enc = @ptrCast(@alignCast(@constCast(self.instructions[i].ctx.?)));
                    n.deinit();
                };
            }
            self.gpa.free(self.instructions);
            self.gpa.destroy(self);
        }

        /// marshal executes the instructions for a given value and writes the resulting
        /// json document to the buffer provided
        pub fn marshal(self: *const Self, s: *const T, w: *Buffer) Error!void {
            return self.marshalRaw(s, w);
        }

        pub fn marshalRaw(self: *const Self, s: *const anyopaque, w: *Buffer) Error!void {
            if (fused) return marshalFused(s, w);

            const p: [*]const u8 = @ptrCast(s);
            for (self.instructions) |*ins| {
                if (ins.kind == .static) { // static data fast path
                    try w.write(ins.static);
                    continue;
                } else if (ins.kind == .string_field) { // string fields fast path
                    try pc.ptrStringToBuf(@ptrCast(p + ins.offset), w);
                    continue;
                } else if (ins.kind == .int) { // int fields fast path
                    try pc.PtrIntToBuf(isize).conv(@ptrCast(p + ins.offset), w);
                    continue;
                } else if (ins.leap_fun) |f| { // simple 'conv' function fast path
                    try f(@ptrCast(p + ins.offset), w);
                    continue;
                }

                try ins.fun.?(ins.ctx, p, w); // all other instruction types
            }
        }

        /// marshalFused is the same plan with every branch resolved at comptime: straight-line code.
        pub fn marshalFused(s: *const anyopaque, w: *Buffer) Error!void {
            const p: [*]const u8 = @ptrCast(s);
            inline for (plan) |op| {
                const ins = op.ins;
                switch (ins.kind) {
                    .static => try w.writeStatic(ins.static),
                    .string_field => try pc.ptrStringToBuf(@ptrCast(p + ins.offset), w),
                    .int => try pc.PtrIntToBuf(isize).conv(@ptrCast(p + ins.offset), w),
                    .normal => if (ins.leap_fun) |f|
                        try f(@ptrCast(p + ins.offset), w)
                    else
                        try ins.fun.?(null, p, w),
                }
            }
        }
    };
}

/// Op is the comptime form of an instruction, carrying the nested encoder type to build at init.
pub const Op = struct {
    ins: Instruction,
    nested: ?type = null,
};

/// EscapeString can be used as the element type of a SliceEncoder in replacement of `[]const u8`,
/// e.g. SliceEncoder([]const EscapeString), which encodes a `[]const []const u8` with escaping.
/// You can and should just use the `,escape` option on your struct fields when using StructEncoder.
pub const EscapeString = struct {};

fn compile(comptime T: type) []const Op {
    comptime {
        @setEvalBranchQuota(100_000);
        var c: Compiler = .{};
        const info = @typeInfo(T).@"struct";

        c.chunk("{");

        var emit = 0; // track number of fields we emit
        // pass over each field in the struct to build up our instruction set for each
        for (info.field_names, info.field_types) |name, F| {
            const tag, const opts = parseTag(tagOf(T, name)); // we're using tags to nominate inclusion
            if (tag.len == 0) continue;
            emit += 1;

            // write the key
            if (emit > 1) c.chunk(",");
            c.chunk("\"" ++ tag ++ "\":");

            const f: Field = .{ .F = F, .offset = @offsetOf(T, name), .owner = T, .name = name };
            const K = f.target();

            if (hasOpt(opts, "stringer") and hasMethod(K, "string")) {
                c.optInstrStringer(f);
            } else if (hasOpt(opts, "encoder")) {
                // require explicit opt-in for JSONMarshaler implementation
                if (hasMethod(K, "encodeJson")) {
                    c.optInstrEncoderWriter(f);
                } else {
                    // default to JSONEncoder implementation for any other encoder fields
                    c.optInstrEncoder(f);
                }
            } else if (hasOpt(opts, "raw")) {
                c.optInstrRaw(f);
            } else if (hasOpt(opts, "escape")) {
                c.optInstrEscape(f);
            } else if (F == Time) {
                // time is a type of struct, not a kind, so somewhat of a special case here.
                c.chunk("\"");
                c.val(f, &pc.ptrTimeToBuf);
                c.chunk("\"");
            } else if (f.indirect() and K == Time) {
                c.ptrstringval(f, &pc.ptrTimeToBuf);
            } else {
                // create an instruction which reads from a pointer, optional or standard field
                c.valueInst(f);
            }
        }

        c.chunk("}");
        c.flunk();

        const out: [c.ops.len]Op = c.ops[0..c.ops.len].*;
        return &out;
    }
}

/// Field is the comptime equivalent of the reflect.StructField jingo keeps as `e.f`.
const Field = struct {
    F: type,
    offset: usize,
    owner: type,
    name: []const u8,

    // indirect reports whether the field is a pointer or optional, i.e. needs a null check / deref
    fn indirect(comptime f: Field) bool {
        return Indirect(f.F) != null;
    }

    // target is the type the field's value resolves to, e.g. Elem() for pointers
    fn target(comptime f: Field) type {
        return Indirect(f.F) orelse f.F;
    }
};

/// Indirect returns the pointee of a nullable/pointer field (`?*T`, `*T`, `?T`), or null otherwise.
pub fn Indirect(comptime F: type) ?type {
    return switch (@typeInfo(F)) {
        .pointer => |p| if (p.size == .one) p.child else null,
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| if (p.size == .one) p.child else o.child,
            else => o.child,
        },
        else => null,
    };
}

/// deref resolves a pointer to an indirect field into a pointer to its value, null when unset.
pub inline fn deref(comptime F: type, fp: *const anyopaque) ?*const Indirect(F).? {
    const f: *const F = @ptrCast(@alignCast(fp));
    return switch (@typeInfo(F)) {
        .pointer => f.*,
        .optional => |o| if (comptime isOnePtr(o.child)) f.* else if (f.*) |*v| v else null,
        else => comptime unreachable,
    };
}

const Compiler = struct {
    ops: []const Op = &.{},
    cb: []const u8 = "", // side buffer for static data

    // chunk writes a chunk of body data to the chunk buffer. only for writing static
    // structure and not dynamic values.
    fn chunk(comptime c: *Compiler, comptime b: []const u8) void {
        c.cb = c.cb ++ b;
    }

    // flunk flushes whatever chunk data we've got buffered into a single instruction
    fn flunk(comptime c: *Compiler) void {
        if (c.cb.len == 0) return;
        c.ops = c.ops ++ &[_]Op{.{ .ins = .{ .static = c.cb, .kind = .static } }};
        c.cb = "";
    }

    fn append(comptime c: *Compiler, comptime op: Op) void {
        c.flunk(); // flush any chunk data we've buffered
        c.ops = c.ops ++ &[_]Op{op};
    }

    fn appendInstructionFun(comptime c: *Compiler, comptime fun: Fun) void {
        c.append(.{ .ins = .{ .fun = fun } });
    }

    // val creates an instruction to read from a field we're marshaling
    fn val(comptime c: *Compiler, comptime f: Field, comptime conv: Conv) void {
        c.append(.{ .ins = .{ .leap_fun = conv, .offset = f.offset } });
    }

    // ptrval creates an instruction to read from a pointer/optional field we're marshaling
    fn ptrval(comptime c: *Compiler, comptime f: Field, comptime conv: Conv) void {
        c.appendInstructionFun(&PtrVal(f.F, f.offset, conv, false).run);
    }

    // ptrstringval is essentially the same as ptrval but quotes strings if not null
    fn ptrstringval(comptime c: *Compiler, comptime f: Field, comptime conv: Conv) void {
        c.appendInstructionFun(&PtrVal(f.F, f.offset, conv, true).run);
    }

    // instr picks val or ptrval for the field, as jingo passes e.val / e.ptrval into valueInst
    fn instr(comptime c: *Compiler, comptime f: Field, comptime conv: Conv) void {
        if (f.indirect()) c.ptrval(f, conv) else c.val(f, conv);
    }

    fn nested(comptime c: *Compiler, comptime f: Field, comptime Enc: type) void {
        c.append(.{ .ins = .{ .fun = &NestedVal(Enc, f.F, f.offset, f.indirect()).run }, .nested = Enc });
    }

    fn optInstrStringer(comptime c: *Compiler, comptime f: Field) void {
        c.chunk("\"");
        c.instr(f, &StringerConv(f.target()).conv);
        c.chunk("\"");
    }

    fn optInstrEncoder(comptime c: *Compiler, comptime f: Field) void {
        c.instr(f, &EncoderConv(f.target()).conv);
    }

    fn optInstrEncoderWriter(comptime c: *Compiler, comptime f: Field) void {
        c.instr(f, &EncoderWriterConv(f.target()).conv);
    }

    fn optInstrRaw(comptime c: *Compiler, comptime f: Field) void {
        c.instr(f, &RawConv(f.target()).conv);
    }

    fn optInstrEscape(comptime c: *Compiler, comptime f: Field) void {
        const K = f.target();
        if (!f.indirect() and @typeInfo(K) == .pointer and @typeInfo(K).pointer.size == .slice and !pc.isString(K)) {
            // create an escape string encoder internally instead of mirroring the struct, so people only need to pass the ,escape opt instead
            c.nested(f, SliceEncoder(EscapeSliceOf(K)));
            return;
        }
        if (!pc.isString(K)) @compileError("the ,escape option needs a string or string slice: " ++ @typeName(f.owner) ++ "." ++ f.name);

        if (f.indirect()) {
            c.ptrstringval(f, &pc.ptrEscapeStringToBuf);
        } else {
            c.chunk("\"");
            c.val(f, &pc.ptrEscapeStringToBuf);
            c.chunk("\"");
        }
    }

    // valueInst works out the conversion function we need for the field and creates an instruction to write it to the buffer
    fn valueInst(comptime c: *Compiler, comptime f: Field) void {
        const K = f.target();

        if (K == isize) {
            // fast path for int fields (go's int)
            if (f.indirect()) return c.ptrval(f, pc.typeconv(isize).?);
            c.append(.{ .ins = .{ .offset = f.offset, .kind = .int } });
            return;
        }

        if (pc.isString(K)) {
            // for strings to be nullable they need a special instruction to write quotes conditionally.
            if (f.indirect()) return c.ptrstringval(f, &pc.ptrStringToBuf);

            // otherwise a standard quoted print instruction, using the string fast path
            c.chunk("\"");
            c.append(.{ .ins = .{ .offset = f.offset, .kind = .string_field } });
            c.chunk("\"");
            return;
        }

        switch (@typeInfo(K)) {
            .bool, .int, .float => {
                // standard print
                const conv = pc.typeconv(K) orelse unsupported(f);
                c.instr(f, conv);
            },
            .array => |a| {
                // support for primitives in arrays
                if (f.indirect()) unsupported(f);
                const conv = pc.typeconv(a.child) orelse unsupported(f);

                c.chunk("[");
                for (0..a.len) |i| {
                    if (i > 0) c.chunk(", ");
                    c.appendInstructionFun(&ArrayElem(f.offset + i * @sizeOf(a.child), conv).run);
                }
                c.chunk("]");
            },
            .pointer => |p| {
                if (p.size != .slice) unsupported(f);
                c.nested(f, SliceEncoder(K));
            },
            .@"struct" => {
                // build a new StructEncoder for the type; a pointer field to its own type re-uses the current encoder
                c.nested(f, StructEncoder(K));
            },
            else => unsupported(f),
        }
    }
};

fn unsupported(comptime f: Field) noreturn {
    @compileError("unsupported type " ++ @typeName(f.F) ++ " for field " ++ @typeName(f.owner) ++ "." ++ f.name);
}

fn PtrVal(comptime F: type, comptime offset: usize, comptime conv: Conv, comptime quoted: bool) type {
    return struct {
        fn run(_: ?*const anyopaque, v: [*]const u8, w: *Buffer) Error!void {
            const p = deref(F, @ptrCast(v + offset)) orelse return w.writeStatic(pc.null_lit);
            // quotes need to be at runtime here because we don't know if we're going to have to null the field
            if (quoted) try w.writeByte('"');
            try conv(@ptrCast(p), w);
            if (quoted) try w.writeByte('"');
        }
    };
}

fn NestedVal(comptime Enc: type, comptime F: type, comptime offset: usize, comptime indirect: bool) type {
    return struct {
        fn run(ctx: ?*const anyopaque, v: [*]const u8, w: *Buffer) Error!void {
            const fp: *const anyopaque = @ptrCast(v + offset);
            const p: *const anyopaque = if (indirect) deref(F, fp) orelse return w.writeStatic(pc.null_lit) else fp;
            if (fused) return Enc.marshalFused(p, w);
            const enc: *const Enc = @ptrCast(@alignCast(ctx.?));
            return enc.marshalRaw(p, w);
        }
    };
}

fn ArrayElem(comptime offset: usize, comptime conv: Conv) type {
    return struct {
        fn run(_: ?*const anyopaque, v: [*]const u8, w: *Buffer) Error!void {
            try conv(@ptrCast(v + offset), w);
        }
    };
}

fn StringerConv(comptime K: type) type {
    return struct {
        fn conv(v: *const anyopaque, w: *Buffer) Error!void {
            const k: *const K = @ptrCast(@alignCast(v));
            try w.write(k.string());
        }
    };
}

fn EncoderConv(comptime K: type) type {
    return struct {
        fn conv(v: *const anyopaque, w: *Buffer) Error!void {
            if (!comptime hasMethod(K, "jsonEncode")) return w.writeStatic(pc.null_lit);
            const k: *const K = @ptrCast(@alignCast(v));
            try k.jsonEncode(w);
        }
    };
}

fn EncoderWriterConv(comptime K: type) type {
    return struct {
        fn conv(v: *const anyopaque, w: *Buffer) Error!void {
            const k: *const K = @ptrCast(@alignCast(v));
            try w.withWriter(k, call);
        }
        fn call(k: *const K, iw: *std.Io.Writer) std.Io.Writer.Error!void {
            return k.encodeJson(iw);
        }
    };
}

fn RawConv(comptime K: type) type {
    return struct {
        fn conv(v: *const anyopaque, w: *Buffer) Error!void {
            // only byteslice-like items can be raw; anything else (and empty) is null, as in jingo
            if (!comptime pc.isString(K)) return w.writeStatic(pc.null_lit);
            const s: *const []const u8 = @ptrCast(@alignCast(v));
            if (s.len == 0) return w.writeStatic(pc.null_lit);
            try w.write(s.*);
        }
    };
}

/// EscapeSliceOf maps a string slice type onto its escaping SliceEncoder equivalent.
fn EscapeSliceOf(comptime S: type) type {
    const E = @typeInfo(S).pointer.child;
    if (pc.isString(E)) return []const EscapeString;
    if (Indirect(E)) |C| if (pc.isString(C)) return []const ?*const EscapeString;
    @compileError("the ,escape option needs a slice of strings, got " ++ @typeName(S));
}

fn isOnePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one,
        else => false,
    };
}

pub fn hasMethod(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

fn tagOf(comptime T: type, comptime name: []const u8) []const u8 {
    if (!@hasDecl(T, "json_tags")) return "";
    const tags = T.json_tags;
    if (!@hasField(@TypeOf(tags), name)) return "";
    return @field(tags, name);
}

/// parseTag splits a struct field's json tag into its name and comma-separated options.
fn parseTag(comptime tag: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, tag, ',')) |idx| return .{ tag[0..idx], tag[idx + 1 ..] };
    return .{ tag, "" };
}

/// hasOpt reports whether a comma-separated list of options contains a particular flag.
fn hasOpt(comptime opts: []const u8, comptime name: []const u8) bool {
    var it = std.mem.splitScalar(u8, opts, ',');
    while (it.next()) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}
