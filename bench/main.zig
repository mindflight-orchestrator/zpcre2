//! zpcre2 vs bundled PCRE2 10.47 interpreter.
//!
//! Compile once, match many times. Higher ratio means zpcre2 is faster.

const std = @import("std");
const Io = std.Io;
const zpcre2 = @import("zpcre2");
const corpus = @import("corpus");
const pcre2 = @import("pcre2_bind");

const default_haystack = 256 * 1024;
const target_ns: i96 = 150 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var haystack_len: usize = default_haystack;
    var filter: ?[]const u8 = null;

    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--size")) {
            i += 1;
            if (i >= args.len) return error.MissingSize;
            haystack_len = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingFilter;
            filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--help")) {
            try out.print(
                "usage: zpcre2-bench [--size BYTES] [--filter SUBSTR]\n",
                .{},
            );
            try out.flush();
            return;
        } else {
            try out.print("unknown arg: {s}\n", .{args[i]});
            try out.flush();
            return error.UnknownArg;
        }
    }

    try out.print("zpcre2 vs PCRE2 10.47 interpreter  ({s})\n", .{@tagName(@import("builtin").mode)});
    try out.print("haystack {d} bytes, match-only after compile\n\n", .{haystack_len});
    try out.print(
        "{s:<16} {s:>8} {s:>12} {s:>12} {s:>8} {s}\n",
        .{ "case", "iters", "zpcre2 ns", "pcre2 ns", "ratio", "" },
    );

    var zig_wins: u32 = 0;
    var pcre_wins: u32 = 0;

    for (corpus.bench_cases) |case| {
        if (filter) |f| {
            if (std.mem.find(u8, case.name, f) == null) continue;
        }

        const haystack = try makeHaystack(gpa, case, haystack_len);
        defer gpa.free(haystack);

        var zig_re = try zpcre2.compileAlloc(gpa, case.pattern, case.opts);
        defer zig_re.deinit();
        const pcre_re = try pcre2.compile(case.pattern, case.opts);
        defer pcre_re.deinit();

        const zig_probe = zig_re.find(case.probe);
        const pcre_probe = pcre_re.find(case.probe);
        if (case.expect_match) {
            if (zig_probe == null or pcre_probe == null or
                zig_probe.?.start != pcre_probe.?.start or
                zig_probe.?.end != pcre_probe.?.end)
            {
                try out.print("{s:<16}  SKIP oracle mismatch on probe\n", .{case.name});
                continue;
            }
        } else if (zig_probe != null or pcre_probe != null) {
            try out.print("{s:<16}  SKIP expected miss, got a match\n", .{case.name});
            continue;
        }

        const zig_ns = try timeMatch(io, zig_re, haystack);
        const pcre_ns = try timeMatchPcre(io, pcre_re, haystack);
        const ratio = @as(f64, @floatFromInt(pcre_ns.ns_per_op)) /
            @as(f64, @floatFromInt(@max(zig_ns.ns_per_op, 1)));
        const label: []const u8 = if (ratio >= 1.05) "zig faster" else if (ratio <= 0.95) "pcre2 faster" else "tie";
        if (ratio >= 1.05) zig_wins += 1 else if (ratio <= 0.95) pcre_wins += 1;

        try out.print(
            "{s:<16} {d:>8} {d:>12} {d:>12} {d:>7.2}x {s}\n",
            .{ case.name, zig_ns.iters, zig_ns.ns_per_op, pcre_ns.ns_per_op, ratio, label },
        );
        try out.flush();
    }

    try out.print("\nzig faster: {d}   pcre2 faster: {d}\n", .{ zig_wins, pcre_wins });
    try out.flush();
}

fn makeHaystack(allocator: std.mem.Allocator, case: corpus.BenchCase, size: usize) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    var off: usize = 0;
    while (off < size) {
        const n = @min(case.filler.len, size - off);
        @memcpy(buf[off..][0..n], case.filler[0..n]);
        off += n;
    }
    if (case.expect_match) {
        const start = size / 2;
        if (start + case.probe.len <= size) {
            @memcpy(buf[start..][0..case.probe.len], case.probe);
        }
    } else {
        // Wipe any accidental copies of the literal from the filler.
        if (std.mem.eql(u8, case.pattern, "http")) {
            for (buf, 0..) |ch, idx| {
                if (ch == 'h' or ch == 'H') buf[idx] = 'x';
            }
        }
    }
    return buf;
}

const Timing = struct {
    iters: u32,
    ns_per_op: u64,
};

fn timeMatch(io: Io, re: zpcre2.Allocated, haystack: []const u8) !Timing {
    return timeLoop(io, struct {
        fn run(ctx: zpcre2.Allocated, subject: []const u8) void {
            const m = ctx.find(subject);
            std.mem.doNotOptimizeAway(m);
            if (m) |found| std.mem.doNotOptimizeAway(found.start + found.end);
        }
    }.run, re, haystack);
}

fn timeMatchPcre(io: Io, re: pcre2.Compiled, haystack: []const u8) !Timing {
    return timeLoop(io, struct {
        fn run(ctx: pcre2.Compiled, subject: []const u8) void {
            const m = ctx.find(subject);
            std.mem.doNotOptimizeAway(m);
            if (m) |found| std.mem.doNotOptimizeAway(found.start + found.end);
        }
    }.run, re, haystack);
}

fn timeLoop(
    io: Io,
    comptime run: anytype,
    ctx: anytype,
    haystack: []const u8,
) !Timing {
    var iters: u32 = 8;
    while (true) {
        const start = Io.Clock.awake.now(io).nanoseconds;
        var n: u32 = 0;
        while (n < iters) : (n += 1) run(ctx, haystack);
        const elapsed = Io.Clock.awake.now(io).nanoseconds - start;
        if (elapsed >= target_ns or iters >= 1 << 20) {
            const ns_per_op: u64 = @intCast(@divTrunc(elapsed, iters));
            return .{ .iters = iters, .ns_per_op = ns_per_op };
        }
        iters *= 2;
    }
}
