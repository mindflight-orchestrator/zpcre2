const std = @import("std");
const zpcre2 = @import("zpcre2");
const corpus = @import("corpus.zig");
const pcre2 = @import("pcre2_bind.zig");

fn expectSame(pattern: []const u8, subject: []const u8, opts: zpcre2.Options) !void {
    var re = zpcre2.compileAlloc(std.testing.allocator, pattern, opts) catch |err| {
        std.debug.print("zpcre2 compile failed for {s}: {}\n", .{ pattern, err });
        return err;
    };
    defer re.deinit();
    const got = re.find(subject);
    const want = pcre2.find(pattern, subject, opts);
    if (got == null and want == null) return;
    if (got == null or want == null) {
        std.debug.print("mismatch null pattern={s} subject={s} zpcre2={?} pcre2={?}\n", .{
            pattern,
            subject,
            got,
            want,
        });
        return error.OracleMismatch;
    }
    try std.testing.expectEqual(want.?.start, got.?.start);
    try std.testing.expectEqual(want.?.end, got.?.end);
}

test "oracle core syntax" {
    for (corpus.oracle_cases) |case| {
        try expectSame(case.pattern, case.subject, case.opts);
    }
}

test "oracle bench probes" {
    for (corpus.bench_cases) |case| {
        var re = try zpcre2.compileAlloc(std.testing.allocator, case.pattern, case.opts);
        defer re.deinit();
        const got = re.find(case.probe);
        const want = pcre2.find(case.pattern, case.probe, case.opts);
        if (case.expect_match) {
            try std.testing.expect(want != null);
            try std.testing.expect(got != null);
            try std.testing.expectEqual(want.?.start, got.?.start);
            try std.testing.expectEqual(want.?.end, got.?.end);
        } else {
            try std.testing.expect(want == null);
            try std.testing.expect(got == null);
        }
    }
}

test "xfail documented gaps" {
    try std.testing.expectError(
        error.UnsupportedSyntax,
        zpcre2.compileAlloc(std.testing.allocator, "\\C", .{}),
    );
}
