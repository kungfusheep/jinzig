//! payloads mirrors the types and values used by jingo_test.go, shared by tests and benchmarks.
//! field names match the json keys so std.json, serde.zig and zerde produce the same documents.
//! jsonStringify (std.json) and zerdeSerialize (serde.zig) hooks mirror the jingo encoder fields;
//! jsonWrite/jsonFormat serve lalinsky/json.zig. zerde, zserde, zig-json and jaysan have no
//! custom-serialization hook, so they can't produce the All/Time documents.

const std = @import("std");
const jz = @import("jinzig");
const bench_options = @import("bench_options");

// lalinsky/json.zig drops null optional fields unless a type returns its StructOptions from jsonFormat
const lalinsky = if (bench_options.competitors) @import("lalinsky_json") else struct {
    pub const StructOptions = struct { omit_null_fields: bool = true };
};

fn keepNulls() lalinsky.StructOptions {
    return .{ .omit_null_fields = false };
}

pub const Encode0 = struct {
    val: u8,

    pub fn jsonEncode(e: *const Encode0, w: *jz.Buffer) jz.Error!void {
        try w.writeByte(e.val);
    }

    pub fn jsonStringify(e: Encode0, jw: anytype) !void {
        try jw.print("{c}", .{e.val});
    }

    pub fn zerdeSerialize(e: Encode0, s: anytype) @TypeOf(s.*).Error!void {
        s.out.writeByte(e.val) catch return error.WriteFailed;
    }

    pub fn jsonWrite(e: Encode0, encoder: anytype) !void {
        try encoder.writer.writeByte(e.val);
    }
};

/// go's `type encode1 []encode0` with a method; zig slices can't carry methods so it's wrapped
pub const Encode1 = struct {
    items: []const Encode0,

    pub fn jsonEncode(e: *const Encode1, w: *jz.Buffer) jz.Error!void {
        try w.writeByte('1');
        for (e.items) |v| try w.writeByte(v.val);
    }

    pub fn jsonStringify(e: Encode1, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('1');
        for (e.items) |v| try jw.writer.writeByte(v.val);
        jw.endWriteRaw();
    }

    pub fn zerdeSerialize(e: Encode1, s: anytype) @TypeOf(s.*).Error!void {
        s.out.writeByte('1') catch return error.WriteFailed;
        for (e.items) |v| s.out.writeByte(v.val) catch return error.WriteFailed;
    }

    pub fn jsonWrite(e: Encode1, encoder: anytype) !void {
        try encoder.writer.writeByte('1');
        for (e.items) |v| try encoder.writer.writeByte(v.val);
    }
};

pub const JsonMarshaler = struct {
    val: []const u8,

    pub fn encodeJson(j: *const JsonMarshaler, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(j.val);
    }

    pub fn jsonStringify(j: JsonMarshaler, jw: anytype) !void {
        try jw.print("{s}", .{j.val});
    }

    pub fn zerdeSerialize(j: JsonMarshaler, s: anytype) @TypeOf(s.*).Error!void {
        s.out.writeAll(j.val) catch return error.WriteFailed;
    }

    pub fn jsonWrite(j: JsonMarshaler, encoder: anytype) !void {
        try encoder.writer.writeAll(j.val);
    }
};

/// tag adds `,escape` to a string field's tag when esc is set. the default payloads (esc=false) use
/// jingo's opt-in escaping; the `escaped` set turns it on for every string so jinzig does the same
/// escape-scanning work std.json, serde.zig and zerde always do.
fn tag(comptime name: []const u8, comptime esc: bool) []const u8 {
    return if (esc) name ++ ",escape" else name;
}

pub fn PropStructT(comptime esc: bool) type {
    return struct {
        propName: []const []const u8,
        ps: []const ?*const []const u8,
        propNameEscaped: []const []const u8,

        pub const json_tags = .{
            .propName = tag("propName", esc),
            .ps = tag("ps", esc),
            .propNameEscaped = "propNameEscaped,escape",
        };
    };
}

