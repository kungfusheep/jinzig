const std = @import("std");
const testing = std.testing;
const jz = @import("jinzig");
const p = @import("payloads");

test {
    _ = @import("nesting.zig");
}

/// expectStruct encodes v into a pooled buffer, then checks the output is exact
fn expectStruct(comptime T: type, v: *const T, want: []const u8) !void {
    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();

    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();

    try jz.StructEncoder(T).marshal(v, b);
    try testing.expectEqualStrings(want, b.string());
}

fn expectSlice(comptime S: type, v: *const jz.SliceEncoder(S).Input, want: []const u8) !void {
    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();

    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();

    try jz.SliceEncoder(S).marshal(v, b);
    try testing.expectEqualStrings(want, b.string());
}

fn expectValid(s: []const u8) !void {
    try testing.expect(try std.json.validate(testing.allocator, s));
}

test "Example" {
    try expectStruct(p.All, &p.example,
        \\{"propBool":false,"propInt":1234567878910111212,"propInt8":123,"propInt16":12349,"propInt32":1234567891,"propInt64":1234567878910111213,"propUint":12345678789101112138,"propUint8":255,"propUint16":12345,"propUint32":1234567891,"propUint64":12345678789101112139,"propFloat32":21.232426,"propFloat64":2799999999888.2827,"propString":"thirty two thirty four","propStruct":{"propName":["a name","another name","another"],"ps":["test pointer string",null,"test pointer string"],"propNameEscaped":["one\\two\\,three\"","\"four\\five\\,six\""]},"propEncode":1,"propEncodeP":2,"propEncodenilP":null,"propEncodeS":134,"propJSONMarshaler":1,"propJSONMarshalerP":2}
    );
}

test "Example_testStruct2" {
    const TestStruct2 = struct {
        raw: []const u8,
        raw2: []const u8,
        raw3: isize,
        pub const json_tags = .{ .raw = "raw,raw", .raw2 = "c,raw", .raw3 = "b,raw" };
    };
    try expectStruct(TestStruct2, &.{ .raw = "{\"mapKey1\":1,\"mapKey2\":2}", .raw2 = "", .raw3 = 1 },
        \\{"raw":{"mapKey1":1,"mapKey2":2},"c":null,"b":null}
    );
}

test "NilStruct" {
    const TestStruct1 = struct {
        str1: []const u8,
        int1: isize,
        pub const json_tags = .{ .str1 = "str1", .int1 = "int1" };
    };
    const TestStruct0 = struct {
        structPtr: ?*const TestStruct1,
        pub const json_tags = .{ .structPtr = "structPtr" };
    };
    try expectStruct(TestStruct0, &.{ .structPtr = null }, "{\"structPtr\":null}");
}

const StructWithEscapes = struct {
    str: []const u8,
    @"str-array": []const []const u8,
    pub const json_tags = .{ .str = "str,escape", .@"str-array" = "str-array,escape" };
};

