//! Study skip: required later literals. Runtime compile, as grep uses.

const std = @import("std");
const zpcre2 = @import("zpcre2");

const inner_ere = "route=/api/item/[[:digit:]]+[[:space:]]+status=500";

fn reqLit(info: zpcre2.analyze.Info) []const u8 {
    return info.req_lit[0..info.req_lit_len];
}

fn compile(pattern: []const u8) !zpcre2.Allocated {
    return zpcre2.compileAlloc(std.testing.allocator, pattern, .{});
}

test "study extracts a later literal after a common prefix" {
    var re = try compile(inner_ere);
    defer re.deinit();
    try std.testing.expectEqualStrings("status=500", reqLit(re.study));
    try std.testing.expect(re.study.prefix_len >= 2);
    try std.testing.expectEqualStrings(
        "route=/api/item/",
        re.study.prefix[0..re.study.prefix_len],
    );
}

test "study does not require one side of an alternation" {
    var re = try compile("status=(200|500)");
    defer re.deinit();
    try std.testing.expectEqual(@as(u8, 0), re.study.req_lit_len);
}

test "study extracts a later literal after alternation" {
    var re = try compile("(foo|bar)required");
    defer re.deinit();
    try std.testing.expectEqualStrings("required", reqLit(re.study));
}

test "study does not treat a pure prefix as a later literal" {
    var re = try compile("http");
    defer re.deinit();
    try std.testing.expectEqual(@as(u8, 0), re.study.req_lit_len);
    try std.testing.expectEqualStrings("http", re.study.prefix[0..re.study.prefix_len]);
}

test "study does not require an optional run" {
    var re = try compile("foo?bar");
    defer re.deinit();
    try std.testing.expectEqualStrings("bar", reqLit(re.study));
}

test "skip ignores a common prefix and finds the later literal" {
    var re = try compile(inner_ere);
    defer re.deinit();

    const miss = "route=/api/item/1 status=200\n";
    const hit = "route=/api/item/9 status=500\n";
    var buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off + miss.len + hit.len <= buf.len) {
        @memcpy(buf[off..][0..miss.len], miss);
        off += miss.len;
    }
    const hit_at = off;
    @memcpy(buf[off..][0..hit.len], hit);
    off += hit.len;

    const m = re.find(buf[0..off]).?;
    try std.testing.expectEqual(hit_at, m.start);
    try std.testing.expect(re.find(miss) == null);
    try std.testing.expectEqual(@as(usize, 0), re.find(hit).?.start);
}

test "skip rejects a later literal that lacks the prefix" {
    var re = try compile(inner_ere);
    defer re.deinit();
    try std.testing.expect(re.find("status=500") == null);
    try std.testing.expect(re.find("nope status=500") == null);
    const m = re.find("xxroute=/api/item/42 status=500yy").?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
}

test "findFrom still skips from a mid-buffer offset" {
    var re = try compile(inner_ere);
    defer re.deinit();
    const subject = "route=/api/item/1 status=500 route=/api/item/2 status=500";
    const first = re.findFrom(subject, 0).?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    const second = re.findFrom(subject, first.end).?;
    try std.testing.expectEqual(first.end + 1, second.start);
    try std.testing.expect(re.findFrom(subject, second.end) == null);
}

test "chain matcher covers inner literal and status alt" {
    var inner = try compile(inner_ere);
    defer inner.deinit();
    try std.testing.expectEqual(@as(u8, 4), inner.study.chain.n);
    try std.testing.expectEqual(@as(u8, 3), inner.study.chain.skip);

    var alt = try compile("status=(200|500)");
    defer alt.deinit();
    try std.testing.expectEqual(@as(u8, 2), alt.study.chain.n);

    const line200 = "2026 INFO route=/api/item/1 status=200 latency=3";
    const line500 = "2026 INFO route=/api/item/9 status=500 latency=3";
    try std.testing.expect(inner.find(line200) == null);
    const hit = inner.find(line500).?;
    try std.testing.expectEqualStrings(
        "route=/api/item/9 status=500",
        line500[hit.start..hit.end],
    );
    try std.testing.expect(alt.isMatch(line200));
    try std.testing.expect(alt.isMatch(line500));
    try std.testing.expect(!alt.isMatch("status=404"));
}

test "study later literal for class-plus suffix" {
    var re = try compile("[A-Z]+_RESUME");
    defer re.deinit();
    try std.testing.expectEqualStrings("_RESUME", reqLit(re.study));
    try std.testing.expect(re.isMatch("xxxABC_RESUMExxx"));
}

test "chain matcher fills capture slots" {
    var re = try compile("status=(200|500)");
    defer re.deinit();
    try std.testing.expect(re.study.chain.n >= 2);
    var sc = try zpcre2.Scratch.init(std.testing.allocator, re.capture_count);
    defer sc.deinit();
    const caps = re.captures("x status=500 y", &sc).?;
    try std.testing.expectEqualStrings("status=500", caps.group(0).?);
    try std.testing.expectEqualStrings("500", caps.group(1).?);
    const caps200 = re.captures("status=200", &sc).?;
    try std.testing.expectEqualStrings("200", caps200.group(1).?);
}

test "chain matcher fills group 0 for inner literal" {
    var re = try compile(inner_ere);
    defer re.deinit();
    var sc = try zpcre2.Scratch.init(std.testing.allocator, re.capture_count);
    defer sc.deinit();
    const line = "xxroute=/api/item/42 status=500yy";
    const caps = re.captures(line, &sc).?;
    try std.testing.expectEqualStrings("route=/api/item/42 status=500", caps.group(0).?);
}
