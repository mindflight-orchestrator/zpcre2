const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const options = @import("options.zig");
const parse_mod = @import("parse.zig");
const unicode = @import("unicode.zig");

const Inst = bytecode.Inst;
const Node = ast.Node;
const Parser = parse_mod.Parser;

pub const Emitter = struct {
    ops: [ast.max_ops]Inst = undefined,
    n_ops: u32 = 0,
    classes: [ast.max_classes]bytecode.Class = undefined,
    n_classes: u16 = 0,
    groups: [512]bytecode.GroupRange = undefined,
    n_groups: u32 = 0,
    flags: options.Flags,
    parser: *const Parser,

    pub fn init(parser: *const Parser) Emitter {
        var e = Emitter{
            .flags = parser.flags,
            .parser = parser,
            .n_groups = parser.captureCount() + 1,
        };
        var i: u32 = 0;
        while (i < e.n_groups) : (i += 1) {
            e.groups[i] = .{ .start = 0, .end = 0 };
        }
        return e;
    }

    pub fn lower(self: *Emitter, root: u32) options.Error!void {
        _ = try self.emit(.{ .save = 0 });
        const body_start = self.pc();
        try self.lowerNode(root);
        const body_end = self.pc();
        _ = try self.emit(.{ .save = 1 });
        _ = try self.emit(.accept);
        self.groups[0] = .{ .start = body_start, .end = body_end };
    }

    pub fn program(self: *const Emitter) bytecode.Program {
        return .{
            .ops = self.ops[0..self.n_ops],
            .classes = self.classes[0..self.n_classes],
            .groups = self.groups[0..self.n_groups],
            .names = self.parser.names[0..self.parser.n_names],
            .capture_count = self.parser.captureCount(),
            .flags = self.flags,
        };
    }

    fn emit(self: *Emitter, inst: Inst) options.Error!u32 {
        if (self.n_ops >= ast.max_ops) return error.PatternTooLarge;
        const index = self.n_ops;
        self.ops[index] = inst;
        self.n_ops += 1;
        return index;
    }

    fn pc(self: *const Emitter) u32 {
        return self.n_ops;
    }

    fn lowerNode(self: *Emitter, idx: u32) options.Error!void {
        const node = self.parser.nodes[idx];
        switch (node.kind) {
            .empty => {},
            .char => |cp| {
                if (self.flags.caseless) {
                    _ = try self.emit(.{ .char_i = cp });
                } else {
                    _ = try self.emit(.{ .char = cp });
                }
            },
            .class => |cl| {
                var class = self.parser.classes[cl];
                class.utf = self.flags.utf;
                if (self.n_classes >= ast.max_classes) return error.PatternTooLarge;
                const cidx = self.n_classes;
                self.classes[cidx] = class;
                self.n_classes += 1;
                _ = try self.emit(.{ .class = cidx });
            },
            .dot => {
                if (self.flags.dotall) {
                    _ = try self.emit(.any_nl);
                } else {
                    _ = try self.emit(.any);
                }
            },
            .concat => |list| {
                const kids = self.parser.children(list);
                for (kids, 0..) |n, ki| {
                    const followed: ?u32 = if (ki + 1 < kids.len) kids[ki + 1] else null;
                    if (self.parser.nodes[n].kind == .repeat) {
                        try self.lowerRepeat(n, followed);
                    } else {
                        try self.lowerNode(n);
                    }
                }
            },
            .alt => |list| try self.lowerAlt(list),
            .group => |g| {
                const start = self.pc();
                if (g.capture) |cap| {
                    const slot: u16 = @intCast(cap * 2);
                    _ = try self.emit(.{ .save = slot });
                    try self.lowerNode(g.body);
                    _ = try self.emit(.{ .save = slot + 1 });
                    if (cap < self.n_groups) {
                        self.groups[cap] = .{ .start = start, .end = self.pc() };
                    }
                } else {
                    try self.lowerNode(g.body);
                }
            },
            .repeat => try self.lowerRepeat(idx, null),
            .assert => |a| {
                _ = try self.emit(switch (a) {
                    .bol => .bol,
                    .eol => .eol,
                    .bot => .bot,
                    .eot => .eot,
                    .eot_nl => .eot_nl,
                    .word_boundary => .word_boundary,
                    .not_word_boundary => .not_word_boundary,
                    .start_match => .start_match,
                });
            },
            .backref => |b| {
                if (b.caseless or self.flags.caseless) {
                    _ = try self.emit(.{ .backref_i = @intCast(b.index) });
                } else {
                    _ = try self.emit(.{ .backref = @intCast(b.index) });
                }
            },
            .look => |l| {
                const lpc = try self.emit(.{ .look = .{
                    .negate = l.negate,
                    .behind = l.behind,
                    .end = 0,
                } });
                try self.lowerNode(l.body);
                self.ops[lpc].look.end = self.pc();
            },
            .atomic => |n| {
                const apc = try self.emit(.{ .atomic = 0 });
                try self.lowerNode(n);
                self.ops[apc].atomic = self.pc();
            },
            .cond => |c| try self.lowerCond(c),
            .call => |c| _ = try self.emit(.{ .call = @intCast(c.group) }),
            .control => |ctl| {
                _ = try self.emit(switch (ctl) {
                    .accept => .accept_verb,
                    .fail => .fail,
                    .commit => .commit,
                    .prune => .prune,
                    .skip => .skip,
                    .then => .then,
                });
            },
            .reset_start => _ = try self.emit(.reset_start),
            .newline_seq => _ = try self.emit(.newline_seq),
            .grapheme => _ = try self.emit(.grapheme),
            .opt_set => |o| {
                const saved = self.flags;
                apply(self, o.set, o.unset);
                if (o.body) |b| {
                    try self.lowerNode(b);
                    self.flags = saved;
                }
            },
        }
    }

    fn lowerRepeat(self: *Emitter, idx: u32, followed: ?u32) options.Error!void {
        var r = self.parser.nodes[idx].kind.repeat;
        if (!r.possessive and followed != null and atomsDisjoint(self.parser, r.inner, followed.?)) {
            r.possessive = true;
        }
        const qpc = try self.emit(.{ .quant = .{
            .min = r.min,
            .max = r.max,
            .greedy = r.greedy,
            .possessive = r.possessive,
            .body_end = 0,
        } });
        try self.lowerNode(r.inner);
        self.ops[qpc].quant.body_end = self.pc();
    }

    fn lowerAlt(self: *Emitter, list: ast.List) options.Error!void {
        const items = self.parser.children(list);
        if (items.len == 0) return;
        if (items.len == 1) return self.lowerNode(items[0]);

        var jumps: [64]u32 = undefined;
        var n_jumps: u32 = 0;
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const last = i + 1 == items.len;
            var split_pc: ?u32 = null;
            if (!last) {
                split_pc = try self.emit(.{ .split = 0 });
            }
            try self.lowerNode(items[i]);
            if (!last) {
                if (n_jumps >= jumps.len) return error.PatternTooLarge;
                jumps[n_jumps] = try self.emit(.{ .jmp = 0 });
                n_jumps += 1;
                self.ops[split_pc.?].split = self.pc();
            }
        }
        const end = self.pc();
        var j: u32 = 0;
        while (j < n_jumps) : (j += 1) {
            self.ops[jumps[j]].jmp = end;
        }
    }

    fn lowerCond(self: *Emitter, c: ast.Cond) options.Error!void {
        if (c.look) |look_body| {
            const split_pc = try self.emit(.{ .split = 0 });
            const lpc = try self.emit(.{ .look = .{
                .negate = c.look_negate,
                .behind = false,
                .end = 0,
            } });
            try self.lowerNode(look_body);
            self.ops[lpc].look.end = self.pc();
            try self.lowerNode(c.yes);
            const jmp_pc = try self.emit(.{ .jmp = 0 });
            self.ops[split_pc].split = self.pc();
            try self.lowerNode(c.no);
            self.ops[jmp_pc].jmp = self.pc();
            return;
        }
        const group: u16 = @intCast(c.group orelse 0);
        const cpc = try self.emit(.{ .cond_group = .{
            .group = group,
            .no_branch = 0,
            .end = 0,
        } });
        try self.lowerNode(c.yes);
        const jmp_pc = try self.emit(.{ .jmp = 0 });
        self.ops[cpc].cond_group.no_branch = self.pc();
        try self.lowerNode(c.no);
        const end = self.pc();
        self.ops[cpc].cond_group.end = end;
        self.ops[jmp_pc].jmp = end;
    }
};

