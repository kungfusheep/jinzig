const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("jinzig", .{
        .root_source_file = b.path("src/jinzig.zig"),
        .target = target,
        .optimize = optimize,
    });

    // the payloads from jingo_test.go, shared by tests and benchmarks
    const payloads = b.createModule(.{
        .root_source_file = b.path("bench/payloads.zig"),
        .imports = &.{.{ .name = "jinzig", .module = mod }},
    });
    // third-party encoders for comparison, fetched by bench/third_party.sh
    const competitors = b.option(bool, "competitors", "include zerde and serde.zig (run bench/third_party.sh first)") orelse false;
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "competitors", competitors);
    const bench_options_mod = bench_options.createModule();
    payloads.addImport("bench_options", bench_options_mod);

    var import_list: std.ArrayList(std.Build.Module.Import) = .empty;
    import_list.appendSlice(b.allocator, &.{
        .{ .name = "jinzig", .module = mod },
        .{ .name = "payloads", .module = payloads },
        .{ .name = "bench_options", .module = bench_options_mod },
    }) catch @panic("OOM");
    if (competitors) {
        const zerde = b.createModule(.{ .root_source_file = b.path("bench/third_party/zerde/src/root.zig") });
        const serde_compat = b.createModule(.{ .root_source_file = b.path("bench/third_party/serde.zig/src/compat_0_16.zig") });
        const serde = b.createModule(.{
            .root_source_file = b.path("bench/third_party/serde.zig/src/root.zig"),
            .imports = &.{.{ .name = "compat", .module = serde_compat }},
        });
        const tp = "bench/third_party/";
        const lalinsky = b.createModule(.{ .root_source_file = b.path(tp ++ "lalinsky-json/src/json.zig") });
        const jaysan = b.createModule(.{ .root_source_file = b.path(tp ++ "jaysan/src/main.zig") });
        const sakakibara = b.createModule(.{ .root_source_file = b.path(tp ++ "sakakibara-json/src/json.zig") });
        const zserde = b.createModule(.{ .root_source_file = b.path(tp ++ "zserde/src/root.zig") });
        const jsonz_float = b.createModule(.{ .root_source_file = b.path(tp ++ "jsonz/src/float/root.zig") });
        const jsonz = b.createModule(.{
            .root_source_file = b.path(tp ++ "jsonz/src/root.zig"),
            .imports = &.{.{ .name = "float", .module = jsonz_float }},
        });

        // zig-json wraps the yyjson C library; 0.17 translates its header here instead of @cImport
        const yyjson_h = b.addTranslateC(.{
            .root_source_file = b.path(tp ++ "zig-json/vendor/yyjson/yyjson.h"),
            .target = target,
            .optimize = optimize,
        });
        yyjson_h.defineCMacro("YYJSON_DISABLE_UTILS", "1");
        const yyjson_c = yyjson_h.createModule();
        const zig_json = b.createModule(.{
            .root_source_file = b.path(tp ++ "zig-json/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "yyjson_c", .module = yyjson_c }},
        });
        zig_json.addIncludePath(b.path(tp ++ "zig-json/vendor/yyjson"));
        zig_json.addCSourceFile(.{ .file = b.path(tp ++ "zig-json/vendor/yyjson/yyjson.c"), .flags = &.{ "-std=c99", "-DYYJSON_DISABLE_UTILS=1" } });

        // payloads declares lalinsky/json.zig's StructOptions to keep null fields, like jingo does
        payloads.addImport("lalinsky_json", lalinsky);
        import_list.appendSlice(b.allocator, &.{
            .{ .name = "zerde", .module = zerde },
            .{ .name = "serde", .module = serde },
            .{ .name = "lalinsky_json", .module = lalinsky },
            .{ .name = "jaysan", .module = jaysan },
            .{ .name = "zig_json", .module = zig_json },
            .{ .name = "sakakibara_json", .module = sakakibara },
            .{ .name = "zserde", .module = zserde },
            .{ .name = "jsonz", .module = jsonz },
            .{ .name = "yyjson", .module = b.createModule(.{
                .root_source_file = b.path("bench/yyjson.zig"),
                .imports = &.{ .{ .name = "jinzig", .module = mod }, .{ .name = "yyjson_c", .module = yyjson_c } },
            }) },
        }) catch @panic("OOM");
    }
    const imports = import_list.items;

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const bench = b.addExecutable(.{
        .name = "jinzig-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
