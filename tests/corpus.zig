const zpcre2 = @import("zpcre2");

pub const OracleCase = struct {
    pattern: []const u8,
    subject: []const u8,
    opts: zpcre2.Options = .{},
};

pub const oracle_cases = [_]OracleCase{
    .{ .pattern = "abc", .subject = "zzabc" },
    .{ .pattern = "^abc$", .subject = "abc" },
    .{ .pattern = "a.c", .subject = "aXc" },
    .{ .pattern = "[a-c]+", .subject = "abcbx" },
    .{ .pattern = "\\d+", .subject = "ab12cd" },
    .{ .pattern = "a*b", .subject = "aaab" },
    .{ .pattern = "a+b", .subject = "aaab" },
    .{ .pattern = "a?b", .subject = "b" },
    .{ .pattern = "foo|bar", .subject = "xxbar" },
    .{ .pattern = "(foo|bar)", .subject = "bar" },
    .{ .pattern = "(?:ab)+c", .subject = "ababc" },
    .{ .pattern = "a{2,4}", .subject = "aaaaa" },
    .{ .pattern = "a*?b", .subject = "aaab" },
    .{ .pattern = "\\bfoo\\b", .subject = "a foo b" },
    .{ .pattern = "(a)\\1", .subject = "aa" },
    .{ .pattern = "foo(?=bar)", .subject = "foobar" },
    .{ .pattern = "(?<=foo)bar", .subject = "foobar" },
    .{ .pattern = "foo(?!bar)", .subject = "foobaz" },
    .{ .pattern = "(?i)abc", .subject = "ABC" },
    .{ .pattern = "a\\sb", .subject = "a b" },
    .{ .pattern = "[[:digit:]]+", .subject = "x123y" },
    .{ .pattern = "\\Q.*\\E", .subject = ".*" },
    .{ .pattern = "foo\\Kbar", .subject = "foobar" },
    .{ .pattern = "(?>a+)b", .subject = "aaab" },
    .{ .pattern = "(a)?(?(1)b|c)", .subject = "ab" },
    .{ .pattern = "(a)?(?(1)b|c)", .subject = "c" },
    .{ .pattern = "abc", .subject = "ABC", .opts = .{ .caseless = true } },
    .{ .pattern = "^foo$", .subject = "x\nfoo\ny", .opts = .{ .multiline = true } },
    .{ .pattern = "a.b", .subject = "a\nb", .opts = .{ .dotall = true } },
    .{ .pattern = "a.b", .subject = "aéb" },
    .{ .pattern = "\\p{L}+", .subject = "Café!" },
};

pub const BenchCase = struct {
    name: []const u8,
    pattern: []const u8,
    /// Small subject used by the oracle to check zpcre2 agrees with PCRE2.
    probe: []const u8,
    /// Repeated to build the match haystack.
    filler: []const u8,
    opts: zpcre2.Options = .{},
    expect_match: bool = true,
};

pub const bench_cases = [_]BenchCase{
    .{
        .name = "literal-hit",
        .pattern = "http",
        .probe = "see http now",
        .filler = "GET /index.html proto none\n",
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
    },
    .{
        .name = "word-boundary",
        .pattern = "\\bfoo\\b",
        .probe = "a foo b",
        .filler = "xx a xxx b yy food z\n",
    },
    .{
        .name = "alternation",
        .pattern = "foo|bar|baz",
        .probe = "xxbar",
        .filler = "aaa xxx yyy zzz qqq\n",
    },
    .{
        .name = "quantifier",
        .pattern = "a+b",
        .probe = "aaab",
        .filler = "xxxx yyyy zzzz\n",
    },
    .{
        .name = "date-groups",
        .pattern = "(\\d{4})-(\\d{2})-(\\d{2})",
        .probe = "date 2026-08-27",
        .filler = "log event ok status=ready\n",
    },
    .{
        .name = "email",
        .pattern = "[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}",
        .probe = "mail user@example.com end",
        .filler = "from local via smtp relay\n",
    },
    .{
        .name = "class-range",
        .pattern = "[a-c]+",
        .probe = "abcbx",
        .filler = "zzzz qqqq wwww\n",
    },
    .{
        .name = "utf-letters",
        .pattern = "\\p{L}+",
        .probe = "Café!",
        .filler = "1234567890 !@# $%^ &*\n",
    },
};