test "StructWithEscapes" {
    const es: StructWithEscapes = .{
        .str = "one\\two\\,three,\n\t\tfour\"",
        .@"str-array" = &.{ "one\\two", "three\\,four,\n\t\tfive" },
    };
    const want =
        \\{"str":"one\\two\\,three,\n\t\tfour\"","str-array":["one\\two","three\\,four,\n\t\tfive"]}
    ;
    try expectStruct(StructWithEscapes, &es, want);
    try expectValid(want);

    // and back again
    const parsed = try std.json.parseFromSlice(StructWithEscapes, testing.allocator, want, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(es.str, parsed.value.str);
    try testing.expectEqual(es.@"str-array".len, parsed.value.@"str-array".len);
    for (es.@"str-array", parsed.value.@"str-array") |a, b| try testing.expectEqualStrings(a, b);
}

const StructWithRecursion = struct {
    name: []const u8,
    child: ?*const StructWithRecursion,
    pub const json_tags = .{ .name = "name", .child = "child" };
};

test "StructWithRecursion" {
    const c: StructWithRecursion = .{ .name = "C", .child = null };
    const b: StructWithRecursion = .{ .name = "B", .child = &c };
    try expectStruct(StructWithRecursion, &.{ .name = "A", .child = &b },
        \\{"name":"A","child":{"name":"B","child":{"name":"C","child":null}}}
    );
}

test "Unicode" {
    try expectStruct(p.UnicodeObject, &.{
        .chinese = "你好，世界",
        .emoji = "👋🌍😄😂👋💊🐂🍺",
        .russian = "ру́сский язы́к",
    }, "{\"chinese\":\"你好，世界\",\"emoji\":\"👋🌍😄😂👋💊🐂🍺\",\"russian\":\"ру́сский язы́к\"}");
}

test "UnicodeLarge" {
    const f = "ascdjkl ascdhjklacdshlacdshjkl acdshjcdhjkl acdshjl kacdshjkl acdshjkacdshjklacdhjskl hjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjk lacdshjk acdshjkl acdshjkl hjkl acdshjkl acdshjkl acdshjkl cdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl ";
    const want = "{\"chinese\":\"你好，世界\",\"emoji\":\"👋🌍😄😂👋💊🐂🍺\",\"russian\":\"ру́сский язы́к\",\"test\":\"" ++ f ++ "\",\"test1\":\"" ++ f ++ "\",\"test2\":\"" ++ f ++ "\",\"test3\":\"" ++ f ++ "\"}";
    try expectValid(want);
    try expectStruct(p.UnicodeObjectLarge, &p.unicode_large, want);
}

test "Time" {
    const d1 = jz.Time.date(2001, 9, 17, 20, 4, 26, 0);
    const d3 = jz.Time.date(2003, 9, 17, 20, 4, 26, 0);
    try expectStruct(p.TimeObject, &.{
        .time = jz.Time.date(2000, 9, 17, 20, 4, 26, 0),
        .ptrTime = &d1,
        .nullPtrTime = null,
        .sliceTime = &.{jz.Time.date(2002, 9, 17, 20, 4, 26, 0)},
        .ptrSliceTime = &.{&d3},
        .nullPtrSliceTime = &.{null},
    },
        \\{"time":"2000-09-17T20:04:26Z","ptrTime":"2001-09-17T20:04:26Z","nullPtrTime":null,"sliceTime":["2002-09-17T20:04:26Z"],"ptrSliceTime":["2003-09-17T20:04:26Z"],"nullPtrSliceTime":[null]}
    );
}

test "SliceEncoder" {
    const S = []const []const u8;
    try expectSlice(S, &&.{}, "[]");
    try expectSlice(S, &&.{"0"}, "[\"0\"]");
    try expectSlice(S, &&.{ "0", "1", "2" }, "[\"0\",\"1\",\"2\"]");
}

// beyond the go suite: behaviour specific to the port and paths go's tests don't reach

test "Time RFC3339Nano fractions, offsets and pre-epoch dates" {
    const T = struct {
        a: jz.Time,
        b: jz.Time,
        c: jz.Time,
        d: jz.Time,
        pub const json_tags = .{ .a = "a", .b = "b", .c = "c", .d = "d" };
    };
    var b = jz.Time.date(2024, 2, 29, 23, 59, 59, 123456789);
    b.offset = -(5 * 3600 + 30 * 60);
    try expectStruct(T, &.{
        .a = jz.Time.date(2024, 2, 29, 23, 59, 59, 120000000),
        .b = b,
        .c = jz.Time.date(1969, 12, 31, 23, 59, 59, 1),
        .d = jz.Time.date(1, 1, 1, 0, 0, 0, 0),
    },
        \\{"a":"2024-02-29T23:59:59.12Z","b":"2024-02-29T18:29:59.123456789-05:30","c":"1969-12-31T23:59:59.000000001Z","d":"0001-01-01T00:00:00Z"}
    );
}

test "optionals and non-null pointers" {
    const Inner = struct {
        x: isize,
        pub const json_tags = .{ .x = "x" };
    };
    const T = struct {
        oi: ?isize,
        oin: ?isize,
        of: ?f64,
        os: ?[]const u8,
        osn: ?[]const u8,
        ost: ?Inner,
        ostn: ?Inner,
        pi: *const isize,
        pu: *const u16,
        ps: *const []const u8,
        pst: *const Inner,
        pb: ?*const bool,
        pbn: ?*const bool,
        pub const json_tags = .{ .oi = "oi", .oin = "oin", .of = "of", .os = "os", .osn = "osn", .ost = "ost", .ostn = "ostn", .pi = "pi", .pu = "pu", .ps = "ps", .pst = "pst", .pb = "pb", .pbn = "pbn" };
    };
    const i: isize = -42;
    const u: u16 = 7;
    const s: []const u8 = "str";
    const in: Inner = .{ .x = 3 };
    const t = true;
    try expectStruct(T, &.{
        .oi = -1,
        .oin = null,
        .of = 0.5,
        .os = "o",
        .osn = null,
        .ost = .{ .x = 1 },
        .ostn = null,
        .pi = &i,
        .pu = &u,
        .ps = &s,
        .pst = &in,
        .pb = &t,
        .pbn = null,
    },
        \\{"oi":-1,"oin":null,"of":0.5,"os":"o","osn":null,"ost":{"x":1},"ostn":null,"pi":-42,"pu":7,"ps":"str","pst":{"x":3},"pb":true,"pbn":null}
    );
}

test "integer extremes" {
    const T = struct {
        a: i64,
        b: i8,
        c: u64,
        d: isize,
        e: isize,
        pub const json_tags = .{ .a = "a", .b = "b", .c = "c", .d = "d", .e = "e" };
    };
    try expectStruct(T, &.{ .a = std.math.minInt(i64), .b = -128, .c = std.math.maxInt(u64), .d = 0, .e = -9 },
        \\{"a":-9223372036854775808,"b":-128,"c":18446744073709551615,"d":0,"e":-9}
    );
}

test "integers either side of every power of ten" {
    const T = struct {
        a: isize, // fused run fast path
        b: i64,
        c: u64,
        pub const json_tags = .{ .a = "a", .b = "b", .c = "c" };
    };
    var want: [128]u8 = undefined;
    var pow: u64 = 1;
    for (0..20) |_| {
        for ([_]u64{ pow - 1, pow, pow + 1 }) |u| {
            const s: i64 = @intCast(@min(u, std.math.maxInt(i64)));
            for ([_]i64{ s, -s }) |v| {
                const doc = try std.fmt.bufPrint(&want, "{{\"a\":{d},\"b\":{d},\"c\":{d}}}", .{ v, v, u });
                try expectStruct(T, &.{ .a = v, .b = v, .c = u }, doc);
            }
        }
        pow *%= 10;
    }
}

test "untagged fields are skipped, arrays keep jingo's spacing" {
    const T = struct {
        hidden: isize,
        arr: [3]u8,
        name: []const u8,
        pub const json_tags = .{ .arr = "arr", .name = "name" };
    };
    try expectStruct(T, &.{ .hidden = 9, .arr = .{ 1, 2, 3 }, .name = "n" },
        \\{"arr":[1, 2, 3],"name":"n"}
    );
}

test "stringer and pointer stringer" {
    const Color = enum {
        red,
        pub fn string(c: *const @This()) []const u8 {
            return @tagName(c.*);
        }
    };
    const T = struct {
        c: Color,
        pc: ?*const Color,
        pub const json_tags = .{ .c = "c,stringer", .pc = "pc,stringer" };
    };
    const r: Color = .red;
    try expectStruct(T, &.{ .c = .red, .pc = &r }, "{\"c\":\"red\",\"pc\":\"red\"}");
}

test "jingo quirks: quoted null stringer, spaced arrays, null raw on non-bytes" {
    const Color = enum {
        red,
        pub fn string(c: *const @This()) []const u8 {
            return @tagName(c.*);
        }
    };
    const T = struct {
        pc: ?*const Color,
        a: [3]isize,
        r: isize,
        pub const json_tags = .{ .pc = "pc,stringer", .a = "a", .r = "r,raw" };
    };
    try expectStruct(T, &.{ .pc = null, .a = .{ 1, 2, 3 }, .r = 7 }, "{\"pc\":\"null\",\"a\":[1, 2, 3],\"r\":null}");
}

test "escape on pointer strings and slices of pointer strings" {
    const T = struct {
        s: ?*const []const u8,
        n: ?*const []const u8,
        l: []const ?*const []const u8,
        pub const json_tags = .{ .s = "s,escape", .n = "n,escape", .l = "l,escape" };
    };
    const a: []const u8 = "a\"b";
    const want =
        \\{"s":"a\"b","n":null,"l":["a\"b",null]}
    ;
    try expectStruct(T, &.{ .s = &a, .n = null, .l = &.{ &a, null } }, want);
    try expectValid(want);
}

test "slice encoder element kinds" {
    try expectSlice([]const i32, &&.{ 1, -2, 3 }, "[1,-2,3]");
    try expectSlice([]const f32, &&.{ 1.5, 0.1 }, "[1.5,0.1]");
    try expectSlice([]const bool, &&.{ true, false }, "[true,false]");
    try expectSlice([]const []const i64, &&.{ &.{ 1, 2 }, &.{}, &.{3} }, "[[1,2],[],[3]]");

    const one: u8 = 1;
    try expectSlice([]const ?*const u8, &&.{ &one, null }, "[1,null]");
    try expectSlice([]const ?u8, &&.{ 2, null }, "[2,null]");

    const sl: []const isize = &.{ 4, 5 };
    try expectSlice([]const ?*const []const isize, &&.{ &sl, null }, "[[4,5],null]");

    try expectSlice([]const p.DSUser, &&.{ .{ .username = "a" }, .{ .username = "b" } },
        \\[{"username":"a"},{"username":"b"}]
    );
    try expectSlice([]const p.DSUser, &&.{}, "[]");
    try expectSlice([]const []const u8, &&.{""}, "[\"\"]");
    const t: p.DSTopic = .{ .ID = -12345678901, .slug = "" };
    try expectSlice([]const ?*const p.DSTopic, &&.{ null, &t, null }, "[null,{\"ID\":-12345678901,\"slug\":\"\"},null]");
    try expectSlice([]const ?*const p.DSTopic, &&.{}, "[]");
    const empty: []const u8 = "";
    try expectSlice([]const ?*const []const u8, &&.{ null, &empty, null }, "[null,\"\",null]");
    try expectSlice([]const ?*const []const u8, &&.{}, "[]");
    try expectSlice([]const jz.EscapeString, &&.{ "a\\b", "\n" },
        \\["a\\b","\n"]
    );
    const e: []const u8 = "q\"";
    try expectSlice([]const ?*const jz.EscapeString, &&.{ &e, null },
        \\["q\"",null]
    );
}

test "LargePayload" {
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, "{\"users\":[");
    for (0..100) |i| {
        if (i > 0) try want.append(testing.allocator, ',');
        try want.print(testing.allocator, "{{\"username\":\"test{d}\"}}", .{i});
    }
    try want.appendSlice(testing.allocator, "],\"topics\":{\"topics\":[");
    for (0..100) |i| {
        if (i > 0) try want.append(testing.allocator, ',');
        try want.print(testing.allocator, "{{\"ID\":{d},\"slug\":\"test{d}\"}}", .{ i, i });
    }
    try want.appendSlice(testing.allocator, "],\"more_topics_URL\":\"http://test.com\"}}");
    try expectStruct(p.LargePayload, &p.large_payload, want.items);
}

