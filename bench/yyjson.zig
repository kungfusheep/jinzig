//! yyjson drives the yyjson C library directly, at its fastest: the document is built in a pool over a
//! reused buffer (no malloc), strings and keys are referenced rather than copied, and the result is
//! written straight into the caller's output buffer. zig-json wraps the same library, but through an
//! allocating API that copies every string, so this is yyjson's own best case.

const std = @import("std");
const jz = @import("jinzig");
const c = @import("yyjson_c");

const Doc = c.yyjson_mut_doc;
const Val = c.yyjson_mut_val;

/// write encodes v into out, using pool for the document's memory.
pub fn write(v: anytype, pool: []u8, out: *std.Io.Writer) !void {
    var alc: c.yyjson_alc = undefined;
    if (!c.yyjson_alc_pool_init(&alc, pool.ptr, pool.len)) return error.PoolTooSmall;
    const doc = c.yyjson_mut_doc_new(&alc) orelse return error.OutOfMemory;
    c.yyjson_mut_doc_set_root(doc, try build(doc, v));

    const dst = try out.writableSliceGreedy(1 << 16);
    const n = c.yyjson_mut_write_buf(dst.ptr, dst.len, doc, c.YYJSON_WRITE_NOFLAG, null);
    if (n == 0) return error.WriteFailed;
    out.advance(n);
}

fn build(doc: *Doc, v: anytype) !*Val {
    const T = @TypeOf(v.*);
    if (T == jz.Time) {
        var buf: [jz.Time.max_rfc3339_len]u8 = undefined;
        const s = v.formatRfc3339Nano(&buf);
        return c.yyjson_mut_strncpy(doc, s.ptr, s.len) orelse error.OutOfMemory;
    }
    // the payloads' custom encoders write raw json, which yyjson embeds as-is
    if (comptime hasDecl(T, "encodeJson")) {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try v.encodeJson(&w);
        return c.yyjson_mut_rawncpy(doc, &buf, w.end) orelse error.OutOfMemory;
    }
    if (comptime hasDecl(T, "jsonEncode")) {
        var buf: [256]u8 = undefined;
        var b: jz.Buffer = .{ .bytes = .initBuffer(&buf) }; // fits, so it never allocates
        try v.jsonEncode(&b);
        return c.yyjson_mut_rawncpy(doc, b.string().ptr, b.string().len) orelse error.OutOfMemory;
    }
    const out: ?*Val = switch (@typeInfo(T)) {
        .bool => c.yyjson_mut_bool(doc, v.*),
        .int => |i| if (i.signedness == .signed) c.yyjson_mut_sint(doc, v.*) else c.yyjson_mut_uint(doc, v.*),
        .float => if (T == f32) c.yyjson_mut_float(doc, v.*) else c.yyjson_mut_real(doc, v.*),
        .optional => if (v.*) |*x| try build(doc, x) else c.yyjson_mut_null(doc),
        .pointer => |p| switch (p.size) {
            .one => return build(doc, v.*),
            .slice => if (p.child == u8) c.yyjson_mut_strn(doc, v.ptr, v.len) else blk: {
                const arr = c.yyjson_mut_arr(doc) orelse return error.OutOfMemory;
                for (v.*) |*x| _ = c.yyjson_mut_arr_append(arr, try build(doc, x));
                break :blk arr;
            },
            else => @compileError("yyjson: " ++ @typeName(T)),
        },
        .array => blk: {
            const arr = c.yyjson_mut_arr(doc) orelse return error.OutOfMemory;
            for (v) |*x| _ = c.yyjson_mut_arr_append(arr, try build(doc, x));
            break :blk arr;
        },
        .@"struct" => |s| blk: {
            const obj = c.yyjson_mut_obj(doc) orelse return error.OutOfMemory;
            inline for (s.field_names) |name| {
                const key = c.yyjson_mut_strn(doc, name.ptr, name.len) orelse return error.OutOfMemory;
                _ = c.yyjson_mut_obj_add(obj, key, try build(doc, &@field(v, name)));
            }
            break :blk obj;
        },
        else => @compileError("yyjson: " ++ @typeName(T)),
    };
    return out orelse error.OutOfMemory;
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => @hasDecl(T, name),
        else => false,
    };
}