pub fn AllT(comptime esc: bool) type {
    return struct {
        propBool: bool,
        propInt: isize,
        propInt8: i8,
        propInt16: i16,
        propInt32: i32,
        propInt64: i64,
        propUint: usize,
        propUint8: u8,
        propUint16: u16,
        propUint32: u32,
        propUint64: u64,
        propFloat32: f32,
        propFloat64: f64,
        propString: []const u8,
        propStruct: PropStructT(esc),
        propEncode: Encode0,
        propEncodeP: ?*const Encode0,
        propEncodenilP: ?*const Encode0,
        propEncodeS: Encode1,
        propJSONMarshaler: JsonMarshaler,
        propJSONMarshalerP: ?*const JsonMarshaler,

        pub const jsonFormat = keepNulls;
        pub const json_tags = .{
            .propBool = "propBool",
            .propInt = "propInt",
            .propInt8 = "propInt8",
            .propInt16 = "propInt16",
            .propInt32 = "propInt32",
            .propInt64 = "propInt64",
            .propUint = "propUint",
            .propUint8 = "propUint8",
            .propUint16 = "propUint16",
            .propUint32 = "propUint32",
            .propUint64 = "propUint64",
            .propFloat32 = "propFloat32",
            .propFloat64 = "propFloat64,stringer",
            .propString = tag("propString", esc),
            .propStruct = "propStruct",
            .propEncode = "propEncode,encoder",
            .propEncodeP = "propEncodeP,encoder",
            .propEncodenilP = "propEncodenilP,encoder",
            .propEncodeS = "propEncodeS,encoder",
            .propJSONMarshaler = "propJSONMarshaler,encoder",
            .propJSONMarshalerP = "propJSONMarshalerP,encoder",
        };
    };
}

const enc_p: Encode0 = .{ .val = '2' };
const enc_s = [_]Encode0{ .{ .val = '3' }, .{ .val = '4' } };
const marsh_p: JsonMarshaler = .{ .val = "2" };
const escaped_names = [_][]const u8{ "one\\two\\,three\"", "\"four\\five\\,six\"" };

fn all(comptime esc: bool, ps: []const ?*const []const u8) AllT(esc) {
    return .{
        .propBool = false,
        .propInt = 1234567878910111212,
        .propInt8 = 123,
        .propInt16 = 12349,
        .propInt32 = 1234567891,
        .propInt64 = 1234567878910111213,
        .propUint = 12345678789101112138,
        .propUint8 = 255,
        .propUint16 = 12345,
        .propUint32 = 1234567891,
        .propUint64 = 12345678789101112139,
        .propFloat32 = 21.232426,
        .propFloat64 = 2799999999888.28293031999999,
        .propString = "thirty two thirty four",
        .propStruct = .{
            .propName = &.{ "a name", "another name", "another" },
            .ps = ps,
            .propNameEscaped = &escaped_names,
        },
        .propEncode = .{ .val = '1' },
        .propEncodeP = &enc_p,
        .propEncodenilP = null,
        .propEncodeS = .{ .items = &enc_s },
        .propJSONMarshaler = .{ .val = "1" },
        .propJSONMarshalerP = &marsh_p,
    };
}

const example_s: []const u8 = "test pointer string";
const example_ps = [_]?*const []const u8{ &example_s, null, &example_s };

const fake_s: []const u8 = "test pointer string b";
const fake_ps = blk: {
    var ps: [269]?*const []const u8 = undefined;
    for (&ps, 0..) |*p, i| p.* = if (i % 2 == 0) &fake_s else null;
    break :blk ps;
};