test "buffer pool reuse and capacity" {
    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();

    const a = try jz.Buffer.fromPoolWithCap(512);
    try testing.expect(a.bytes.capacity >= 512);
    try a.write("hello");
    a.returnToPool();

    const b = try jz.Buffer.fromPool();
    defer b.returnToPool();
    try testing.expect(a == b);
    try testing.expectEqual(@as(usize, 0), b.string().len);
}

test "golden: output is byte-identical to go jingo" {
    const cases = .{
        .{ "example", p.All, &p.example },
        .{ "fake", p.All, &p.fake },
        .{ "small", p.SmallPayload, &p.small_payload },
        .{ "large", p.LargePayload, &p.large_payload },
        .{ "unicode", p.UnicodeObject, &p.unicode },
        .{ "unicode_large", p.UnicodeObjectLarge, &p.unicode_large },
        .{ "time", p.TimeObject, &p.time_object },
    };
    inline for (cases) |c| {
        try expectStruct(c[1], c[2], std.mem.trimEnd(u8, @embedFile("golden/" ++ c[0] ++ ".json"), "\n"));
    }
    try expectSlice([]const []const u8, &&p.slice_strings, std.mem.trimEnd(u8, @embedFile("golden/slice.json"), "\n"));
    try expectSlice([]const jz.EscapeString, &&p.slice_strings, std.mem.trimEnd(u8, @embedFile("golden/slice_escape.json"), "\n"));

    // the escape-everything variants emit the same documents (the inputs need no escaping)
    const e = p.escaped;
    const escaped_cases = .{
        .{ "fake", e.All, &e.fake },
        .{ "small", e.SmallPayload, &e.small_payload },
        .{ "large", e.LargePayload, &e.large_payload },
        .{ "unicode", e.UnicodeObject, &e.unicode },
        .{ "unicode_large", e.UnicodeObjectLarge, &e.unicode_large },
    };
    inline for (escaped_cases) |c| {
        try expectStruct(c[1], c[2], std.mem.trimEnd(u8, @embedFile("golden/" ++ c[0] ++ ".json"), "\n"));
    }
}

