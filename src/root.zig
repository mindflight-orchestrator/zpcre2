//! zpcre2 — PCRE2 10.47-compatible regular expressions in pure Zig 0.16.
//!
//! Compile a pattern at comptime or at runtime; match with a backtracking VM.

const std = @import("std");
const analyze_mod = @import("analyze.zig");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compile_mod = @import("compile.zig");
const match_mod = @import("match.zig");
const options_mod = @import("options.zig");
const parse_mod = @import("parse.zig");
const scratch_mod = @import("scratch.zig");

pub const analyze = analyze_mod;
pub const options = options_mod;
pub const unicode = @import("unicode.zig");
pub const scratch = scratch_mod;

pub const Options = options_mod.Options;
pub const Diagnostics = options_mod.Diagnostics;
pub const Error = options_mod.Error;
pub const spec_version = options_mod.spec_version;

pub const Match = match_mod.Match;
pub const Captures = match_mod.Captures;
pub const Scratch = scratch_mod.Scratch;
pub const MatchLimits = scratch_mod.MatchLimits;

pub const Compiled = struct {
    ops: []const bytecode.Inst,
    classes: []const bytecode.Class,
    groups: []const bytecode.GroupRange,
    names: []const bytecode.NameEntry,
    capture_count: u32,
    options: Options,
    flags: options_mod.Flags,
    study: analyze_mod.Info,

    pub fn program(self: Compiled) bytecode.Program {
        return .{
            .ops = self.ops,
            .classes = self.classes,
            .groups = self.groups,
            .names = self.names,
            .capture_count = self.capture_count,
            .flags = self.flags,
        };
    }

    pub fn find(self: Compiled, subject: []const u8) ?Match {
        return self.findFrom(subject, 0);
    }

    pub fn findFrom(self: Compiled, subject: []const u8, start: usize) ?Match {
        return findProgramFrom(self.program(), subject, self.study, start);
    }

    pub fn isMatch(self: Compiled, subject: []const u8) bool {
        return self.find(subject) != null;
    }

    pub fn captures(self: Compiled, subject: []const u8, sc: *Scratch) ?Captures {
        sc.reset();
        return match_mod.findCaptures(self.program(), subject, sc.slots, .{}, self.study);
    }

    pub fn isMatchComptime(self: Compiled, comptime subject: []const u8) bool {
        return self.isMatch(subject);
    }
};

pub const Allocated = struct {
    allocator: std.mem.Allocator,
    ops: []bytecode.Inst,
    classes: []bytecode.Class,
    groups: []bytecode.GroupRange,
    names: []bytecode.NameEntry,
    capture_count: u32,
    options: Options,
    flags: options_mod.Flags,
    study: analyze_mod.Info,

    pub fn deinit(self: *Allocated) void {
        self.allocator.free(self.ops);
        self.allocator.free(self.classes);
        self.allocator.free(self.groups);
        self.allocator.free(self.names);
    }

    pub fn program(self: Allocated) bytecode.Program {
        return .{
            .ops = self.ops,
            .classes = self.classes,
            .groups = self.groups,
            .names = self.names,
            .capture_count = self.capture_count,
            .flags = self.flags,
        };
    }

    pub fn find(self: Allocated, subject: []const u8) ?Match {
        return self.findFrom(subject, 0);
    }

    pub fn findFrom(self: Allocated, subject: []const u8, start: usize) ?Match {
        return findProgramFrom(self.program(), subject, self.study, start);
    }

    pub fn isMatch(self: Allocated, subject: []const u8) bool {
        return self.find(subject) != null;
    }

    pub fn captures(self: Allocated, subject: []const u8, sc: *Scratch) ?Captures {
        sc.reset();
        return match_mod.findCaptures(self.program(), subject, sc.slots, .{}, self.study);
    }
};

fn findProgram(program: bytecode.Program, subject: []const u8, study: analyze_mod.Info) ?Match {
    return findProgramFrom(program, subject, study, 0);
}

fn findProgramFrom(
    program: bytecode.Program,
    subject: []const u8,
    study: analyze_mod.Info,
    start: usize,
) ?Match {
    var buf: [128]?usize = undefined;
    const n = @min(2 * (@as(usize, program.capture_count) + 1), buf.len);
    const slots = buf[0..n];
    @memset(slots, null);
    return match_mod.findFrom(program, subject, slots, .{}, study, start);
}

/// Compile `pattern` at comptime. Invalid patterns fail the build.
pub fn compile(comptime pattern: []const u8, comptime opts: Options) Compiled {
    @setEvalBranchQuota(2_000_000);
    return comptime compileComptime(pattern, opts);
}

