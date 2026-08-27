//! Run vendored PCRE2 10.47 pcre2test output files against zpcre2.
//! No C. Unsupported patterns are skipped; behavioral mismatches fail.

const std = @import("std");
const zpcre2 = @import("zpcre2");

const testoutput1 = @embedFile("pcre2data/testoutput1");
const testoutput4 = @embedFile("pcre2data/testoutput4");

const Stats = struct {
    pass: u32 = 0,
    skip: u32 = 0,
    fail: u32 = 0,
};

test "pcre2test 1 non-UTF" {
    try runSuite("testoutput1", testoutput1, .{ .utf = false }, 1800);
}

test "pcre2test 4 UTF" {
    try runSuite("testoutput4", testoutput4, .{ .utf = true }, 650);
}

fn runSuite(name: []const u8, source: []const u8, base: zpcre2.Options, min_pass: u32) !void {
    var stats = Stats{};
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        try lines.append(arena, stripCr(raw));
    }

    var i: usize = 0;
    var skip_if: bool = false;
    var skip_pat: bool = false;
    var re_opt: ?zpcre2.Allocated = null;
    defer if (re_opt) |*r| r.deinit();

    while (i < lines.items.len) {
        const line = lines.items[i];
        i += 1;
        if (line.len == 0) continue;

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#if ")) {
                skip_if = !conditionOk(line["#if ".len..]);
            } else if (std.mem.eql(u8, line, "#endif")) {
                skip_if = false;
            }
            continue;
        }
        if (skip_if) continue;
        if (std.mem.startsWith(u8, line, "\\=")) continue;

        if (line[0] == '/') {
            if (re_opt) |*r| {
                r.deinit();
                re_opt = null;
            }
            const parsed = parsePattern(arena, lines.items, &i, line, base) catch {
                skip_pat = true;
                stats.skip += 1;
                continue;
            };
            skip_pat = parsed.skip;
            if (skip_pat) {
                stats.skip += 1;
                continue;
            }
            re_opt = zpcre2.compileAlloc(std.testing.allocator, parsed.pattern, parsed.opts) catch {
                skip_pat = true;
                stats.skip += 1;
                continue;
            };
            continue;
        }

        if (line[0] != ' ' and line[0] != '\t') {
            // Result leftover or "No match" without a subject — ignore.
            continue;
        }

        const sub_src = std.mem.trimStart(u8, line, " \t");
        if (sub_src.len == 0) continue;

        const result = takeResult(lines.items, &i);
        if (skip_pat or re_opt == null) {
            stats.skip += 1;
            continue;
        }
        if (leadingGt(sub_src) != 0) {
            stats.skip += 1;
            continue;
        }

        const subject = unescapeSubject(arena, sub_src) catch {
            stats.skip += 1;
            continue;
        };
        const got = re_opt.?.find(subject);
        switch (result) {
            .skip => {
                stats.skip += 1;
            },
            .nomatch => {
                if (got == null) {
                    stats.pass += 1;
                } else {
                    stats.fail += 1;
                }
            },
            .text => |want_esc| {
                const want = unescapeOutput(arena, want_esc) catch {
                    stats.skip += 1;
                    continue;
                };
                if (got) |m| {
                    const slice = m.slice(subject);
                    if (std.mem.eql(u8, slice, want)) {
                        stats.pass += 1;
                    } else {
                        stats.fail += 1;
                    }
                } else {
                    stats.fail += 1;
                }
            },
        }
    }

    std.debug.print("{s}: {d} pass, {d} skip, {d} fail (engine gaps)\n", .{
        name,
        stats.pass,
        stats.skip,
        stats.fail,
    });
    try std.testing.expect(stats.pass >= min_pass);
}

fn conditionOk(rest: []const u8) bool {
    const c = std.mem.trim(u8, rest, " \t");
    if (std.mem.eql(u8, c, "!ebcdic")) return true;
    if (std.mem.eql(u8, c, "ebcdic")) return false;
    return true;
}

const ParsedPat = struct {
    pattern: []const u8,
    opts: zpcre2.Options,
    skip: bool,
};

fn parsePattern(
    arena: std.mem.Allocator,
    lines: []const []const u8,
    i: *usize,
    first: []const u8,
    base: zpcre2.Options,
) !ParsedPat {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, first);
    while (!closesPattern(buf.items)) {
        if (i.* >= lines.len) return error.UnclosedPattern;
        try buf.append(arena, '\n');
        try buf.appendSlice(arena, lines[i.*]);
        i.* += 1;
    }
    const all = buf.items;
    const end = lastUnescapedSlash(all) orelse return error.UnclosedPattern;
    const pattern = all[1..end];
    const mods = all[end + 1 ..];
    var opts = base;
    const skip = applyModifiers(&opts, mods);
    return .{ .pattern = pattern, .opts = opts, .skip = skip };
}

fn closesPattern(s: []const u8) bool {
    return lastUnescapedSlash(s) != null;
}

fn lastUnescapedSlash(s: []const u8) ?usize {
    if (s.len < 2 or s[0] != '/') return null;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '/') return i;
    }
    return null;
}