const bench_options = @import("bench_options");

fn expectLib(comptime lib: enum { std_json, serde_zig, zerde, yyjson }, v: anytype, golden: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    switch (lib) {
        .std_json => try std.json.Stringify.value(v, .{}, &out.writer),
        .serde_zig => try @import("serde").json.toWriter(&out.writer, v),
        .zerde => {
            const zerde = @import("zerde");
            try zerde.serialize(zerde.json, &out.writer, v);
        },
        .yyjson => {
            const pool = try testing.allocator.alloc(u8, 1 << 20);
            defer testing.allocator.free(pool);
            try @import("yyjson").write(v, pool, &out.writer);
        },
    }
    // the one known divergence: std.json widens f32 to f64 precision (jingo, serde.zig, zerde and yyjson
    // print the shortest f32 form), so its expected document carries the widened digits
    const want = if (lib == .std_json)
        try std.mem.replaceOwned(u8, testing.allocator, golden, "\"propFloat32\":21.232426,", "\"propFloat32\":21.232425689697266,")
    else
        try testing.allocator.dupe(u8, golden);
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, want, "\n"), out.written());
}

test "golden: competing zig encoders produce the same documents as jingo" {
    const g = struct {
        fn f(comptime name: []const u8) []const u8 {
            return @embedFile("golden/" ++ name ++ ".json");
        }
    }.f;
    const slice: []const []const u8 = &p.slice_strings;

    // std.json is always available; the hooks in payloads.zig reproduce jingo's encoder fields
    inline for (.{ .std_json, .serde_zig, .zerde, .yyjson }) |lib| {
        if (lib == .std_json or bench_options.competitors) {
            try expectLib(lib, &p.unicode, g("unicode"));
            try expectLib(lib, &p.unicode_large, g("unicode_large"));
            try expectLib(lib, &slice, g("slice"));
            try expectLib(lib, &p.small_payload, g("small"));
            try expectLib(lib, &p.large_payload, g("large"));
            if (lib != .zerde) {
                // zerde has no custom-serialization hook for the encoder fields and Time
                try expectLib(lib, &p.fake, g("fake"));
                try expectLib(lib, &p.time_object, g("time"));
            }
        }
    }
}