fn compileComptime(comptime pattern: []const u8, comptime opts: Options) Compiled {
    var diag = Diagnostics{};
    var parser = parse_mod.Parser.init(pattern, opts, &diag) catch |err| {
        @compileError("zpcre2: failed to compile pattern: " ++ @errorName(err));
    };
    const root = parser.parse() catch |err| {
        @compileError("zpcre2: failed to compile pattern: " ++ @errorName(err));
    };
    var emitter = compile_mod.Emitter.init(&parser);
    emitter.lower(root) catch |err| {
        @compileError("zpcre2: failed to lower pattern: " ++ @errorName(err));
    };
    const program = emitter.program();

    var ops_copy: [program.ops.len]bytecode.Inst = undefined;
    @memcpy(&ops_copy, program.ops);
    const ops_final = ops_copy;

    var classes_copy: [program.classes.len]bytecode.Class = undefined;
    @memcpy(&classes_copy, program.classes);
    const classes_final = classes_copy;

    var groups_copy: [program.groups.len]bytecode.GroupRange = undefined;
    @memcpy(&groups_copy, program.groups);
    const groups_final = groups_copy;

    var names_copy: [program.names.len]bytecode.NameEntry = undefined;
    @memcpy(&names_copy, program.names);
    const names_final = names_copy;

    const compiled = bytecode.Program{
        .ops = &ops_final,
        .classes = &classes_final,
        .groups = &groups_final,
        .names = &names_final,
        .capture_count = program.capture_count,
        .flags = program.flags,
    };
    return .{
        .ops = compiled.ops,
        .classes = compiled.classes,
        .groups = compiled.groups,
        .names = compiled.names,
        .capture_count = compiled.capture_count,
        .options = opts,
        .flags = compiled.flags,
        .study = analyze_mod.analyze(compiled),
    };
}

pub fn compileAlloc(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) Error!Allocated {
    var diag = Diagnostics{};
    return compileAllocDiag(allocator, pattern, opts, &diag);
}

pub fn compileAllocDiag(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    opts: Options,
    diag: *Diagnostics,
) Error!Allocated {
    var parser = try parse_mod.Parser.init(pattern, opts, diag);
    const root = try parser.parse();
    var emitter = compile_mod.Emitter.init(&parser);
    try emitter.lower(root);
    const program = emitter.program();

    const ops = try allocator.dupe(bytecode.Inst, program.ops);
    errdefer allocator.free(ops);
    const classes = try allocator.dupe(bytecode.Class, program.classes);
    errdefer allocator.free(classes);
    const groups = try allocator.dupe(bytecode.GroupRange, program.groups);
    errdefer allocator.free(groups);
    const names = try allocator.dupe(bytecode.NameEntry, program.names);
    errdefer allocator.free(names);

    const compiled = bytecode.Program{
        .ops = ops,
        .classes = classes,
        .groups = groups,
        .names = names,
        .capture_count = program.capture_count,
        .flags = program.flags,
    };
    return .{
        .allocator = allocator,
        .ops = ops,
        .classes = classes,
        .groups = groups,
        .names = names,
        .capture_count = program.capture_count,
        .options = opts,
        .flags = program.flags,
        .study = analyze_mod.analyze(compiled),
    };
}

test "comptime compile smoke" {
    const re = compile("abc", .{});
    try std.testing.expect(re.isMatch("abc"));
    try std.testing.expect(re.isMatch("zzabc"));
    try std.testing.expect(!re.isMatch("ab"));
    try std.testing.expect(re.isMatchComptime("abc"));
}

test "runtime compile smoke" {
    var re = try compileAlloc(std.testing.allocator, "abc", .{});
    defer re.deinit();
    try std.testing.expect(re.isMatch("abc"));
    try std.testing.expectEqual(@as(usize, 0), re.find("abc").?.start);
    try std.testing.expectEqual(@as(usize, 3), re.find("abc").?.end);
}

test "dot and anchors" {
    const re = compile("^a.c$", .{});
    try std.testing.expect(re.isMatch("abc"));
    try std.testing.expect(re.isMatch("aXc"));
    try std.testing.expect(!re.isMatch("abbc"));
    try std.testing.expect(!re.isMatch("xabc"));
}

test "dot does not match newline unless dotall" {
    const re = compile("a.b", .{});
    try std.testing.expect(!re.isMatch("a\nb"));
    const re2 = compile("a.b", .{ .dotall = true });
    try std.testing.expect(re2.isMatch("a\nb"));
}

