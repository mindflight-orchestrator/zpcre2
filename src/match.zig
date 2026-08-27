const std = @import("std");
const analyze = @import("analyze.zig");
const bytecode = @import("bytecode.zig");
const options = @import("options.zig");
const scratch_mod = @import("scratch.zig");
const unicode = @import("unicode.zig");

const Inst = bytecode.Inst;
const Program = bytecode.Program;

pub const Match = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Match, subject: []const u8) []const u8 {
        return subject[self.start..self.end];
    }
};

pub const Captures = struct {
    subject: []const u8,
    slots: []const ?usize,

    pub fn group(self: Captures, n: usize) ?[]const u8 {
        const i = n * 2;
        if (i + 1 >= self.slots.len) return null;
        const a = self.slots[i] orelse return null;
        const b = self.slots[i + 1] orelse return null;
        if (a > b or b > self.subject.len) return null;
        return self.subject[a..b];
    }

    pub fn span(self: Captures) ?Match {
        const g = self.group(0) orelse return null;
        const start = self.slots[0].?;
        return .{ .start = start, .end = start + g.len };
    }
};

pub const ExecError = error{MatchLimit};

pub fn find(program: Program, subject: []const u8, slots: []?usize, limits: scratch_mod.MatchLimits, info: analyze.Info) ?Match {
    var caps = findCaptures(program, subject, slots, limits, info) orelse return null;
    return caps.span();
}

pub fn isMatch(program: Program, subject: []const u8, slots: []?usize, limits: scratch_mod.MatchLimits, info: analyze.Info) bool {
    return find(program, subject, slots, limits, info) != null;
}

pub fn findCaptures(program: Program, subject: []const u8, slots: []?usize, limits: scratch_mod.MatchLimits, info: analyze.Info) ?Captures {
    const anchored = isAnchored(program);
    var pos: usize = 0;
    while (true) {
        const cand = skipToCandidate(subject, pos, info) orelse break;
        if (info.min_length > 0 and cand.start + info.min_length > subject.len) break;
        @memset(slots, null);
        var eng = Engine{
            .program = program,
            .subject = subject,
            .slots = slots,
            .start_offset = cand.start,
            .limits = limits,
            .copies = undefined,
        };
        slots[0] = cand.start;
        if (eng.matchAt(0, cand.start)) {
            const mstart = slots[0] orelse cand.start;
            const mend = slots[1] orelse eng.end_pos;
            slots[0] = mstart;
            slots[1] = mend;
            return .{ .subject = subject, .slots = slots };
        }
        if (anchored or cand.start >= subject.len) break;
        pos = cand.next;
        if (pos <= cand.start) pos = cand.start + 1;
    }
    return null;
}

fn isAnchored(program: Program) bool {
    if (program.ops.len == 0) return false;
    var i: usize = 0;
    while (i < program.ops.len) : (i += 1) {
        switch (program.ops[i]) {
            .save => continue,
            .bot, .start_match => return true,
            .bol => return !program.flags.multiline,
            else => return false,
        }
    }
    return false;
}

const Candidate = struct {
    start: usize,
    next: usize,
};

fn skipToCandidate(subject: []const u8, pos: usize, info: analyze.Info) ?Candidate {
    if (pos > subject.len) return null;
    if (pos == subject.len) {
        return if (info.min_length == 0) .{ .start = pos, .next = pos + 1 } else null;
    }
    if (info.req_byte) |rb| {
        if (std.mem.findScalarPos(u8, subject, pos, rb)) |at| {
            var start = at;
            if (info.has_start_bits) {
                while (start > pos and bitAt(info.start_bits, subject[start - 1])) start -= 1;
            }
            return .{ .start = start, .next = at + 1 };
        }
        return null;
    }
    if (info.first_byte) |b| {
        var p = pos;
        while (p < subject.len) {
            const idx = if (info.first_byte2) |b2| blk: {
                const a = std.mem.findScalarPos(u8, subject, p, b);
                const c = std.mem.findScalarPos(u8, subject, p, b2);
                if (a == null and c == null) break :blk null;
                break :blk @min(a orelse std.math.maxInt(usize), c orelse std.math.maxInt(usize));
            } else std.mem.findScalarPos(u8, subject, p, b);
            const found = idx orelse return null;
            if (prefixMatches(subject, found, info))
                return .{ .start = found, .next = found + 1 };
            p = found + 1;
        }
        return null;
    }
    if (info.has_start_bits) {
        const found = findStartBit(subject, pos, info.start_bits) orelse return null;
        return .{ .start = found, .next = found + 1 };
    }
    return .{ .start = pos, .next = pos + 1 };
}