/// reference is jingo's original byte-at-a-time escape loop, kept as the oracle for the simd scan
fn referenceEscape(out: *std.ArrayList(u8), bs: []const u8) !void {
    for (bs) |c| try out.appendSlice(testing.allocator, switch (c) {
        '\\' => "\\\\",
        '"' => "\\\"",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        else => &.{c},
    });
}

test "simd escape matches the byte-at-a-time reference at every length and position" {
    jz.buffer.allocator = testing.allocator;
    defer jz.Buffer.drainPool();

    const T = struct {
        s: []const u8,
        pub const json_tags = .{ .s = "s,escape" };
    };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    const alphabet = "\"\\\n\r\t\x00\x7f\xc3\xa9abcdefgh ";

    var input: [100]u8 = undefined;
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);

    for (0..input.len) |len| {
        for (0..60) |round| {
            for (input[0..len]) |*c| c.* = if (round % 3 == 0) alphabet[r.uintLessThan(usize, alphabet.len)] else r.int(u8);
            const s = input[0..len];

            want.clearRetainingCapacity();
            try want.appendSlice(testing.allocator, "{\"s\":\"");
            try referenceEscape(&want, s);
            try want.appendSlice(testing.allocator, "\"}");

            const b = try jz.Buffer.fromPool();
            defer b.returnToPool();
            try jz.StructEncoder(T).marshal(&.{ .s = s }, b);
            try testing.expectEqualStrings(want.items, b.string());
        }
    }
}

test "readme example" {
    const MyPayload = struct {
        name: []const u8,
        age: isize,
        id: isize,
        pub const json_tags = .{ .name = "name", .age = "age" };
    };
    try expectStruct(MyPayload, &.{ .name = "Mr Payload", .age = 33, .id = 1 }, "{\"name\":\"Mr Payload\",\"age\":33}");
    try expectSlice([]const []const u8, &&.{ "a", "b" }, "[\"a\",\"b\"]");
}