test "character class" {
    const re = compile("[a-c]+", .{});
    try std.testing.expect(re.isMatch("abcb"));
    try std.testing.expect(!re.isMatch("xyz"));
    const neg = compile("[^0-9]+", .{});
    try std.testing.expect(neg.isMatch("abc"));
    try std.testing.expectEqual(@as(usize, 0), neg.find("abc123").?.start);
}

test "shorthands" {
    const d = compile("\\d+", .{});
    try std.testing.expect(d.isMatch("42"));
    try std.testing.expect(!d.isMatch("ab"));
    const w = compile("\\w+", .{});
    try std.testing.expect(w.isMatch("foo_1"));
    const s = compile("a\\sb", .{});
    try std.testing.expect(s.isMatch("a b"));
}

test "quantifiers greedy lazy possessive" {
    const g = compile("a*b", .{});
    try std.testing.expectEqualStrings("aaab", g.find("aaab").?.slice("aaab"));
    const l = compile("a*?b", .{});
    try std.testing.expectEqualStrings("aaab", l.find("aaab").?.slice("aaab"));
    const p = compile("a++b", .{});
    try std.testing.expect(p.isMatch("aaab"));
    const q = compile("a{2,4}", .{});
    try std.testing.expectEqual(@as(usize, 4), q.find("aaaaa").?.end);
    const q2 = compile("a{2}", .{});
    try std.testing.expectEqual(@as(usize, 2), q2.find("aaa").?.end);
}

test "alternation and groups" {
    const re = compile("(foo|bar)", .{});
    try std.testing.expect(re.isMatch("bar"));
    try std.testing.expectEqual(@as(u32, 1), re.capture_count);
    var sc = try Scratch.init(std.testing.allocator, re.capture_count);
    defer sc.deinit();
    const caps = re.captures("xxfooyy", &sc).?;
    try std.testing.expectEqualStrings("foo", caps.group(1).?);
}

test "non-capturing group" {
    const re = compile("(?:ab)+", .{});
    try std.testing.expect(re.isMatch("abab"));
    try std.testing.expectEqual(@as(u32, 0), re.capture_count);
}

test "escapes" {
    const re = compile("a\\n\\t\\\\b", .{});
    try std.testing.expect(re.isMatch("a\n\t\\b"));
    const hex = compile("\\x41\\x{42}", .{});
    try std.testing.expect(hex.isMatch("AB"));
}

test "caseless" {
    const re = compile("abc", .{ .caseless = true });
    try std.testing.expect(re.isMatch("ABC"));
    try std.testing.expect(re.isMatch("AbC"));
}

test "multiline" {
    const re = compile("^foo$", .{ .multiline = true });
    try std.testing.expect(re.isMatch("x\nfoo\ny"));
}

test "invalid pattern runtime" {
    try std.testing.expectError(error.InvalidPattern, compileAlloc(std.testing.allocator, "(", .{}));
    try std.testing.expectError(error.InvalidPattern, compileAlloc(std.testing.allocator, "[", .{}));
}

test "utf8 dot" {
    const re = compile("a.b", .{});
    try std.testing.expect(re.isMatch("aéb"));
    try std.testing.expect(re.isMatch("a你b"));
}

test "word boundary" {
    const re = compile("\\bfoo\\b", .{});
    try std.testing.expect(re.isMatch("foo"));
    try std.testing.expect(re.isMatch("a foo b"));
    try std.testing.expect(!re.isMatch("afoob"));
}

test "named groups and backrefs" {
    const re = compile("(?<num>\\d+)-\\k<num>", .{});
    try std.testing.expect(re.isMatch("12-12"));
    try std.testing.expect(!re.isMatch("12-13"));
    const re2 = compile("(\\w)\\1", .{});
    try std.testing.expect(re2.isMatch("aa"));
    try std.testing.expect(!re2.isMatch("ab"));
}

test "lookahead lookbehind" {
    const ahead = compile("foo(?=bar)", .{});
    try std.testing.expectEqualStrings("foo", ahead.find("foobar").?.slice("foobar"));
    try std.testing.expect(ahead.find("foobaz") == null);
    const behind = compile("(?<=foo)bar", .{});
    try std.testing.expectEqualStrings("bar", behind.find("foobar").?.slice("foobar"));
    try std.testing.expect(behind.find("bazbar") == null);
    const neg = compile("foo(?!bar)", .{});
    try std.testing.expect(neg.isMatch("foobaz"));
    try std.testing.expect(!neg.isMatch("foobar"));
}

test "unicode properties" {
    const re = compile("\\p{L}+", .{});
    try std.testing.expect(re.isMatch("Café"));
    try std.testing.expect(re.isMatch("你好"));
    const nd = compile("\\p{Nd}+", .{});
    try std.testing.expect(nd.isMatch("42"));
}

