const unicode = @import("unicode.zig");

pub const Range = struct {
    start: u21,
    end: u21,
};

pub const PropSpec = struct {
    prop: unicode.Property,
    negated: bool = false,
};

pub const Class = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },
    negated: bool = false,
    ranges: [16]Range = [_]Range{.{ .start = 0, .end = 0 }} ** 16,
    range_count: u8 = 0,
    props: [4]PropSpec = [_]PropSpec{.{ .prop = .L }} ** 4,
    prop_count: u8 = 0,
    /// When true, `.` / class matching uses UTF-8 code points.
    utf: bool = true,
    caseless: bool = false,

    pub fn setBit(self: *Class, b: u8) void {
        self.bits[b >> 6] |= @as(u64, 1) << @as(u6, @truncate(b));
    }

    pub fn hasBit(self: Class, b: u8) bool {
        return (self.bits[b >> 6] & (@as(u64, 1) << @as(u6, @truncate(b)))) != 0;
    }

    pub fn addRange(self: *Class, start: u21, end: u21) void {
        if (start <= 255 and end <= 255) {
            var c: u21 = start;
            while (c <= end) : (c += 1) {
                self.setBit(@intCast(c));
                if (self.caseless) {
                    const folded = unicode.asciiFold(c);
                    if (folded <= 255) self.setBit(@intCast(folded));
                    if (c >= 'a' and c <= 'z') self.setBit(@intCast(c - 32));
                }
            }
            if (end <= 255) return;
        }
        if (self.range_count < self.ranges.len) {
            self.ranges[self.range_count] = .{ .start = start, .end = end };
            self.range_count += 1;
        }
    }

    pub fn addProp(self: *Class, prop: unicode.Property, negated: bool) void {
        if (self.prop_count < self.props.len) {
            self.props[self.prop_count] = .{ .prop = prop, .negated = negated };
            self.prop_count += 1;
        }
    }

    pub fn addCodepoint(self: *Class, cp: u21) void {
        if (cp <= 255) {
            self.setBit(@intCast(cp));
            if (self.caseless) {
                const folded = unicode.simpleFold(cp);
                if (folded <= 255) self.setBit(@intCast(folded));
            }
            return;
        }
        self.addRange(cp, cp);
        if (self.caseless) {
            const folded = unicode.simpleFold(cp);
            if (folded != cp) self.addRange(folded, folded);
        }
    }

    pub fn matches(self: Class, cp: u21) bool {
        var ok = false;
        if (cp <= 255) {
            ok = self.hasBit(@intCast(cp));
            if (!ok and self.caseless) {
                const folded = unicode.asciiFold(cp);
                if (folded <= 255) ok = self.hasBit(@intCast(folded));
            }
        }
        if (!ok) {
            var i: u8 = 0;
            while (i < self.range_count) : (i += 1) {
                const r = self.ranges[i];
                if (cp >= r.start and cp <= r.end) {
                    ok = true;
                    break;
                }
            }
        }
        if (!ok) {
            var i: u8 = 0;
            while (i < self.prop_count) : (i += 1) {
                const spec = self.props[i];
                const has = unicode.hasProperty(cp, spec.prop);
                if (has != spec.negated) {
                    ok = true;
                    break;
                }
            }
        }
        return if (self.negated) !ok else ok;
    }
};

pub const Quant = struct {
    min: u32,
    max: u32,
    greedy: bool,
    possessive: bool,
    body_end: u32,
};

pub const Look = struct {
    negate: bool,
    behind: bool,
    end: u32,
};

pub const CondGroup = struct {
    group: u16,
    no_branch: u32,
    end: u32,
};

pub const Inst = union(enum) {
    accept,
    fail,
    char: u21,
    char_i: u21,
    any,
    any_nl,
    class: u16,
    jmp: u32,
    split: u32,
    save: u16,
    bol,
    eol,
    bot,
    eot,
    eot_nl,
    word_boundary,
    not_word_boundary,
    start_match, // \G
    backref: u16,
    backref_i: u16,
    quant: Quant,
    look: Look,
    atomic: u32,
    call: u16,
    reset_start,
    newline_seq,
    grapheme,
    commit,
    prune,
    skip,
    then,
    accept_verb,
    cond_group: CondGroup,
};

pub const GroupRange = struct {
    start: u32,
    end: u32,
};

pub const NameEntry = struct {
    index: u32,
    name: []const u8,
};

pub const Program = struct {
    ops: []const Inst,
    classes: []const Class,
    groups: []const GroupRange,
    names: []const NameEntry,
    capture_count: u32,
    flags: @import("options.zig").Flags,
};
