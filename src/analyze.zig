const std = @import("std");
const bytecode = @import("bytecode.zig");
const unicode = @import("unicode.zig");

pub const Info = struct {
    min_length: u32 = 0,
    first_byte: ?u8 = null,
    first_byte2: ?u8 = null,
    prefix: [16]u8 = undefined,
    prefix_len: u8 = 0,
    start_bits: [4]u64 = .{ 0, 0, 0, 0 },
    has_start_bits: bool = false,
    /// A later literal that must appear in a match. Used when start_bits are wide.
    req_byte: ?u8 = null,
    /// A later mandatory ASCII string, after the start atom. Used even when a
    /// prefix exists: a common prefix plus a rare tail (`status=500`) should
    /// skip on the tail.
    req_lit: [32]u8 = undefined,
    req_lit_len: u8 = 0,
    /// Linear ASCII chain (lits, possessive class runs, 2-way lit alts).
    /// When set, `find` verifies from the skip atom instead of running the VM.
    chain: Chain = .{},
};

pub const ChainAtom = union(enum) {
    lit: struct { off: u8, len: u8 },
    cls: struct { idx: u16, min: u32, max: u32 },
    alt: struct { a_off: u8, a_len: u8, b_off: u8, b_len: u8 },
};

pub const Chain = struct {
    atoms: [8]ChainAtom = undefined,
    n: u8 = 0,
    lits: [64]u8 = undefined,
    lit_n: u8 = 0,
    skip: u8 = 0,
    /// Bitmask of `.save` slots to set at each atom's start / end (slots 0..15).
    start_slots: [8]u16 = .{0} ** 8,
    end_slots: [8]u16 = .{0} ** 8,

    pub fn litSlice(self: *const Chain, off: u8, len: u8) []const u8 {
        return self.lits[off..][0..len];
    }
};

const StartSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },
    unknown: bool = false,
    empty_ok: bool = false,
    prefix: [16]u8 = undefined,
    prefix_len: u8 = 0,
    prefix_ok: bool = true,

    fn addByte(self: *StartSet, b: u8) void {
        self.bits[b >> 6] |= @as(u64, 1) << @as(u6, @truncate(b));
    }

    fn addPrefix(self: *StartSet, b: u8) void {
        if (!self.prefix_ok or self.prefix_len >= self.prefix.len) {
            self.prefix_ok = false;
            return;
        }
        self.prefix[self.prefix_len] = b;
        self.prefix_len += 1;
    }

    fn merge(self: *StartSet, other: StartSet) void {
        self.unknown = self.unknown or other.unknown;
        self.empty_ok = self.empty_ok or other.empty_ok;
        self.bits[0] |= other.bits[0];
        self.bits[1] |= other.bits[1];
        self.bits[2] |= other.bits[2];
        self.bits[3] |= other.bits[3];
        if (!other.prefix_ok) self.prefix_ok = false;
        var n: u8 = 0;
        const lim = @min(self.prefix_len, other.prefix_len);
        while (n < lim and self.prefix[n] == other.prefix[n]) n += 1;
        self.prefix_len = n;
        if (self.prefix_len < 2) self.prefix_ok = false;
    }

    fn bitCount(self: StartSet) u16 {
        return @as(u16, @popCount(self.bits[0])) + @as(u16, @popCount(self.bits[1])) +
            @as(u16, @popCount(self.bits[2])) + @as(u16, @popCount(self.bits[3]));
    }

    fn nthBit(self: StartSet, n: u16) ?u8 {
        var seen: u16 = 0;
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const byte: u8 = @intCast(b);
            if ((self.bits[byte >> 6] & (@as(u64, 1) << @as(u6, @truncate(byte)))) == 0) continue;
            if (seen == n) return byte;
            seen += 1;
        }
        return null;
    }

    fn toInfo(self: StartSet) Info {
        var info = Info{};
        info.min_length = if (self.empty_ok) 0 else 1;
        if (self.unknown) return info;

        const n = self.bitCount();
        if (n == 0) return info;
        if (n == 256) return info;

        if (self.prefix_ok and self.prefix_len >= 2) {
            info.prefix = self.prefix;
            info.prefix_len = self.prefix_len;
            info.first_byte = self.prefix[0];
            return info;
        }

        if (n == 1) {
            info.first_byte = self.nthBit(0);
            return info;
        }
        if (n == 2) {
            info.first_byte = self.nthBit(0);
            info.first_byte2 = self.nthBit(1);
            return info;
        }

        info.start_bits = self.bits;
        info.has_start_bits = true;
        return info;
    }
};