pub fn SmallPayloadT(comptime esc: bool) type {
    return struct {
        st: isize,
        sid: isize,
        tt: []const u8,
        gr: isize,
        uuid: []const u8,
        ip: []const u8,
        ua: []const u8,
        tz: isize,
        v: isize,

        pub const json_tags = .{ .st = "st", .sid = "sid", .tt = tag("tt", esc), .gr = "gr", .uuid = tag("uuid", esc), .ip = tag("ip", esc), .ua = tag("ua", esc), .tz = "tz", .v = "v" };
    };
}

fn small(comptime esc: bool) SmallPayloadT(esc) {
    return .{
        .st = 1,
        .sid = 2,
        .tt = "TestString",
        .gr = 4,
        .uuid = "8f9a65eb-4807-4d57-b6e0-bda5d62f1429",
        .ip = "127.0.0.1",
        .ua = "Mozilla",
        .tz = 8,
        .v = 6,
    };
}

pub fn DSUserT(comptime esc: bool) type {
    return struct {
        username: []const u8,
        pub const json_tags = .{ .username = tag("username", esc) };
    };
}

pub fn DSTopicT(comptime esc: bool) type {
    return struct {
        ID: isize,
        slug: []const u8,
        pub const json_tags = .{ .ID = "ID", .slug = tag("slug", esc) };
    };
}

pub fn DSTopicsListT(comptime esc: bool) type {
    return struct {
        topics: []const ?*const DSTopicT(esc),
        more_topics_URL: []const u8,
        pub const json_tags = .{ .topics = "topics", .more_topics_URL = tag("more_topics_URL", esc) };
    };
}

pub fn LargePayloadT(comptime esc: bool) type {
    return struct {
        users: []const ?*const DSUserT(esc),
        topics: ?*const DSTopicsListT(esc),
        pub const jsonFormat = keepNulls;
        pub const json_tags = .{ .users = "users", .topics = "topics" };
    };
}

/// Large holds the value from jingo's NewLargePayload(). each stage is a container-level const so
/// pointers into it are valid at runtime.
fn Large(comptime esc: bool) type {
    return struct {
        const users = blk: {
            @setEvalBranchQuota(100_000);
            var us: [100]DSUserT(esc) = undefined;
            for (&us, 0..) |*u, i| u.* = .{ .username = std.fmt.comptimePrint("test{d}", .{i}) };
            break :blk us;
        };

        const topic_values = blk: {
            var ts: [100]DSTopicT(esc) = undefined;
            for (&ts, 0..) |*t, i| t.* = .{ .ID = i, .slug = users[i].username };
            break :blk ts;
        };

        const user_ptrs = blk: {
            var up: [100]?*const DSUserT(esc) = undefined;
            for (&up, 0..) |*u, i| u.* = &users[i];
            break :blk up;
        };

        const topic_ptrs = blk: {
            var tp: [100]?*const DSTopicT(esc) = undefined;
            for (&tp, 0..) |*t, i| t.* = &topic_values[i];
            break :blk tp;
        };

        const topics: DSTopicsListT(esc) = .{ .topics = &topic_ptrs, .more_topics_URL = "http://test.com" };

        pub const value: LargePayloadT(esc) = .{ .users = &user_ptrs, .topics = &topics };
    };
}

pub fn UnicodeObjectT(comptime esc: bool) type {
    return struct {
        chinese: []const u8,
        emoji: []const u8,
        russian: []const u8,
        pub const json_tags = .{ .chinese = tag("chinese", esc), .emoji = tag("emoji", esc), .russian = tag("russian", esc) };
    };
}

fn unicodeOf(comptime esc: bool) UnicodeObjectT(esc) {
    return .{
        .chinese = "你好，世界",
        .emoji = "👋🌍😄😂💊🐂🍺",
        .russian = "ру́сский язы́к",
    };
}

const filler = "ascdjkl ascdhjklacdshlacdshjkl acdshjcdhjkl acdshjl kacdshjkl acdshjkacdshjklacdhjskl hjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjk lacdshjk acdshjkl acdshjkl hjkl acdshjkl acdshjkl acdshjkl cdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl ";