test "inline flags" {
    const re = compile("(?i)abc", .{});
    try std.testing.expect(re.isMatch("ABC"));
    const scoped = compile("(?i:ab)c", .{});
    try std.testing.expect(scoped.isMatch("ABc"));
    try std.testing.expect(!scoped.isMatch("ABC"));
}

test "atomic group" {
    const re = compile("(?>a+)a", .{});
    try std.testing.expect(!re.isMatch("aaa"));
    const re2 = compile("(?>a+)b", .{});
    try std.testing.expect(re2.isMatch("aaab"));
}

test "conditional" {
    const re = compile("(a)?(?(1)b|c)", .{});
    try std.testing.expect(re.isMatch("ab"));
    try std.testing.expect(re.isMatch("c"));
    try std.testing.expect(!re.isMatch("b"));
}

test "recursion" {
    const re = compile("\\((?:[^()]++|(?R))*\\)", .{});
    try std.testing.expect(re.isMatch("(a(b)c)"));
    try std.testing.expectEqualStrings("(a(b)c)", re.find("(a(b)c)").?.slice("(a(b)c)"));
    try std.testing.expectEqualStrings("(b)", re.find("(a(b)").?.slice("(a(b)"));
}

test "control verbs" {
    const fail = compile("a(*FAIL)", .{});
    try std.testing.expect(!fail.isMatch("a"));
    const acc = compile("a(*ACCEPT)b", .{});
    try std.testing.expectEqualStrings("a", acc.find("ab").?.slice("ab"));
}

test "reset start and newline seq" {
    const k = compile("foo\\Kbar", .{});
    try std.testing.expectEqualStrings("bar", k.find("foobar").?.slice("foobar"));
    const r = compile("a\\Rb", .{});
    try std.testing.expect(r.isMatch("a\nb"));
    try std.testing.expect(r.isMatch("a\r\nb"));
}

test "extended mode" {
    const re = compile("a #comment\nc", .{ .extended = true });
    try std.testing.expect(re.isMatch("ac"));
}

test "quoted literals" {
    const re = compile("\\Q.*+?\\E", .{});
    try std.testing.expect(re.isMatch(".*+?"));
}

test "posix class" {
    const re = compile("[[:digit:]]+", .{});
    try std.testing.expect(re.isMatch("123"));
}

test "branch reset" {
    const re = compile("(?|(a)|(b))", .{});
    try std.testing.expectEqual(@as(u32, 1), re.capture_count);
    try std.testing.expect(re.isMatch("b"));
}

test "unsupported syntax errors" {
    try std.testing.expectError(error.UnsupportedSyntax, compileAlloc(std.testing.allocator, "\\C", .{}));
}

test "spec version" {
    try std.testing.expectEqualStrings("10.47", spec_version);
}

test "findFrom honors lookbehind across the start offset" {
    var re = try compileAlloc(std.testing.allocator, "(?<=x)a", .{});
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 1), re.findFrom("xaxa", 0).?.start);
    try std.testing.expectEqual(@as(usize, 3), re.findFrom("xaxa", 2).?.start);
    try std.testing.expect(re.findFrom("xaxa", 4) == null);
}

test "unanchored skip finds in the middle of a long haystack" {
    var re = try compileAlloc(std.testing.allocator, "needle", .{});
    defer re.deinit();
    var buf: [4096]u8 = undefined;
    @memset(&buf, 'x');
    @memcpy(buf[2000..][0..6], "needle");
    try std.testing.expectEqual(@as(usize, 2000), re.find(&buf).?.start);
    try std.testing.expect(re.find("xxxxxxxx") == null);
}

test "optional first atom still matches" {
    const re = compile("a*b", .{});
    try std.testing.expect(re.isMatch("b"));
    try std.testing.expect(re.isMatch("aaab"));
    const re2 = compile("a?b", .{});
    try std.testing.expect(re2.isMatch("b"));
}

test "analyze prefix and start bits" {
    const lit = compile("http", .{});
    const lit_info = analyze.analyze(lit.program());
    try std.testing.expectEqual(@as(u8, 'h'), lit_info.first_byte.?);
    try std.testing.expectEqual(@as(u8, 4), lit_info.prefix_len);

    const digits = compile("\\d+", .{});
    const d_info = analyze.analyze(digits.program());
    try std.testing.expect(d_info.has_start_bits or d_info.first_byte != null);

    const alt = compile("foo|bar", .{});
    const a_info = analyze.analyze(alt.program());
    try std.testing.expect(a_info.first_byte != null or a_info.has_start_bits);
}

test {
    _ = ast;
    _ = analyze_mod;
    _ = unicode;
    std.testing.refAllDecls(@This());
}