pub fn analyze(program: bytecode.Program) Info {
    var set = StartSet{};
    collect(program, 0, @intCast(program.ops.len), &set, 0);
    var info = set.toInfo();
    if (info.has_start_bits and set.bitCount() > 8) {
        info.req_byte = requiredLiteral(program, info.start_bits);
    }
    fillRequiredLater(program, &info);
    fillChain(program, &info);
    return info;
}

fn requiredLiteral(program: bytecode.Program, bits: [4]u64) ?u8 {
    for (program.ops) |op| {
        switch (op) {
            .char => |cp| {
                if (cp > 255) continue;
                const b: u8 = @intCast(cp);
                if ((bits[b >> 6] & (@as(u64, 1) << @as(u6, @truncate(b)))) == 0) return b;
            },
            else => {},
        }
    }
    return null;
}

/// Longest ASCII `.char` run that must appear after the start atom.
/// Conservative: never take bytes from a split, optional quant, or lookaround.
fn fillRequiredLater(program: bytecode.Program, info: *Info) void {
    var best: [32]u8 = undefined;
    var best_len: u8 = 0;
    var run: [32]u8 = undefined;
    var run_len: u8 = 0;
    var past_start = false;
    var i: usize = 0;

    const flush = struct {
        fn go(
            past: *bool,
            run_buf: []u8,
            run_n: *u8,
            best_buf: *[32]u8,
            best_n: *u8,
        ) void {
            if (past.* and run_n.* >= 3 and run_n.* >= best_n.*) {
                @memcpy(best_buf[0..run_n.*], run_buf[0..run_n.*]);
                best_n.* = run_n.*;
            }
            if (run_n.* > 0) past.* = true;
            run_n.* = 0;
        }
    }.go;

    while (i < program.ops.len) {
        switch (program.ops[i]) {
            .save, .commit, .reset_start => i += 1,
            .bol, .eol, .bot, .eot, .eot_nl, .word_boundary, .not_word_boundary, .start_match => i += 1,
            .char => |cp| {
                if (cp > 127) {
                    flush(&past_start, &run, &run_len, &best, &best_len);
                    past_start = true;
                    i += 1;
                    continue;
                }
                if (run_len < run.len) {
                    run[run_len] = @intCast(cp);
                    run_len += 1;
                }
                i += 1;
            },
            .quant => |q| {
                flush(&past_start, &run, &run_len, &best, &best_len);
                past_start = true;
                i = q.body_end;
            },
            .split => |alt| {
                flush(&past_start, &run, &run_len, &best, &best_len);
                past_start = true;
                if (alt == 0 or alt > program.ops.len or alt < 1) break;
                switch (program.ops[alt - 1]) {
                    .jmp => |join| {
                        if (join < alt) break;
                        i = join;
                    },
                    else => break,
                }
            },
            .jmp => |t| {
                flush(&past_start, &run, &run_len, &best, &best_len);
                if (t <= i) break;
                i = t;
            },
            .look => |l| {
                flush(&past_start, &run, &run_len, &best, &best_len);
                i = l.end;
            },
            .cond_group => |cg| {
                flush(&past_start, &run, &run_len, &best, &best_len);
                past_start = true;
                i = cg.end;
            },
            .accept, .accept_verb, .fail, .prune, .skip, .then => break,
            else => {
                flush(&past_start, &run, &run_len, &best, &best_len);
                past_start = true;
                i += 1;
            },
        }
    }
    flush(&past_start, &run, &run_len, &best, &best_len);

    if (best_len < 3) return;
    if (info.prefix_len >= 2 and best_len == info.prefix_len and
        std.mem.eql(u8, best[0..best_len], info.prefix[0..info.prefix_len]))
        return;
    info.req_lit = best;
    info.req_lit_len = best_len;
}

