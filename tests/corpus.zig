const zpcre2 = @import("zpcre2");

pub const Span = struct { start: usize, end: usize };

pub const OracleCase = struct {
    pattern: []const u8,
    subject: []const u8,
    opts: zpcre2.Options = .{},
    /// PCRE2 10.47 interpreter span; null means no match.
    match: ?Span,
};

pub const oracle_cases = [_]OracleCase{
    .{ .pattern = "abc", .subject = "zzabc", .match = .{ .start = 2, .end = 5 } },
    .{ .pattern = "^abc$", .subject = "abc", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "a.c", .subject = "aXc", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "[a-c]+", .subject = "abcbx", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "\\d+", .subject = "ab12cd", .match = .{ .start = 2, .end = 4 } },
    .{ .pattern = "a*b", .subject = "aaab", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "a+b", .subject = "aaab", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "a?b", .subject = "b", .match = .{ .start = 0, .end = 1 } },
    .{ .pattern = "foo|bar", .subject = "xxbar", .match = .{ .start = 2, .end = 5 } },
    .{ .pattern = "(foo|bar)", .subject = "bar", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "(?:ab)+c", .subject = "ababc", .match = .{ .start = 0, .end = 5 } },
    .{ .pattern = "a{2,4}", .subject = "aaaaa", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "a*?b", .subject = "aaab", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "\\bfoo\\b", .subject = "a foo b", .match = .{ .start = 2, .end = 5 } },
    .{ .pattern = "(a)\\1", .subject = "aa", .match = .{ .start = 0, .end = 2 } },
    .{ .pattern = "foo(?=bar)", .subject = "foobar", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "(?<=foo)bar", .subject = "foobar", .match = .{ .start = 3, .end = 6 } },
    .{ .pattern = "foo(?!bar)", .subject = "foobaz", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "(?i)abc", .subject = "ABC", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "a\\sb", .subject = "a b", .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "[[:digit:]]+", .subject = "x123y", .match = .{ .start = 1, .end = 4 } },
    .{ .pattern = "\\Q.*\\E", .subject = ".*", .match = .{ .start = 0, .end = 2 } },
    .{ .pattern = "foo\\Kbar", .subject = "foobar", .match = .{ .start = 3, .end = 6 } },
    .{ .pattern = "(?>a+)b", .subject = "aaab", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "(a)?(?(1)b|c)", .subject = "ab", .match = .{ .start = 0, .end = 2 } },
    .{ .pattern = "(a)?(?(1)b|c)", .subject = "c", .match = .{ .start = 0, .end = 1 } },
    .{ .pattern = "abc", .subject = "ABC", .opts = .{ .caseless = true }, .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "^foo$", .subject = "x\nfoo\ny", .opts = .{ .multiline = true }, .match = .{ .start = 2, .end = 5 } },
    .{ .pattern = "a.b", .subject = "a\nb", .opts = .{ .dotall = true }, .match = .{ .start = 0, .end = 3 } },
    .{ .pattern = "a.b", .subject = "aéb", .match = .{ .start = 0, .end = 4 } },
    .{ .pattern = "\\p{L}+", .subject = "Café!", .match = .{ .start = 0, .end = 5 } },
};

pub const BenchCase = struct {
    name: []const u8,
    pattern: []const u8,
    probe: []const u8,
    filler: []const u8,
    opts: zpcre2.Options = .{},
    expect_match: bool = true,
    match: ?Span = null,
};

pub const bench_cases = [_]BenchCase{
    .{
        .name = "literal-hit",
        .pattern = "http",
        .probe = "see http now",
        .filler = "GET /index.html proto none\n",
        .match = .{ .start = 4, .end = 8 },
    },
    .{
        .name = "literal-miss",
        .pattern = "http",
        .probe = "no match here",
        .filler = "GET /index.html proto none\n",
        .expect_match = false,
    },
    .{
        .name = "digits",
        .pattern = "\\d+",
        .probe = "id=42;",
        .filler = "user=anon path=/var/log host=local\n",
        .match = .{ .start = 3, .end = 5 },
    },
    .{
        .name = "word-boundary",
        .pattern = "\\bfoo\\b",
        .probe = "a foo b",
        .filler = "xx a xxx b yy food z\n",
        .match = .{ .start = 2, .end = 5 },
    },
    .{
        .name = "alternation",
        .pattern = "foo|bar|baz",
        .probe = "xxbar",
        .filler = "aaa xxx yyy zzz qqq\n",
        .match = .{ .start = 2, .end = 5 },
    },
    .{
        .name = "quantifier",
        .pattern = "a+b",
        .probe = "aaab",
        .filler = "xxxx yyyy zzzz\n",
        .match = .{ .start = 0, .end = 4 },
    },
    .{
        .name = "date-groups",
        .pattern = "(\\d{4})-(\\d{2})-(\\d{2})",
        .probe = "date 2026-08-27",
        .filler = "log event ok status=ready\n",
        .match = .{ .start = 5, .end = 15 },
    },
    .{
        .name = "email",
        .pattern = "[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}",
        .probe = "mail user@example.com end",
        .filler = "from local via smtp relay\n",
        .match = .{ .start = 5, .end = 21 },
    },
    .{
        .name = "class-range",
        .pattern = "[a-c]+",
        .probe = "abcbx",
        .filler = "zzzz qqqq wwww\n",
        .match = .{ .start = 0, .end = 4 },
    },
    .{
        .name = "utf-letters",
        .pattern = "\\p{L}+",
        .probe = "Café!",
        .filler = "1234567890 !@# $%^ &*\n",
        .match = .{ .start = 0, .end = 5 },
    },
};
