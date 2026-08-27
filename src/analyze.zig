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