fn fillChain(program: bytecode.Program, info: *Info) void {
    var chain = Chain{};
    var pending: [32]u8 = undefined;
    var pending_n: u8 = 0;
    var pending_start: u16 = 0;
    var i: usize = 0;

    const flushPending = struct {
        fn go(chain_p: *Chain, buf: []const u8, n: *u8, starts: *u16) bool {
            if (n.* == 0) return true;
            if (!addLit(chain_p, buf[0..n.*])) return false;
            n.* = 0;
            attachStarts(chain_p, starts);
            return true;
        }
    }.go;

    while (i < program.ops.len) {
        switch (program.ops[i]) {
            .commit, .reset_start => return,
            .save => |slot| {
                if (!flushPending(&chain, &pending, &pending_n, &pending_start)) return;
                if (slot >= 16) return;
                const bit: u16 = @as(u16, 1) << @intCast(slot);
                if (slot % 2 == 0) {
                    pending_start |= bit;
                } else {
                    if (chain.n == 0) return;
                    chain.end_slots[chain.n - 1] |= bit;
                }
                i += 1;
            },
            .char => |cp| {
                if (cp > 127 or pending_n >= pending.len) return;
                pending[pending_n] = @intCast(cp);
                pending_n += 1;
                i += 1;
            },
            .quant => |q| {
                if (!flushPending(&chain, &pending, &pending_n, &pending_start)) return;
                if (q.min == 0) return;
                if (q.body_end != i + 2) return;
                switch (program.ops[i + 1]) {
                    .class => |idx| {
                        if (idx >= program.classes.len) return;
                        const class = program.classes[idx];
                        if (class.negated or class.range_count != 0 or class.prop_count != 0) return;
                        if (chain.n >= chain.atoms.len) return;
                        chain.atoms[chain.n] = .{ .cls = .{ .idx = idx, .min = q.min, .max = q.max } };
                        chain.n += 1;
                        attachStarts(&chain, &pending_start);
                        i = q.body_end;
                    },
                    else => return,
                }
            },
            .split => |alt| {
                if (!flushPending(&chain, &pending, &pending_n, &pending_start)) return;
                if (alt == 0 or alt > program.ops.len or alt < 1) return;
                const join = switch (program.ops[alt - 1]) {
                    .jmp => |t| t,
                    else => return,
                };
                if (join < alt or join > program.ops.len) return;
                var a_buf: [32]u8 = undefined;
                var b_buf: [32]u8 = undefined;
                const a_len = asciiChars(program, i + 1, alt - 1, &a_buf) orelse return;
                const b_len = asciiChars(program, alt, join, &b_buf) orelse return;
                if (a_len == 0 or b_len == 0) return;
                if (chain.lit_n + a_len + b_len > chain.lits.len or chain.n >= chain.atoms.len) return;
                const a_off = chain.lit_n;
                @memcpy(chain.lits[a_off..][0..a_len], a_buf[0..a_len]);
                chain.lit_n += a_len;
                const b_off = chain.lit_n;
                @memcpy(chain.lits[b_off..][0..b_len], b_buf[0..b_len]);
                chain.lit_n += b_len;
                chain.atoms[chain.n] = .{ .alt = .{
                    .a_off = a_off,
                    .a_len = a_len,
                    .b_off = b_off,
                    .b_len = b_len,
                } };
                chain.n += 1;
                attachStarts(&chain, &pending_start);
                i = join;
            },
            .jmp => |t| {
                if (!flushPending(&chain, &pending, &pending_n, &pending_start)) return;
                if (t <= i) return;
                i = t;
            },
            .accept, .accept_verb => break,
            else => return,
        }
    }
    if (!flushPending(&chain, &pending, &pending_n, &pending_start)) return;
    if (pending_start != 0) return;
    if (chain.n < 2) return;

    var skip: u8 = 0;
    var best_len: u8 = 0;
    var found_req = false;
    var ai: u8 = 0;
    while (ai < chain.n) : (ai += 1) {
        switch (chain.atoms[ai]) {
            .lit => |lit| {
                const slice = chain.litSlice(lit.off, lit.len);
                if (info.req_lit_len >= 3 and std.mem.eql(u8, slice, info.req_lit[0..info.req_lit_len])) {
                    skip = ai;
                    found_req = true;
                    best_len = lit.len;
                } else if (!found_req and lit.len >= best_len) {
                    skip = ai;
                    best_len = lit.len;
                }
            },
            else => {},
        }
    }
    if (best_len < 2) return;
    chain.skip = skip;
    if (!chainClassesSafe(program, chain)) return;
    info.chain = chain;
}