fn bitAt(bits: [4]u64, b: u8) bool {
    return (bits[b >> 6] & (@as(u64, 1) << @as(u6, @truncate(b)))) != 0;
}

fn prefixMatches(subject: []const u8, idx: usize, info: analyze.Info) bool {
    if (info.prefix_len < 2) return true;
    if (idx + info.prefix_len > subject.len) return false;
    return std.mem.eql(u8, subject[idx..][0..info.prefix_len], info.prefix[0..info.prefix_len]);
}

fn findStartBit(subject: []const u8, pos: usize, bits: [4]u64) ?usize {
    const nbits = @as(u16, @popCount(bits[0])) + @as(u16, @popCount(bits[1])) +
        @as(u16, @popCount(bits[2])) + @as(u16, @popCount(bits[3]));
    if (nbits == 0) return null;
    if (nbits <= 8) {
        var best: usize = std.math.maxInt(usize);
        var found = false;
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const byte: u8 = @intCast(b);
            if ((bits[byte >> 6] & (@as(u64, 1) << @as(u6, @truncate(byte)))) == 0) continue;
            if (std.mem.findScalarPos(u8, subject, pos, byte)) |idx| {
                if (idx < best) best = idx;
                found = true;
            }
        }
        return if (found) best else null;
    }
    var i = pos;
    while (i + 8 <= subject.len) : (i += 8) {
        inline for (0..8) |k| {
            const byte = subject[i + k];
            if ((bits[byte >> 6] & (@as(u64, 1) << @as(u6, @truncate(byte)))) != 0)
                return i + k;
        }
    }
    while (i < subject.len) : (i += 1) {
        const byte = subject[i];
        if ((bits[byte >> 6] & (@as(u64, 1) << @as(u6, @truncate(byte)))) != 0)
            return i;
    }
    return null;
}

fn advance(subject: []const u8, pos: usize, utf: bool) usize {
    if (pos >= subject.len) return subject.len + 1;
    if (!utf) return pos + 1;
    const n = unicode.nextCodepoint(subject, pos, true) orelse return pos + 1;
    return pos + n.len;
}

const copy_frames = 32;
const copy_slots = 64;
const CopyStack = [copy_frames][copy_slots]?usize;

threadlocal var tls_copies: CopyStack = undefined;

const Choice = struct {
    pc: u32,
    pos: usize,
    copy_at: u8,
};

