//! PCRE2 10.47 expected-match tests. No C.

const std = @import("std");
const zpcre2 = @import("zpcre2");
const corpus = @import("corpus.zig");

fn expectSpan(pattern: []const u8, subject: []const u8, opts: zpcre2.Options, want: ?corpus.Span) !void {
    var re = zpcre2.compileAlloc(std.testing.allocator, pattern, opts) catch |err| {
        std.debug.print("compile failed for {s}: {}\n", .{ pattern, err });
        return err;
    };
    defer re.deinit();
    const got = re.find(subject);
    if (want) |span| {
        const m = got orelse {
            std.debug.print("expected match {s} in {s}\n", .{ pattern, subject });
            return error.ExpectedMatch;
        };
        try std.testing.expectEqual(span.start, m.start);
        try std.testing.expectEqual(span.end, m.end);
    } else {
        try std.testing.expect(got == null);
    }
}

test "pcre2 10.47 core syntax spans" {
    for (corpus.oracle_cases) |case| {
        try expectSpan(case.pattern, case.subject, case.opts, case.match);
    }
}

test "pcre2 10.47 bench probe spans" {
    for (corpus.bench_cases) |case| {
        try expectSpan(case.pattern, case.probe, case.opts, case.match);
    }
}

test "unsupported \\C" {
    try std.testing.expectError(
        error.UnsupportedSyntax,
        zpcre2.compileAlloc(std.testing.allocator, "\\C", .{}),
    );
}