pub fn UnicodeObjectLargeT(comptime esc: bool) type {
    return struct {
        chinese: []const u8,
        emoji: []const u8,
        russian: []const u8,
        @"test": []const u8,
        test1: []const u8,
        test2: []const u8,
        test3: []const u8,
        pub const json_tags = .{ .chinese = tag("chinese", esc), .emoji = tag("emoji", esc), .russian = tag("russian", esc), .@"test" = tag("test", esc), .test1 = tag("test1", esc), .test2 = tag("test2", esc), .test3 = tag("test3", esc) };
    };
}

fn unicodeLargeOf(comptime esc: bool) UnicodeObjectLargeT(esc) {
    return .{
        .chinese = "你好，世界",
        .emoji = "👋🌍😄😂👋💊🐂🍺",
        .russian = "ру́сский язы́к",
        .@"test" = filler,
        .test1 = filler,
        .test2 = filler,
        .test3 = filler,
    };
}

// the payloads from jingo_test.go, with jingo's opt-in escaping
pub const PropStruct = PropStructT(false);
pub const All = AllT(false);
pub const SmallPayload = SmallPayloadT(false);
pub const DSUser = DSUserT(false);
pub const DSTopic = DSTopicT(false);
pub const DSTopicsList = DSTopicsListT(false);
pub const LargePayload = LargePayloadT(false);
pub const UnicodeObject = UnicodeObjectT(false);
pub const UnicodeObjectLarge = UnicodeObjectLargeT(false);

/// the value from jingo's Example()
pub const example = all(false, &example_ps);
/// the value from jingo's BenchmarkJson (`fake`)
pub const fake = all(false, &fake_ps);
pub const small_payload = small(false);
pub const large_payload = Large(false).value;
pub const unicode = unicodeOf(false);
pub const unicode_large = unicodeLargeOf(false);

/// the same values with `,escape` on every string field
pub const escaped = struct {
    pub const All = AllT(true);
    pub const SmallPayload = SmallPayloadT(true);
    pub const LargePayload = LargePayloadT(true);
    pub const UnicodeObject = UnicodeObjectT(true);
    pub const UnicodeObjectLarge = UnicodeObjectLargeT(true);

    pub const fake = all(true, &fake_ps);
    pub const small_payload = small(true);
    pub const large_payload = Large(true).value;
    pub const unicode = unicodeOf(true);
    pub const unicode_large = unicodeLargeOf(true);
};

pub const TimeObject = struct {
    time: jz.Time,
    ptrTime: ?*const jz.Time,
    nullPtrTime: ?*const jz.Time,
    sliceTime: []const jz.Time,
    ptrSliceTime: []const ?*const jz.Time,
    nullPtrSliceTime: []const ?*const jz.Time,
    pub const jsonFormat = keepNulls;
    pub const json_tags = .{ .time = "time", .ptrTime = "ptrTime", .nullPtrTime = "nullPtrTime", .sliceTime = "sliceTime", .ptrSliceTime = "ptrSliceTime", .nullPtrSliceTime = "nullPtrSliceTime" };
};

const d1 = jz.Time.date(2001, 9, 17, 20, 4, 26, 0);
const d2 = [_]jz.Time{jz.Time.date(2002, 9, 17, 20, 4, 26, 0)};
const d3 = jz.Time.date(2003, 9, 17, 20, 4, 26, 0);
const d3p = [_]?*const jz.Time{&d3};

/// the value from jingo's BenchmarkTime (no null pointer slice entries)
pub const time_object: TimeObject = .{
    .time = jz.Time.date(2000, 9, 17, 20, 4, 26, 0),
    .ptrTime = &d1,
    .nullPtrTime = null,
    .sliceTime = &d2,
    .ptrSliceTime = &d3p,
    .nullPtrSliceTime = &.{},
};

pub const slice_strings = [_][]const u8{ "a name", "another name", "another", "and one more", "last one, promise" };