const Engine = struct {
    program: Program,
    subject: []const u8,
    slots: []?usize,
    start_offset: usize,
    limits: scratch_mod.MatchLimits,
    steps: u32 = 0,
    depth: u32 = 0,
    recursion: u32 = 0,
    end_pos: usize = 0,
    committed: bool = false,
    skip_to: ?usize = null,
    hit_limit: bool = false,
    copies: *CopyStack = undefined,
    copy_depth: u8 = 0,

    fn matchAt(self: *Engine, start_pc: u32, start_pos: usize) bool {
        if (@inComptime()) {
            var ct_copies: CopyStack = undefined;
            self.copies = &ct_copies;
        } else {
            self.copies = &tls_copies;
        }
        self.copy_depth = 0;
        return self.exec(start_pc, @intCast(self.program.ops.len), start_pos, true);
    }

    fn exec(self: *Engine, start_pc: u32, end_pc: u32, start_pos: usize, save_end: bool) bool {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > self.limits.depth_limit) return false;

        var choices: [16]Choice = undefined;
        var nchoice: u8 = 0;
        var pc = start_pc;
        var pos = start_pos;

        dispatch: while (true) {
            self.steps += 1;
            if (self.steps > self.limits.match_limit) {
                self.hit_limit = true;
                return false;
            }
            if (pc >= end_pc) {
                self.end_pos = pos;
                if (save_end and pc >= self.program.ops.len) {
                    if (self.slots.len > 1) self.slots[1] = pos;
                }
                return true;
            }
            const inst = self.program.ops[pc];
            switch (inst) {
                .accept => {
                    if (save_end) {
                        self.end_pos = pos;
                        if (self.slots.len > 1) self.slots[1] = pos;
                    }
                    return true;
                },
                .fail, .prune, .then => {
                    if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                    continue :dispatch;
                },
                .char => |cp| {
                    pos = self.consumeChar(pos, cp, false) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .char_i => |cp| {
                    pos = self.consumeChar(pos, cp, true) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .any => {
                    pos = self.consumeAny(pos, false) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .any_nl => {
                    pos = self.consumeAny(pos, true) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .class => |idx| {
                    pos = self.consumeClass(pos, idx) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .jmp => |t| pc = t,
                .split => |alt| {
                    if (nchoice >= choices.len) return false;
                    _ = self.saveSlots();
                    choices[nchoice] = .{
                        .pc = alt,
                        .pos = pos,
                        .copy_at = self.copy_depth,
                    };
                    nchoice += 1;
                    pc += 1;
                },
                .save => |slot| {
                    if (slot < self.slots.len) self.slots[slot] = pos;
                    pc += 1;
                },
                .bol => {
                    if (!self.isBol(pos)) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .eol => {
                    if (!self.isEol(pos)) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .bot => {
                    if (pos != 0) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .eot => {
                    if (pos != self.subject.len) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .eot_nl => {
                    if (!self.isEotNl(pos)) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .word_boundary => {
                    if (!self.isWordBoundary(pos)) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .not_word_boundary => {
                    if (self.isWordBoundary(pos)) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .start_match => {
                    if (pos != self.start_offset) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc += 1;
                },
                .backref => |g| {
                    pos = self.consumeBackref(pos, g, false) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .backref_i => |g| {
                    pos = self.consumeBackref(pos, g, true) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .quant => |q| {
                    if (q.possessive) {
                        switch (self.possessiveAsciiRun(q, pc + 1, q.body_end, pos)) {
                            .inapplicable => {},
                            .fail => {
                                if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                                continue :dispatch;
                            },
                            .pos => |p| {
                                pos = p;
                                pc = q.body_end;
                                continue :dispatch;
                            },
                        }
                    }
                    if (self.execQuant(q, pc + 1, q.body_end, end_pc, pos, save_end)) return true;
                    if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                    continue :dispatch;
                },
                .look => |l| {
                    const ok = self.execLook(l, pc + 1, pos);
                    if (ok == l.negate) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pc = l.end;
                },
                .atomic => |aend| {
                    if (!self.exec(pc + 1, aend, pos, false)) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pos = self.end_pos;
                    pc = aend;
                },
                .call => |g| {
                    if (self.recursion >= self.limits.recursion_limit or g >= self.program.groups.len) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    const range = self.program.groups[g];
                    self.recursion += 1;
                    const ok = self.exec(range.start, range.end, pos, false);
                    self.recursion -= 1;
                    if (!ok) {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    }
                    pos = self.end_pos;
                    pc += 1;
                },
                .reset_start => {
                    if (self.slots.len > 0) self.slots[0] = pos;
                    pc += 1;
                },
                .newline_seq => {
                    pos = self.consumeNewlineSeq(pos) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .grapheme => {
                    pos = self.consumeGrapheme(pos) orelse {
                        if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                        continue :dispatch;
                    };
                    pc += 1;
                },
                .commit => {
                    self.committed = true;
                    pc += 1;
                },
                .skip => {
                    self.skip_to = pos;
                    if (!self.takeChoice(&choices, &nchoice, &pc, &pos)) return false;
                    continue :dispatch;
                },
                .accept_verb => {
                    if (save_end) {
                        self.end_pos = pos;
                        if (self.slots.len > 1) self.slots[1] = pos;
                    }
                    return true;
                },
                .cond_group => |cg| {
                    const set = self.groupSet(cg.group);
                    pc = if (set) pc + 1 else cg.no_branch;
                },
            }
        }
    }

    fn takeChoice(self: *Engine, choices: []Choice, nchoice: *u8, pc: *u32, pos: *usize) bool {
        if (self.committed) return false;
        if (nchoice.* == 0) return false;
        nchoice.* -= 1;
        const ch = choices[nchoice.*];
        self.rewindTo(ch.copy_at);
        pc.* = ch.pc;
        pos.* = ch.pos;
        if (self.skip_to) |s| {
            if (pos.* < s) return false;
        }
        return true;
    }

    fn rewindTo(self: *Engine, copy_at: u8) void {
        if (copy_at == 0) {
            self.copy_depth = 0;
            return;
        }
        const idx = copy_at - 1;
        const n = @min(self.slots.len, copy_slots);
        @memcpy(self.slots[0..n], self.copies[idx][0..n]);
        self.copy_depth = idx;
    }

    const AsciiRun = union(enum) {
        inapplicable,
        fail,
        pos: usize,
    };

    fn possessiveAsciiRun(
        self: *Engine,
        q: bytecode.Quant,
        body_pc: u32,
        body_end: u32,
        pos: usize,
    ) AsciiRun {
        if (body_end != body_pc + 1) return .inapplicable;
        switch (self.program.ops[body_pc]) {
            .char => |cp| {
                if (cp >= 0x80) return .inapplicable;
                const want: u8 = @intCast(cp);
                var n: u32 = 0;
                var p = pos;
                while (n < q.max and p < self.subject.len and self.subject[p] == want) {
                    p += 1;
                    n += 1;
                }
                if (n < q.min) return .fail;
                return .{ .pos = p };
            },
            .class => |idx| {
                if (idx >= self.program.classes.len) return .inapplicable;
                const class = self.program.classes[idx];
                if (class.negated or class.range_count != 0 or class.prop_count != 0) return .inapplicable;
                var n: u32 = 0;
                var p = pos;
                while (n < q.max and p < self.subject.len) {
                    const b = self.subject[p];
                    if (b >= 0x80 or !class.matches(b)) break;
                    p += 1;
                    n += 1;
                }
                if (n < q.min) return .fail;
                return .{ .pos = p };
            },
            else => return .inapplicable,
        }
    }

    fn execQuant(
        self: *Engine,
        q: bytecode.Quant,
        body_pc: u32,
        body_end: u32,
        rest_end: u32,
        pos: usize,
        save_end: bool,
    ) bool {
        if (q.possessive) {
            switch (self.possessiveAsciiRun(q, body_pc, body_end, pos)) {
                .inapplicable => {},
                .fail => return false,
                .pos => |p| return self.exec(body_end, rest_end, p, save_end),
            }
            var n: u32 = 0;
            var p = pos;
            while (n < q.max) {
                const saved = p;
                if (!self.exec(body_pc, body_end, p, false)) break;
                p = self.end_pos;
                n += 1;
                if (p == saved) {
                    if (n < q.min) {
                        // count empties toward min
                        n = q.min;
                    }
                    break;
                }
            }
            if (n < q.min) return false;
            return self.exec(body_end, rest_end, p, save_end);
        }
        if (q.greedy) {
            return self.quantGreedy(q, body_pc, body_end, rest_end, pos, 0, save_end);
        }
        return self.quantLazy(q, body_pc, body_end, rest_end, pos, 0, save_end);
    }

    fn quantGreedy(
        self: *Engine,
        q: bytecode.Quant,
        body_pc: u32,
        body_end: u32,
        rest_end: u32,
        pos: usize,
        count: u32,
        save_end: bool,
    ) bool {
        if (count < q.max) {
            const saved_slots = self.saveSlots();
            if (self.exec(body_pc, body_end, pos, false)) {
                const np = self.end_pos;
                if (np > pos) {
                    if (self.quantGreedy(q, body_pc, body_end, rest_end, np, count + 1, save_end))
                        return true;
                    self.restoreSlots(saved_slots);
                } else {
                    const next_count = @max(count + 1, q.min);
                    if (next_count >= q.min and self.exec(body_end, rest_end, pos, save_end))
                        return true;
                    self.restoreSlots(saved_slots);
                }
            } else {
                self.restoreSlots(saved_slots);
            }
        }
        if (count >= q.min) return self.exec(body_end, rest_end, pos, save_end);
        return false;
    }

    fn quantLazy(
        self: *Engine,
        q: bytecode.Quant,
        body_pc: u32,
        body_end: u32,
        rest_end: u32,
        pos: usize,
        count: u32,
        save_end: bool,
    ) bool {
        if (count >= q.min) {
            const saved_slots = self.saveSlots();
            if (self.exec(body_end, rest_end, pos, save_end)) return true;
            self.restoreSlots(saved_slots);
        }
        if (count < q.max) {
            const saved_slots = self.saveSlots();
            if (self.exec(body_pc, body_end, pos, false)) {
                const np = self.end_pos;
                if (np == pos) {
                    if (count + 1 >= q.min) {
                        const ok = self.exec(body_end, rest_end, pos, save_end);
                        if (!ok) self.restoreSlots(saved_slots);
                        return ok;
                    }
                } else if (self.quantLazy(q, body_pc, body_end, rest_end, np, count + 1, save_end)) {
                    return true;
                }
            }
            self.restoreSlots(saved_slots);
        }
        return false;
    }

    fn execLook(self: *Engine, look: bytecode.Look, body_pc: u32, pos: usize) bool {
        const saved_slots = self.saveSlots();
        if (!look.behind) {
            const ok = self.exec(body_pc, look.end, pos, false);
            if (!ok or look.negate) self.restoreSlots(saved_slots) else self.popCopy(saved_slots);
            return ok;
        }
        var start: usize = 0;
        while (start <= pos) {
            if (self.exec(body_pc, look.end, start, false) and self.end_pos == pos) {
                if (look.negate) self.restoreSlots(saved_slots) else self.popCopy(saved_slots);
                return true;
            }
            self.restoreSlots(saved_slots);
            _ = self.pushCopy();
            if (start == pos) break;
            start = advance(self.subject, start, self.program.flags.utf);
            if (start > pos) break;
        }
        self.restoreSlots(saved_slots);
        return false;
    }

    fn consumeChar(self: *Engine, pos: usize, want: u21, caseless: bool) ?usize {
        if (pos >= self.subject.len) return null;
        if (!caseless and want < 0x80) {
            if (self.subject[pos] == want) return pos + 1;
            if (self.subject[pos] < 0x80) return null;
        }
        const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse return null;
        if (caseless) {
            if (!unicode.equalFold(n.cp, want, self.program.flags.ucp or self.program.flags.utf))
                return null;
        } else if (n.cp != want) return null;
        return pos + n.len;
    }

    fn consumeAny(self: *Engine, pos: usize, dotall: bool) ?usize {
        const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse return null;
        if (!dotall and unicode.isAsciiNewline(n.cp)) return null;
        return pos + n.len;
    }

    fn consumeClass(self: *Engine, pos: usize, idx: u16) ?usize {
        if (pos >= self.subject.len) return null;
        if (idx >= self.program.classes.len) return null;
        const class = self.program.classes[idx];
        const b = self.subject[pos];
        if (b < 0x80) {
            if (!class.matches(b)) return null;
            return pos + 1;
        }
        const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse return null;
        if (!class.matches(n.cp)) return null;
        return pos + n.len;
    }

    fn consumeBackref(self: *Engine, pos: usize, group: u16, caseless: bool) ?usize {
        const g = self.groupSlice(group) orelse return null;
        if (pos + g.len > self.subject.len) return null;
        if (!caseless) {
            if (!std.mem.eql(u8, self.subject[pos..][0..g.len], g)) return null;
            return pos + g.len;
        }
        var a = pos;
        var b: usize = 0;
        while (b < g.len) {
            const na = unicode.nextCodepoint(self.subject, a, self.program.flags.utf) orelse return null;
            const nb = unicode.nextCodepoint(g, b, self.program.flags.utf) orelse return null;
            if (!unicode.equalFold(na.cp, nb.cp, self.program.flags.ucp or true)) return null;
            a += na.len;
            b += nb.len;
        }
        return a;
    }

    fn consumeNewlineSeq(self: *Engine, pos: usize) ?usize {
        if (pos >= self.subject.len) return null;
        if (unicode.isCrlf(self.subject, pos)) return pos + 2;
        const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse return null;
        if (!unicode.isNewline(n.cp)) return null;
        return pos + n.len;
    }

    fn consumeGrapheme(self: *Engine, pos: usize) ?usize {
        const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse return null;
        var p = pos + n.len;
        while (p < self.subject.len) {
            const m = unicode.nextCodepoint(self.subject, p, self.program.flags.utf) orelse break;
            if (unicode.generalCategory(m.cp) != .Mn and unicode.generalCategory(m.cp) != .Mc and
                unicode.generalCategory(m.cp) != .Me)
                break;
            p += m.len;
        }
        return p;
    }

    fn isBol(self: *Engine, pos: usize) bool {
        if (pos == 0) return true;
        if (!self.program.flags.multiline) return false;
        return pos > 0 and unicode.isAsciiNewline(self.subject[pos - 1]);
    }

    fn isEol(self: *Engine, pos: usize) bool {
        if (pos == self.subject.len) return true;
        if (self.program.flags.multiline and unicode.isAsciiNewline(self.subject[pos])) return true;
        if (!self.program.flags.multiline) {
            // $ matches before a final newline
            if (pos + 1 == self.subject.len and self.subject[pos] == '\n') return true;
            if (pos + 2 == self.subject.len and unicode.isCrlf(self.subject, pos)) return true;
        }
        return false;
    }

    fn isEotNl(self: *Engine, pos: usize) bool {
        if (pos == self.subject.len) return true;
        if (pos + 1 == self.subject.len and self.subject[pos] == '\n') return true;
        if (pos + 2 == self.subject.len and unicode.isCrlf(self.subject, pos)) return true;
        return false;
    }

    fn isWordBoundary(self: *Engine, pos: usize) bool {
        const ucp = self.program.flags.ucp;
        if (!ucp) {
            const prev_ascii = pos == 0 or self.subject[pos - 1] < 0x80;
            const next_ascii = pos >= self.subject.len or self.subject[pos] < 0x80;
            if (prev_ascii and next_ascii) {
                const prev = pos > 0 and unicode.isAsciiWord(self.subject[pos - 1]);
                const next = pos < self.subject.len and unicode.isAsciiWord(self.subject[pos]);
                return prev != next;
            }
        }
        const prev = if (pos == 0) false else blk: {
            const cp = prevCodepoint(self.subject, pos, self.program.flags.utf);
            break :blk unicode.isWord(cp, ucp);
        };
        const next = if (pos >= self.subject.len) false else blk: {
            const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse break :blk false;
            break :blk unicode.isWord(n.cp, ucp);
        };
        return prev != next;
    }

    fn groupSet(self: *Engine, group: u16) bool {
        const i = @as(usize, group) * 2;
        if (i + 1 >= self.slots.len) return false;
        return self.slots[i] != null and self.slots[i + 1] != null;
    }

    fn groupSlice(self: *Engine, group: u16) ?[]const u8 {
        const i = @as(usize, group) * 2;
        if (i + 1 >= self.slots.len) return null;
        const a = self.slots[i] orelse return null;
        const b = self.slots[i + 1] orelse return null;
        if (a > b or b > self.subject.len) return null;
        return self.subject[a..b];
    }

    fn saveSlots(self: *Engine) []?usize {
        // Use a stack-local copy when small; otherwise leak into a side buffer.
        // Engine is single-threaded recursive, so a scratch copy array is enough
        // if we allocate from a fixed local via duplicating on the caller's stack
        // through a helper that uses a small buffer.
        return self.copySlots();
    }

    fn copySlots(self: *Engine) []?usize {
        // Recursion uses a thread-local style arena on the Engine: we store copies
        // in a linked list would be heavy. Instead we copy into a temporary allocated
        // from a bump inside Engine — but we have no allocator.
        // Use a bounded inline buffer on Engine.
        return self.pushCopy();
    }

    fn restoreSlots(self: *Engine, saved: []?usize) void {
        if (saved.len == 0) return;
        const n = @min(saved.len, self.slots.len);
        @memcpy(self.slots[0..n], saved[0..n]);
        self.popCopy(saved);
    }

    fn pushCopy(self: *Engine) []?usize {
        if (self.copy_depth >= copy_frames) return &.{};
        const n = @min(self.slots.len, copy_slots);
        const d = self.copy_depth;
        self.copy_depth += 1;
        @memcpy(self.copies[d][0..n], self.slots[0..n]);
        return self.copies[d][0..n];
    }

    fn popCopy(self: *Engine, saved: []?usize) void {
        _ = saved;
        if (self.copy_depth > 0) self.copy_depth -= 1;
    }
};

fn prevCodepoint(subject: []const u8, pos: usize, utf: bool) u21 {
    if (pos == 0) return 0;
    if (!utf) return subject[pos - 1];
    var i = pos - 1;
    while (i > 0 and subject[i] & 0xC0 == 0x80) i -= 1;
    const n = unicode.nextCodepoint(subject, i, true) orelse return subject[pos - 1];
    return n.cp;
}