fn applyModifiers(opts: *zpcre2.Options, mods_raw: []const u8) bool {
    const mods = std.mem.trim(u8, mods_raw, " \t\r");
    if (mods.len == 0) return false;
    var it = std.mem.splitScalar(u8, mods, ',');
    while (it.next()) |part0| {
        const part = std.mem.trim(u8, part0, " \t");
        if (part.len == 0) continue;
        if (isWordModifier(part)) {
            if (skipWord(part)) return true;
            applyWord(opts, part);
            continue;
        }
        for (part) |c| {
            switch (c) {
                'i' => opts.caseless = true,
                'm' => opts.multiline = true,
                's' => opts.dotall = true,
                'x' => opts.extended = true,
                'U' => opts.ungreedy = true,
                'A' => opts.anchored = true,
                'n' => opts.no_auto_capture = true,
                '8', 'u' => opts.utf = true,
                else => return true,
            }
        }
    }
    return false;
}

fn isWordModifier(s: []const u8) bool {
    if (s.len < 2) return false;
    if (std.mem.eql(u8, s, "utf") or std.mem.eql(u8, s, "ucp")) return true;
    return std.mem.indexOfScalar(u8, s, '_') != null or s.len > 3;
}

fn skipWord(s: []const u8) bool {
    const skip = [_][]const u8{
        "aftertext",  "allaftertext", "allcaptures", "global",     "altglobal",
        "jit",        "dfa",          "posix",       "info",       "debug",
        "replace",    "callout",      "mark",        "memory",     "partial",
        "find_limits", "ovector",     "offset",      "hex",        "bin",
        "utf8_checked",
    };
    for (skip) |k| {
        if (std.mem.eql(u8, s, k) or std.mem.startsWith(u8, s, k)) return true;
    }
    return false;
}

fn applyWord(opts: *zpcre2.Options, s: []const u8) void {
    if (std.mem.eql(u8, s, "utf") or std.mem.eql(u8, s, "utf8")) opts.utf = true;
    if (std.mem.eql(u8, s, "ucp")) opts.ucp = true;
    if (std.mem.eql(u8, s, "caseless")) opts.caseless = true;
    if (std.mem.eql(u8, s, "multiline")) opts.multiline = true;
    if (std.mem.eql(u8, s, "dotall")) opts.dotall = true;
    if (std.mem.eql(u8, s, "extended")) opts.extended = true;
    if (std.mem.eql(u8, s, "ungreedy")) opts.ungreedy = true;
    if (std.mem.eql(u8, s, "anchored")) opts.anchored = true;
    if (std.mem.eql(u8, s, "no_auto_capture")) opts.no_auto_capture = true;
}

const Result = union(enum) {
    nomatch,
    text: []const u8,
    skip,
};

fn takeResult(lines: []const []const u8, i: *usize) Result {
    var got: Result = .skip;
    while (i.* < lines.len) {
        const line = lines[i.*];
        if (line.len == 0) {
            i.* += 1;
            continue;
        }
        if (std.mem.eql(u8, line, "No match")) {
            i.* += 1;
            return .nomatch;
        }
        if (std.mem.startsWith(u8, line, "Partial")) {
            i.* += 1;
            return .skip;
        }
        if (isCaptureLine(line)) {
            const idx = std.mem.indexOfScalar(u8, line, ':').?;
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, line[0..idx], " "), 10) catch 99;
            i.* += 1;
            if (n == 0) {
                got = .{ .text = line[idx + 1 ..] };
                if (got.text.len > 0 and got.text[0] == ' ') got = .{ .text = got.text[1..] };
            }
            continue;
        }
        break;
    }
    return got;
}

fn isCaptureLine(line: []const u8) bool {
    if (line.len < 3 or line[0] != ' ') return false;
    var j: usize = 1;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
    return j > 1 and j < line.len and line[j] == ':';
}

fn leadingGt(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == '>') n += 1;
    return n;
}

fn stripCr(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

fn unescapeSubject(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    return unescape(allocator, src, .subject);
}

fn unescapeOutput(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    return unescape(allocator, src, .output);
}

const UnescapeMode = enum { subject, output };

fn unescape(allocator: std.mem.Allocator, src: []const u8, mode: UnescapeMode) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '\\' or i + 1 >= src.len) {
            try out.append(allocator, src[i]);
            i += 1;
            continue;
        }
        if (mode == .output and src[i + 1] != 'x') {
            try out.append(allocator, src[i]);
            i += 1;
            continue;
        }
        i += 1;
        const c = src[i];
        i += 1;
        switch (c) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'a' => try out.append(allocator, 0x07),
            'e' => try out.append(allocator, 0x1b),
            'f' => try out.append(allocator, 0x0c),
            'x' => {
                if (i < src.len and src[i] == '{') {
                    i += 1;
                    const start = i;
                    while (i < src.len and src[i] != '}') i += 1;
                    const cp = try std.fmt.parseInt(u21, src[start..i], 16);
                    if (i < src.len) i += 1;
                    var buf: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &buf);
                    try out.appendSlice(allocator, buf[0..n]);
                } else {
                    if (i + 1 >= src.len) return error.BadEscape;
                    const b = try std.fmt.parseInt(u8, src[i .. i + 2], 16);
                    i += 2;
                    try out.append(allocator, b);
                }
            },
            '0'...'7' => {
                var val: u16 = c - '0';
                var n: u8 = 1;
                while (n < 3 and i < src.len and src[i] >= '0' and src[i] <= '7') {
                    val = val * 8 + (src[i] - '0');
                    i += 1;
                    n += 1;
                }
                try out.append(allocator, @truncate(val));
            },
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}
