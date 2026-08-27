//! C PCRE2 10.47 bindings for tests and benchmarks. Not part of the library.

const zpcre2 = @import("zpcre2");
const c = @import("c");

pub fn compileFlags(opts: zpcre2.Options) u32 {
    var options: u32 = c.PCRE2_UTF;
    if (opts.caseless) options |= c.PCRE2_CASELESS;
    if (opts.multiline) options |= c.PCRE2_MULTILINE;
    if (opts.dotall) options |= c.PCRE2_DOTALL;
    if (opts.extended) options |= c.PCRE2_EXTENDED;
    if (opts.anchored) options |= c.PCRE2_ANCHORED;
    if (opts.ungreedy) options |= c.PCRE2_UNGREEDY;
    if (opts.ucp) options |= c.PCRE2_UCP;
    return options;
}

pub const Compiled = struct {
    re: *c.pcre2_code_8,
    md: *c.pcre2_match_data_8,

    pub fn deinit(self: Compiled) void {
        c.pcre2_match_data_free_8(self.md);
        c.pcre2_code_free_8(self.re);
    }

    pub fn find(self: Compiled, subject: []const u8) ?zpcre2.Match {
        const rc = c.pcre2_match_8(
            self.re,
            subject.ptr,
            subject.len,
            0,
            c.PCRE2_NO_UTF_CHECK,
            self.md,
            null,
        );
        if (rc < 0) return null;
        const ovector = c.pcre2_get_ovector_pointer_8(self.md);
        return .{ .start = ovector[0], .end = ovector[1] };
    }
};

pub fn compile(pattern: []const u8, opts: zpcre2.Options) error{CompileFailed}!Compiled {
    var errcode: c_int = 0;
    var erroffset: c.PCRE2_SIZE = 0;
    const re = c.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        compileFlags(opts),
        &errcode,
        &erroffset,
        null,
    ) orelse return error.CompileFailed;
    const md = c.pcre2_match_data_create_from_pattern_8(re, null) orelse {
        c.pcre2_code_free_8(re);
        return error.CompileFailed;
    };
    return .{ .re = re, .md = md };
}

pub fn find(pattern: []const u8, subject: []const u8, opts: zpcre2.Options) ?zpcre2.Match {
    const compiled = compile(pattern, opts) catch return null;
    defer compiled.deinit();
    return compiled.find(subject);
}