fn atomsDisjoint(parser: *const Parser, inner: u32, next: u32) bool {
    const a = parser.nodes[firstAtom(parser, inner)].kind;
    const b = parser.nodes[firstAtom(parser, next)].kind;
    const caseless = parser.flags.caseless;
    return switch (a) {
        .char => |ca| switch (b) {
            .char => |cb| if (caseless)
                unicode.asciiFold(ca) != unicode.asciiFold(cb)
            else
                ca != cb,
            .class => |ci| !parser.classes[ci].matches(ca),
            else => false,
        },
        .class => |ci| switch (b) {
            .char => |cb| !parser.classes[ci].matches(cb),
            .class => |cj| classesDisjoint(parser.classes[ci], parser.classes[cj]),
            else => false,
        },
        else => false,
    };
}

fn firstAtom(parser: *const Parser, idx: u32) u32 {
    var i = idx;
    var guard: u8 = 0;
    while (guard < 16) : (guard += 1) {
        switch (parser.nodes[i].kind) {
            .group => |g| i = g.body,
            .concat => |list| {
                const kids = parser.children(list);
                if (kids.len == 0) return i;
                i = kids[0];
            },
            .opt_set => |o| {
                if (o.body) |body| i = body else return i;
            },
            else => return i,
        }
    }
    return i;
}

fn classesDisjoint(a: bytecode.Class, b: bytecode.Class) bool {
    if (a.negated or b.negated) return false;
    if (a.prop_count > 0 or b.prop_count > 0) return false;
    return (a.bits[0] & b.bits[0]) == 0 and
        (a.bits[1] & b.bits[1]) == 0 and
        (a.bits[2] & b.bits[2]) == 0 and
        (a.bits[3] & b.bits[3]) == 0;
}

fn apply(e: *Emitter, set: options.Flags, unset: options.Flags) void {
    if (set.caseless) e.flags.caseless = true;
    if (unset.caseless) e.flags.caseless = false;
    if (set.multiline) e.flags.multiline = true;
    if (unset.multiline) e.flags.multiline = false;
    if (set.dotall) e.flags.dotall = true;
    if (unset.dotall) e.flags.dotall = false;
    if (set.extended) e.flags.extended = true;
    if (unset.extended) e.flags.extended = false;
    if (set.ungreedy) e.flags.ungreedy = true;
    if (unset.ungreedy) e.flags.ungreedy = false;
    if (set.ucp) e.flags.ucp = true;
    if (unset.ucp) e.flags.ucp = false;
}