fn attachStarts(chain: *Chain, pending_start: *u16) void {
    chain.start_slots[chain.n - 1] = pending_start.*;
    pending_start.* = 0;
}

fn chainClassesSafe(program: bytecode.Program, chain: Chain) bool {
    var i: u8 = 0;
    while (i < chain.n) : (i += 1) {
        switch (chain.atoms[i]) {
            .cls => |c| {
                if (c.idx >= program.classes.len) return false;
                const class = program.classes[c.idx];
                if (i > 0 and !classDisjointAtom(program, class, chain, chain.atoms[i - 1], .last))
                    return false;
                if (i + 1 < chain.n and !classDisjointAtom(program, class, chain, chain.atoms[i + 1], .first))
                    return false;
            },
            else => {},
        }
    }
    return true;
}

fn classDisjointAtom(
    program: bytecode.Program,
    class: bytecode.Class,
    chain: Chain,
    atom: ChainAtom,
    end: enum { first, last },
) bool {
    switch (atom) {
        .lit => |lit| {
            const slice = chain.litSlice(lit.off, lit.len);
            if (slice.len == 0) return false;
            const b = if (end == .first) slice[0] else slice[slice.len - 1];
            return !asciiClassBit(class, b);
        },
        .cls => |c| {
            if (c.idx >= program.classes.len) return false;
            return classesBitsDisjoint(class, program.classes[c.idx]);
        },
        .alt => |a| {
            const sa = chain.litSlice(a.a_off, a.a_len);
            const sb = chain.litSlice(a.b_off, a.b_len);
            if (sa.len == 0 or sb.len == 0) return false;
            const ba = if (end == .first) sa[0] else sa[sa.len - 1];
            const bb = if (end == .first) sb[0] else sb[sb.len - 1];
            return !asciiClassBit(class, ba) and !asciiClassBit(class, bb);
        },
    }
}

fn classesBitsDisjoint(a: bytecode.Class, b: bytecode.Class) bool {
    return (a.bits[0] & b.bits[0]) == 0 and
        (a.bits[1] & b.bits[1]) == 0 and
        (a.bits[2] & b.bits[2]) == 0 and
        (a.bits[3] & b.bits[3]) == 0;
}

fn asciiClassBit(class: bytecode.Class, b: u8) bool {
    return b < 0x80 and class.hasBit(b);
}

fn addLit(chain: *Chain, bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    if (chain.n >= chain.atoms.len) return false;
    if (chain.lit_n + bytes.len > chain.lits.len) return false;
    const off = chain.lit_n;
    @memcpy(chain.lits[off..][0..bytes.len], bytes);
    chain.lit_n += @intCast(bytes.len);
    chain.atoms[chain.n] = .{ .lit = .{ .off = off, .len = @intCast(bytes.len) } };
    chain.n += 1;
    return true;
}

fn asciiChars(program: bytecode.Program, start: usize, end: usize, buf: *[32]u8) ?u8 {
    var n: u8 = 0;
    var i = start;
    while (i < end) {
        switch (program.ops[i]) {
            .save, .commit, .reset_start => i += 1,
            .char => |cp| {
                if (cp > 127 or n >= buf.len) return null;
                buf[n] = @intCast(cp);
                n += 1;
                i += 1;
            },
            else => return null,
        }
    }
    return n;
}

