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

pub fn find(program: Program, subject: []const u8, slots: []?usize, limits: scratch_mod.MatchLimits) ?Match {
    var caps = findCaptures(program, subject, slots, limits) orelse return null;
    return caps.span();
}

pub fn isMatch(program: Program, subject: []const u8, slots: []?usize, limits: scratch_mod.MatchLimits) bool {
    return find(program, subject, slots, limits) != null;
}

pub fn findCaptures(program: Program, subject: []const u8, slots: []?usize, limits: scratch_mod.MatchLimits) ?Captures {
    const info = analyze.analyze(program);
    var pos: usize = 0;
    const anchored = program.flags.utf and false;
    _ = anchored;
    while (true) {
        if (program.flags.utf == false or true) {
            if (!tryStart(program, subject, pos, info)) {
                if (pos >= subject.len) break;
                pos = advance(subject, pos, program.flags.utf);
                continue;
            }
        }
        @memset(slots, null);
        var eng = Engine{
            .program = program,
            .subject = subject,
            .slots = slots,
            .start_offset = pos,
            .limits = limits,
        };
        slots[0] = pos;
        if (eng.matchAt(0, pos)) {
            const start = slots[0] orelse pos;
            const end = slots[1] orelse eng.end_pos;
            slots[0] = start;
            slots[1] = end;
            return .{ .subject = subject, .slots = slots };
        }
        if (pos >= subject.len) break;
        if (isAnchored(program)) break;
        pos = advance(subject, pos, program.flags.utf);
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

fn tryStart(program: Program, subject: []const u8, pos: usize, info: analyze.Info) bool {
    if (info.min_length > 0 and pos + info.min_length > subject.len) {
        // still allow empty-width? min_length>0 means no
        if (pos > subject.len) return false;
        if (pos == subject.len and info.min_length > 0) return false;
    }
    if (info.first_byte) |b| {
        if (pos >= subject.len) return false;
        if (program.flags.caseless) {
            return unicode.asciiFold(subject[pos]) == unicode.asciiFold(b);
        }
        return subject[pos] == b;
    }
    return true;
}

fn advance(subject: []const u8, pos: usize, utf: bool) usize {
    if (pos >= subject.len) return subject.len + 1;
    if (!utf) return pos + 1;
    const n = unicode.nextCodepoint(subject, pos, true) orelse return pos + 1;
    return pos + n.len;
}

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
    copy_stack: [32][64]?usize = undefined,
    copy_depth: u8 = 0,

    fn matchAt(self: *Engine, start_pc: u32, start_pos: usize) bool {
        return self.exec(start_pc, @intCast(self.program.ops.len), start_pos, true);
    }

    fn exec(self: *Engine, start_pc: u32, end_pc: u32, start_pos: usize, save_end: bool) bool {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > self.limits.depth_limit) return false;

        var pc = start_pc;
        var pos = start_pos;
        while (pc < end_pc) {
            self.steps += 1;
            if (self.steps > self.limits.match_limit) {
                self.hit_limit = true;
                return false;
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
                .fail => return false,
                .char => |cp| {
                    const n = self.consumeChar(pos, cp, false) orelse return false;
                    pos = n;
                    pc += 1;
                },
                .char_i => |cp| {
                    const n = self.consumeChar(pos, cp, true) orelse return false;
                    pos = n;
                    pc += 1;
                },
                .any => {
                    const n = self.consumeAny(pos, false) orelse return false;
                    pos = n;
                    pc += 1;
                },
                .any_nl => {
                    const n = self.consumeAny(pos, true) orelse return false;
                    pos = n;
                    pc += 1;
                },
                .class => |idx| {
                    const n = self.consumeClass(pos, idx) orelse return false;
                    pos = n;
                    pc += 1;
                },
                .jmp => |t| pc = t,
                .split => |alt| {
                    const saved = self.saveSlots();
                    if (self.exec(pc + 1, end_pc, pos, save_end)) return true;
                    if (self.committed) return false;
                    self.restoreSlots(saved);
                    if (self.skip_to) |s| {
                        if (pos < s) return false;
                    }
                    pc = alt;
                },
                .save => |slot| {
                    if (slot < self.slots.len) self.slots[slot] = pos;
                    pc += 1;
                },
                .bol => {
                    if (!self.isBol(pos)) return false;
                    pc += 1;
                },
                .eol => {
                    if (!self.isEol(pos)) return false;
                    pc += 1;
                },
                .bot => {
                    if (pos != 0) return false;
                    pc += 1;
                },
                .eot => {
                    if (pos != self.subject.len) return false;
                    pc += 1;
                },
                .eot_nl => {
                    if (!self.isEotNl(pos)) return false;
                    pc += 1;
                },
                .word_boundary => {
                    if (!self.isWordBoundary(pos)) return false;
                    pc += 1;
                },
                .not_word_boundary => {
                    if (self.isWordBoundary(pos)) return false;
                    pc += 1;
                },
                .start_match => {
                    if (pos != self.start_offset) return false;
                    pc += 1;
                },
                .backref => |g| {
                    pos = self.consumeBackref(pos, g, false) orelse return false;
                    pc += 1;
                },
                .backref_i => |g| {
                    pos = self.consumeBackref(pos, g, true) orelse return false;
                    pc += 1;
                },
                .quant => |q| {
                    return self.execQuant(q, pc + 1, q.body_end, end_pc, pos, save_end);
                },
                .look => |l| {
                    const ok = self.execLook(l, pc + 1, pos);
                    if (ok == l.negate) return false;
                    pc = l.end;
                },
                .atomic => |aend| {
                    if (!self.exec(pc + 1, aend, pos, false)) return false;
                    pos = self.end_pos;
                    pc = aend;
                },
                .call => |g| {
                    if (self.recursion >= self.limits.recursion_limit) return false;
                    if (g >= self.program.groups.len) return false;
                    const range = self.program.groups[g];
                    self.recursion += 1;
                    const ok = self.exec(range.start, range.end, pos, false);
                    self.recursion -= 1;
                    if (!ok) return false;
                    pos = self.end_pos;
                    pc += 1;
                },
                .reset_start => {
                    if (self.slots.len > 0) self.slots[0] = pos;
                    pc += 1;
                },
                .newline_seq => {
                    pos = self.consumeNewlineSeq(pos) orelse return false;
                    pc += 1;
                },
                .grapheme => {
                    pos = self.consumeGrapheme(pos) orelse return false;
                    pc += 1;
                },
                .commit => {
                    self.committed = true;
                    pc += 1;
                },
                .prune => return false,
                .skip => {
                    self.skip_to = pos;
                    return false;
                },
                .then => return false,
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
        self.end_pos = pos;
        if (save_end and pc >= self.program.ops.len) {
            if (self.slots.len > 1) self.slots[1] = pos;
        }
        return true;
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
        const n = unicode.nextCodepoint(self.subject, pos, self.program.flags.utf) orelse return null;
        if (idx >= self.program.classes.len) return null;
        if (!self.program.classes[idx].matches(n.cp)) return null;
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
        if (self.copy_depth >= self.copy_stack.len) return &.{};
        const n = @min(self.slots.len, 64);
        const d = self.copy_depth;
        self.copy_depth += 1;
        @memcpy(self.copy_stack[d][0..n], self.slots[0..n]);
        return self.copy_stack[d][0..n];
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