fn collect(program: bytecode.Program, start_pc: u32, end_pc: u32, set: *StartSet, depth: u8) void {
    if (set.unknown or depth > 24) {
        set.unknown = true;
        return;
    }
    var i: u32 = start_pc;
    const end = @min(end_pc, @as(u32, @intCast(program.ops.len)));
    while (i < end) {
        switch (program.ops[i]) {
            .save, .commit, .reset_start => i += 1,
            .bol, .eol, .bot, .eot, .eot_nl, .word_boundary, .not_word_boundary, .start_match => i += 1,
            .look => |l| {
                i = l.end;
            },
            .fail, .prune, .skip, .then => return,
            .accept, .accept_verb => {
                set.empty_ok = true;
                return;
            },
            .jmp => |t| {
                i = t;
            },
            .char => |cp| {
                if (cp <= 255) {
                    set.addByte(@intCast(cp));
                    set.addPrefix(@intCast(cp));
                    extendPrefix(program, i + 1, end, set);
                } else {
                    set.unknown = true;
                }
                return;
            },
            .char_i => |cp| {
                set.prefix_ok = false;
                if (cp <= 255) {
                    const b: u8 = @intCast(cp);
                    set.addByte(b);
                    const folded: u8 = @intCast(unicode.asciiFold(cp));
                    if (folded != b) set.addByte(folded);
                    if (b >= 'a' and b <= 'z') set.addByte(b - 32);
                    if (b >= 'A' and b <= 'Z') set.addByte(b + 32);
                } else {
                    set.unknown = true;
                }
                return;
            },
            .class => |idx| {
                set.prefix_ok = false;
                if (idx >= program.classes.len) {
                    set.unknown = true;
                    return;
                }
                mergeClass(program.classes[idx], set);
                return;
            },
            .any, .any_nl, .newline_seq, .grapheme, .backref, .backref_i, .call => {
                set.unknown = true;
                return;
            },
            .split => |alt| {
                var a = StartSet{};
                var b = StartSet{};
                collect(program, i + 1, end, &a, depth + 1);
                collect(program, alt, end, &b, depth + 1);
                set.merge(a);
                set.merge(b);
                return;
            },
            .quant => |q| {
                var inner = StartSet{};
                collect(program, i + 1, q.body_end, &inner, depth + 1);
                if (q.min == 0) {
                    var rest = StartSet{};
                    collect(program, q.body_end, end, &rest, depth + 1);
                    set.merge(inner);
                    set.merge(rest);
                } else {
                    set.merge(inner);
                }
                return;
            },
            .atomic => |aend| {
                collect(program, i + 1, aend, set, depth + 1);
                return;
            },
            .cond_group => |cg| {
                var yes = StartSet{};
                var no = StartSet{};
                collect(program, i + 1, end, &yes, depth + 1);
                collect(program, cg.no_branch, end, &no, depth + 1);
                set.merge(yes);
                set.merge(no);
                return;
            },
        }
    }
    set.empty_ok = true;
}

fn extendPrefix(program: bytecode.Program, start_pc: u32, end_pc: u32, set: *StartSet) void {
    var j = start_pc;
    while (j < end_pc) {
        switch (program.ops[j]) {
            .save => j += 1,
            .char => |cp| {
                if (cp > 127) break;
                set.addPrefix(@intCast(cp));
                j += 1;
            },
            else => break,
        }
    }
}

fn mergeClass(class: bytecode.Class, set: *StartSet) void {
    if (class.negated) {
        set.unknown = true;
        return;
    }
    set.bits[0] |= class.bits[0];
    set.bits[1] |= class.bits[1];
    set.bits[2] |= class.bits[2];
    set.bits[3] |= class.bits[3];
    if (class.prop_count > 0) {
        var b: u16 = 0;
        while (b < 128) : (b += 1) {
            if (class.matches(@intCast(b))) set.addByte(@intCast(b));
        }
        if (class.utf) {
            b = 128;
            while (b < 256) : (b += 1) set.addByte(@intCast(b));
        }
    }
}

test "start bits popcount" {
    var set = StartSet{};
    set.addByte('0');
    set.addByte('9');
    try std.testing.expectEqual(@as(u16, 2), set.bitCount());
}
