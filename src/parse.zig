const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const options = @import("options.zig");
const unicode = @import("unicode.zig");

const Node = ast.Node;
const Flags = options.Flags;
const Class = bytecode.Class;

pub const Parser = struct {
    src: []const u8,
    i: usize = 0,
    flags: Flags,
    no_auto_capture: bool,
    capture_next: u32 = 1,
    nesting: u32 = 0,
    diag: *options.Diagnostics,
    anchored: bool,
    in_class: bool = false,
    nodes: [ast.max_nodes]Node = undefined,
    n_nodes: u32 = 0,
    extras: [ast.max_extras]u32 = undefined,
    n_extras: u32 = 0,
    classes: [ast.max_classes]Class = undefined,
    n_classes: u16 = 0,
    names: [ast.max_names]bytecode.NameEntry = undefined,
    n_names: u32 = 0,

    pub fn init(pattern: []const u8, opts: options.Options, diag: *options.Diagnostics) options.Error!Parser {
        if (pattern.len > options.max_pattern_len) {
            diag.* = .{ .offset = 0, .message = "pattern too large" };
            return error.PatternTooLarge;
        }
        return .{
            .src = pattern,
            .flags = Flags.fromOptions(opts),
            .no_auto_capture = opts.no_auto_capture,
            .diag = diag,
            .anchored = opts.anchored,
        };
    }

    pub fn node(self: *const Parser, idx: u32) Node {
        return self.nodes[idx];
    }

    pub fn children(self: *const Parser, list: ast.List) []const u32 {
        return self.extras[list.start..][0..list.len];
    }

    fn fail(self: *Parser, message: []const u8) options.Error {
        self.diag.* = .{ .offset = self.i, .message = message };
        return error.InvalidPattern;
    }

    fn unsupported(self: *Parser, message: []const u8) options.Error {
        self.diag.* = .{ .offset = self.i, .message = message };
        return error.UnsupportedSyntax;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    fn peekAt(self: *Parser, off: usize) ?u8 {
        const j = self.i + off;
        if (j >= self.src.len) return null;
        return self.src[j];
    }

    fn bump(self: *Parser) void {
        if (self.i < self.src.len) self.i += 1;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() == c) {
            self.bump();
            return true;
        }
        return false;
    }

    fn skipExtended(self: *Parser) void {
        if (!self.flags.extended or self.in_class) return;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
                self.bump();
                continue;
            }
            if (c == '#') {
                self.bump();
                while (self.i < self.src.len and self.src[self.i] != '\n') self.bump();
                continue;
            }
            break;
        }
    }

    pub fn parse(self: *Parser) options.Error!u32 {
        const root = try self.parsePattern();
        self.resolveForwardBackrefs(root);
        return root;
    }

    pub fn captureCount(self: *const Parser) u32 {
        return if (self.capture_next == 0) 0 else self.capture_next - 1;
    }

    fn newNode(self: *Parser, loc: usize, kind: Node.Kind) options.Error!u32 {
        if (self.n_nodes >= ast.max_nodes) return error.PatternTooLarge;
        const idx = self.n_nodes;
        self.nodes[idx] = .{ .loc = loc, .kind = kind };
        self.n_nodes += 1;
        return idx;
    }

    fn pushExtra(self: *Parser, idx: u32) options.Error!void {
        if (self.n_extras >= ast.max_extras) return error.PatternTooLarge;
        self.extras[self.n_extras] = idx;
        self.n_extras += 1;
    }

    fn addClass(self: *Parser, class: Class) options.Error!u16 {
        if (self.n_classes >= ast.max_classes) return error.PatternTooLarge;
        const idx = self.n_classes;
        self.classes[idx] = class;
        self.n_classes += 1;
        return idx;
    }

    fn addName(self: *Parser, index: u32, name: []const u8) options.Error!void {
        if (self.n_names >= ast.max_names) return error.TooManyCaptures;
        self.names[self.n_names] = .{ .index = index, .name = name };
        self.n_names += 1;
    }

    fn parsePattern(self: *Parser) options.Error!u32 {
        try self.consumeLeadingVerbs();
        const loc = self.i;
        const expr = try self.parseAlt();
        self.skipExtended();
        if (self.i != self.src.len) return self.fail("unparsed trailing input");
        _ = loc;
        return expr;
    }

    fn consumeLeadingVerbs(self: *Parser) options.Error!void {
        while (self.i + 2 < self.src.len and self.src[self.i] == '(' and self.src[self.i + 1] == '*') {
            const start = self.i;
            self.i += 2;
            const name_start = self.i;
            while (self.i < self.src.len and self.src[self.i] != ')' and self.src[self.i] != ':') self.i += 1;
            const name = self.src[name_start..self.i];
            if (self.eat(':')) {
                while (self.i < self.src.len and self.src[self.i] != ')') self.i += 1;
            }
            if (!self.eat(')')) return self.fail("unclosed (*verb)");
            if (std.ascii.eqlIgnoreCase(name, "UTF") or std.ascii.eqlIgnoreCase(name, "UTF8")) {
                self.flags.utf = true;
            } else if (std.ascii.eqlIgnoreCase(name, "UCP")) {
                self.flags.ucp = true;
            } else if (std.ascii.eqlIgnoreCase(name, "NO_AUTO_CAPTURE")) {
                self.no_auto_capture = true;
            } else if (std.ascii.eqlIgnoreCase(name, "CASELESS")) {
                self.flags.caseless = true;
            } else if (std.ascii.eqlIgnoreCase(name, "DOTALL") or std.ascii.eqlIgnoreCase(name, "s")) {
                self.flags.dotall = true;
            } else if (std.ascii.eqlIgnoreCase(name, "MULTILINE") or std.ascii.eqlIgnoreCase(name, "m")) {
                self.flags.multiline = true;
            } else if (std.ascii.eqlIgnoreCase(name, "EXTENDED") or std.ascii.eqlIgnoreCase(name, "x")) {
                self.flags.extended = true;
            } else if (std.ascii.eqlIgnoreCase(name, "UNGREEDY")) {
                self.flags.ungreedy = true;
            } else if (std.ascii.eqlIgnoreCase(name, "CRLF") or std.ascii.eqlIgnoreCase(name, "CR") or
                std.ascii.eqlIgnoreCase(name, "LF") or std.ascii.eqlIgnoreCase(name, "ANYCRLF") or
                std.ascii.eqlIgnoreCase(name, "ANY") or std.ascii.eqlIgnoreCase(name, "NUL"))
            {
                // newline convention recorded as default LF-family; ANY/CRLF still match \n/\r
            } else if (std.ascii.eqlIgnoreCase(name, "LIMIT_MATCH") or
                std.ascii.eqlIgnoreCase(name, "LIMIT_DEPTH") or
                std.ascii.eqlIgnoreCase(name, "LIMIT_HEAP"))
            {
                // limits are accepted and ignored; matching uses MatchLimits instead
            } else {
                self.i = start;
                break;
            }
        }
    }

    fn parseAlt(self: *Parser) options.Error!u32 {
        const loc = self.i;
        var buf: [64]u32 = undefined;
        var count: u32 = 0;
        buf[0] = try self.parseConcat();
        count = 1;
        while (true) {
            self.skipExtended();
            if (!self.eat('|')) break;
            if (count >= buf.len) return error.PatternTooLarge;
            buf[count] = try self.parseConcat();
            count += 1;
        }
        if (count == 1) return buf[0];
        const start = self.n_extras;
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.pushExtra(buf[i]);
        return self.newNode(loc, .{ .alt = .{ .start = start, .len = count } });
    }

    fn parseConcat(self: *Parser) options.Error!u32 {
        const loc = self.i;
        var buf: [64]u32 = undefined;
        var count: u32 = 0;
        while (true) {
            self.skipExtended();
            const c = self.peek() orelse break;
            if (c == '|' or c == ')') break;
            if (count >= buf.len) return error.PatternTooLarge;
            buf[count] = try self.parseRepeat();
            count += 1;
        }
        if (count == 0) return self.newNode(loc, .empty);
        if (count == 1) return buf[0];
        const start = self.n_extras;
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.pushExtra(buf[i]);
        return self.newNode(loc, .{ .concat = .{ .start = start, .len = count } });
    }

    fn parseRepeat(self: *Parser) options.Error!u32 {
        const loc = self.i;
        const atom = try self.parseAtom();
        self.skipExtended();
        const q = self.peek() orelse return atom;
        if (q != '*' and q != '+' and q != '?' and q != '{') return atom;

        var min: u32 = 0;
        var max: u32 = 0;
        if (self.eat('*')) {
            min = 0;
            max = options.unbounded;
        } else if (self.eat('+')) {
            min = 1;
            max = options.unbounded;
        } else if (self.eat('?')) {
            min = 0;
            max = 1;
        } else if (self.eat('{')) {
            const parsed = try self.parseBraceQuant();
            min = parsed.min;
            max = parsed.max;
        }

        var greedy = !self.flags.ungreedy;
        var possessive = false;
        if (self.eat('?')) {
            greedy = false;
        } else if (self.eat('+')) {
            possessive = true;
        }
        if (self.flags.ungreedy and !possessive) {
            // already applied unless ? or + flipped it; `{n,m}?` handled above
        }

        return self.newNode(loc, .{ .repeat = .{
            .inner = atom,
            .min = min,
            .max = max,
            .greedy = greedy,
            .possessive = possessive,
        } });
    }

    fn parseBraceQuant(self: *Parser) options.Error!struct { min: u32, max: u32 } {
        const min = try self.parseUint();
        var max = min;
        if (self.eat(',')) {
            if (self.peek() == '}') {
                max = options.unbounded;
            } else {
                max = try self.parseUint();
                if (max < min) return self.fail("quantifier max < min");
            }
        }
        if (!self.eat('}')) return self.fail("unclosed quantifier");
        return .{ .min = min, .max = max };
    }

    fn parseUint(self: *Parser) options.Error!u32 {
        if (self.peek() == null or !std.ascii.isDigit(self.peek().?)) return self.fail("expected number");
        var v: u32 = 0;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            const d: u32 = c - '0';
            if (v > (@as(u32, 0xffffffff) - d) / 10) return self.fail("number overflow");
            v = v * 10 + d;
            self.bump();
        }
        return v;
    }

    fn parseAtom(self: *Parser) options.Error!u32 {
        self.skipExtended();
        const loc = self.i;
        const c = self.peek() orelse return self.fail("unexpected end of pattern");
        switch (c) {
            '.' => {
                self.bump();
                return self.newNode(loc, .dot);
            },
            '^' => {
                self.bump();
                return self.newNode(loc, .{ .assert = .bol });
            },
            '$' => {
                self.bump();
                return self.newNode(loc, .{ .assert = .eol });
            },
            '[' => return self.parseClass(),
            '(' => return self.parseGroup(),
            '\\' => return self.parseEscape(false),
            '|', ')' => return self.fail("unexpected metacharacter"),
            '*', '+', '?' => return self.fail("nothing to repeat"),
            '{' => {
                const cp = try self.parseLiteralChar();
                return self.newNode(loc, .{ .char = cp });
            },
            else => {
                if (self.flags.extended and (c == '#' or c == ' ' or c == '\t' or c == '\n')) {
                    return self.fail("internal skip error");
                }
                const cp = try self.parseLiteralChar();
                return self.newNode(loc, .{ .char = cp });
            },
        }
    }

    fn parseLiteralChar(self: *Parser) options.Error!u21 {
        const c = self.peek() orelse return self.fail("unexpected end");
        if (!self.flags.utf or c < 0x80) {
            self.bump();
            return c;
        }
        const decoded = unicode.decodeAt(self.src, self.i) catch return self.fail("invalid UTF-8 in pattern");
        self.i += decoded.len;
        return decoded.cp;
    }

    fn parseGroup(self: *Parser) options.Error!u32 {
        const loc = self.i;
        std.debug.assert(self.eat('('));
        if (self.nesting >= options.max_nesting) return error.NestingTooDeep;
        self.nesting += 1;
        defer self.nesting -= 1;

        if (self.eat('?')) {
            return self.parseGroupQuestion();
        }
        if (self.peek() == '*') {
            return self.parseVerb(loc);
        }

        var capture: ?u32 = null;
        if (!self.no_auto_capture) {
            if (self.capture_next > options.max_captures) return error.TooManyCaptures;
            capture = self.capture_next;
            self.capture_next += 1;
        }
        const body = try self.parseAlt();
        self.skipExtended();
        if (!self.eat(')')) return self.fail("unclosed group");
        return self.newNode(loc, .{ .group = .{ .capture = capture, .name = null, .body = body } });
    }

    fn parseGroupQuestion(self: *Parser) options.Error!u32 {
        const loc = self.i - 2;
        const c = self.peek() orelse return self.fail("unclosed group");
        switch (c) {
            ':' => {
                self.bump();
                const body = try self.parseAlt();
                if (!self.eat(')')) return self.fail("unclosed group");
                return self.newNode(loc, .{ .group = .{ .capture = null, .name = null, .body = body } });
            },
            '>' => {
                self.bump();
                const body = try self.parseAlt();
                if (!self.eat(')')) return self.fail("unclosed group");
                return self.newNode(loc, .{ .atomic = body });
            },
            '=' => {
                self.bump();
                const body = try self.parseAlt();
                if (!self.eat(')')) return self.fail("unclosed group");
                return self.newNode(loc, .{ .look = .{ .behind = false, .negate = false, .body = body } });
            },
            '!' => {
                self.bump();
                const body = try self.parseAlt();
                if (!self.eat(')')) return self.fail("unclosed group");
                return self.newNode(loc, .{ .look = .{ .behind = false, .negate = true, .body = body } });
            },
            '#' => {
                self.bump();
                while (self.peek()) |ch| {
                    self.bump();
                    if (ch == ')') break;
                }
                return self.newNode(loc, .empty);
            },
            '|' => {
                self.bump();
                return self.parseBranchReset();
            },
            '<' => {
                self.bump();
                const n = self.peek() orelse return self.fail("unclosed group");
                if (n == '=' or n == '!') {
                    const negate = n == '!';
                    self.bump();
                    const body = try self.parseAlt();
                    if (!self.eat(')')) return self.fail("unclosed group");
                    return self.newNode(loc, .{ .look = .{ .behind = true, .negate = negate, .body = body } });
                }
                const name = try self.parseNameUntil('>');
                if (!self.eat('>')) return self.fail("unclosed named group");
                return self.parseNamedCapture(loc, name);
            },
            '\'' => {
                self.bump();
                const name = try self.parseNameUntil('\'');
                if (!self.eat('\'')) return self.fail("unclosed named group");
                return self.parseNamedCapture(loc, name);
            },
            'P' => {
                self.bump();
                if (self.eat('<')) {
                    const name = try self.parseNameUntil('>');
                    if (!self.eat('>')) return self.fail("unclosed named group");
                    return self.parseNamedCapture(loc, name);
                }
                if (self.eat('=')) {
                    const name = try self.parseNameUntil(')');
                    if (!self.eat(')')) return self.fail("unclosed named backref");
                    const idx = self.lookupName(name) orelse return self.fail("unknown group name");
                    return self.newNode(loc, .{ .backref = .{ .index = idx, .caseless = self.flags.caseless } });
                }
                return self.fail("unknown (?P construct");
            },
            '(' => return self.parseConditional(loc),
            'R', '0'...'9', '+' => return self.parseSubroutine(loc),
            '&' => {
                self.bump();
                const name = try self.parseNameUntil(')');
                if (!self.eat(')')) return self.fail("unclosed subroutine");
                const idx = self.lookupName(name) orelse return self.fail("unknown group name");
                return self.newNode(loc, .{ .call = .{ .group = idx } });
            },
            'i', 'm', 's', 'x', 'U', 'J', 'n', '-' => return self.parseFlags(loc),
            else => return self.fail("unknown group extension"),
        }
    }

    fn parseBranchReset(self: *Parser) options.Error!u32 {
        const loc = self.i;
        const saved = self.capture_next;
        var max_used = saved;
        var buf: [64]u32 = undefined;
        var count: u32 = 0;
        while (true) {
            self.capture_next = saved;
            if (count >= buf.len) return error.PatternTooLarge;
            buf[count] = try self.parseConcat();
            count += 1;
            max_used = @max(max_used, self.capture_next);
            self.skipExtended();
            if (self.eat('|')) continue;
            break;
        }
        if (!self.eat(')')) return self.fail("unclosed group");
        self.capture_next = max_used;
        const start = self.n_extras;
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.pushExtra(buf[i]);
        const body = try self.newNode(loc, .{ .alt = .{ .start = start, .len = count } });
        return self.newNode(loc, .{ .group = .{
            .capture = null,
            .name = null,
            .body = body,
            .branch_reset = true,
        } });
    }

    fn parseNamedCapture(self: *Parser, loc: usize, name: []const u8) options.Error!u32 {
        if (self.capture_next > options.max_captures) return error.TooManyCaptures;
        const idx = self.capture_next;
        self.capture_next += 1;
        try self.addName(idx, name);
        const body = try self.parseAlt();
        if (!self.eat(')')) return self.fail("unclosed group");
        return self.newNode(loc, .{ .group = .{ .capture = idx, .name = name, .body = body } });
    }

    fn parseNameUntil(self: *Parser, end: u8) options.Error![]const u8 {
        const start = self.i;
        while (self.peek()) |c| {
            if (c == end) break;
            if (!std.ascii.isAlphanumeric(c) and c != '_') return self.fail("invalid group name");
            self.bump();
        }
        if (self.i == start) return self.fail("empty group name");
        return self.src[start..self.i];
    }

    fn lookupName(self: *Parser, name: []const u8) ?u32 {
        for (self.names[0..self.n_names]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.index;
        }
        return null;
    }

    fn parseFlags(self: *Parser, loc: usize) options.Error!u32 {
        var set = Flags{
            .caseless = false,
            .multiline = false,
            .dotall = false,
            .extended = false,
            .ungreedy = false,
            .ucp = false,
            .utf = false,
        };
        var unset = set;
        var on = true;
        while (self.peek()) |c| {
            switch (c) {
                'i' => {
                    if (on) set.caseless = true else unset.caseless = true;
                    self.bump();
                },
                'm' => {
                    if (on) set.multiline = true else unset.multiline = true;
                    self.bump();
                },
                's' => {
                    if (on) set.dotall = true else unset.dotall = true;
                    self.bump();
                },
                'x' => {
                    if (on) set.extended = true else unset.extended = true;
                    self.bump();
                },
                'U' => {
                    if (on) set.ungreedy = true else unset.ungreedy = true;
                    self.bump();
                },
                'n' => {
                    self.no_auto_capture = on;
                    self.bump();
                },
                'J' => self.bump(),
                '-' => {
                    on = false;
                    self.bump();
                },
                ':' => {
                    self.bump();
                    const saved = self.flags;
                    self.applyFlags(set, unset);
                    const body = try self.parseAlt();
                    self.flags = saved;
                    if (!self.eat(')')) return self.fail("unclosed group");
                    return self.newNode(loc, .{ .opt_set = .{ .set = set, .unset = unset, .body = body } });
                },
                ')' => {
                    self.bump();
                    self.applyFlags(set, unset);
                    return self.newNode(loc, .{ .opt_set = .{ .set = set, .unset = unset, .body = null } });
                },
                else => return self.fail("unknown flag"),
            }
        }
        return self.fail("unclosed flags");
    }

    fn applyFlags(self: *Parser, set: Flags, unset: Flags) void {
        if (set.caseless) self.flags.caseless = true;
        if (unset.caseless) self.flags.caseless = false;
        if (set.multiline) self.flags.multiline = true;
        if (unset.multiline) self.flags.multiline = false;
        if (set.dotall) self.flags.dotall = true;
        if (unset.dotall) self.flags.dotall = false;
        if (set.extended) self.flags.extended = true;
        if (unset.extended) self.flags.extended = false;
        if (set.ungreedy) self.flags.ungreedy = true;
        if (unset.ungreedy) self.flags.ungreedy = false;
    }

    fn parseSubroutine(self: *Parser, loc: usize) options.Error!u32 {
        var group: u32 = 0;
        if (self.eat('R')) {
            group = 0;
        } else if (self.peek() == '+' or self.peek() == '-') {
            return self.unsupported("relative subroutine calls");
        } else {
            group = try self.parseUint();
        }
        if (self.peek() == '(') return self.unsupported("subroutine with returned captures");
        if (!self.eat(')')) return self.fail("unclosed subroutine");
        return self.newNode(loc, .{ .call = .{ .group = group } });
    }

    fn parseConditional(self: *Parser, loc: usize) options.Error!u32 {
        std.debug.assert(self.eat('('));
        var group: ?u32 = null;
        var look: ?u32 = null;
        var look_negate = false;
        if (self.eat('?')) {
            const kind = self.peek() orelse return self.fail("bad conditional");
            if (kind == '=' or kind == '!') {
                look_negate = kind == '!';
                self.bump();
                look = try self.parseAlt();
                if (!self.eat(')')) return self.fail("unclosed lookahead condition");
            } else if (kind == '<' ) {
                self.bump();
                const n = self.peek() orelse return self.fail("bad lookbehind condition");
                look_negate = n == '!';
                if (n != '=' and n != '!') return self.fail("bad lookbehind condition");
                self.bump();
                look = try self.parseAlt();
                if (!self.eat(')')) return self.fail("unclosed lookbehind condition");
            } else return self.fail("bad conditional");
        } else if (self.peek() == 'R') {
            self.bump();
            group = 0;
            if (!self.eat(')')) return self.fail("unclosed condition");
        } else if (self.peek() == '<' or self.peek() == '\'') {
            const end: u8 = if (self.eat('<')) '>' else '\'';
            if (end == '\'') self.bump();
            const name = try self.parseNameUntil(end);
            if (!self.eat(end)) return self.fail("unclosed named condition");
            if (!self.eat(')')) return self.fail("unclosed condition");
            group = self.lookupName(name) orelse return self.fail("unknown group name");
        } else {
            group = try self.parseUint();
            if (!self.eat(')')) return self.fail("unclosed condition");
        }
        const yes = try self.parseConcat();
        var no: u32 = try self.newNode(self.i, .empty);
        self.skipExtended();
        if (self.eat('|')) {
            no = try self.parseConcat();
            self.skipExtended();
            if (self.peek() == '|') return self.fail("conditional has more than two branches");
        }
        if (!self.eat(')')) return self.fail("unclosed conditional");
        return self.newNode(loc, .{ .cond = .{
            .group = group,
            .look = look,
            .look_negate = look_negate,
            .yes = yes,
            .no = no,
        } });
    }

    fn parseVerb(self: *Parser, loc: usize) options.Error!u32 {
        std.debug.assert(self.eat('*'));
        const start = self.i;
        while (self.peek()) |c| {
            if (c == ')' or c == ':') break;
            self.bump();
        }
        const name = self.src[start..self.i];
        if (self.eat(':')) {
            while (self.peek()) |c| {
                if (c == ')') break;
                self.bump();
            }
            if (std.ascii.eqlIgnoreCase(name, "MARK") or std.ascii.eqlIgnoreCase(name, ":") or
                std.ascii.eqlIgnoreCase(name, "SKIP") or std.ascii.eqlIgnoreCase(name, "THEN") or
                std.ascii.eqlIgnoreCase(name, "PRUNE"))
            {
                if (!self.eat(')')) return self.fail("unclosed verb");
                if (std.ascii.eqlIgnoreCase(name, "MARK") or std.mem.eql(u8, name, ":"))
                    return self.unsupported("(*MARK:name)");
                if (std.ascii.eqlIgnoreCase(name, "SKIP"))
                    return self.newNode(loc, .{ .control = .skip });
                if (std.ascii.eqlIgnoreCase(name, "THEN"))
                    return self.newNode(loc, .{ .control = .then });
                return self.newNode(loc, .{ .control = .prune });
            }
            return self.unsupported("named control verb argument");
        }
        if (!self.eat(')')) return self.fail("unclosed verb");
        if (std.ascii.eqlIgnoreCase(name, "ACCEPT"))
            return self.newNode(loc, .{ .control = .accept });
        if (std.ascii.eqlIgnoreCase(name, "FAIL") or std.ascii.eqlIgnoreCase(name, "F"))
            return self.newNode(loc, .{ .control = .fail });
        if (std.ascii.eqlIgnoreCase(name, "COMMIT"))
            return self.newNode(loc, .{ .control = .commit });
        if (std.ascii.eqlIgnoreCase(name, "PRUNE"))
            return self.newNode(loc, .{ .control = .prune });
        if (std.ascii.eqlIgnoreCase(name, "SKIP"))
            return self.newNode(loc, .{ .control = .skip });
        if (std.ascii.eqlIgnoreCase(name, "THEN"))
            return self.newNode(loc, .{ .control = .then });
        return self.unsupported("unknown control verb");
    }

    fn parseClass(self: *Parser) options.Error!u32 {
        const loc = self.i;
        std.debug.assert(self.eat('['));
        const saved = self.in_class;
        self.in_class = true;
        defer self.in_class = saved;

        var class = Class{
            .utf = self.flags.utf,
            .caseless = self.flags.caseless,
        };
        if (self.eat('^')) class.negated = true;

        var first = true;
        while (true) {
            const c = self.peek() orelse return self.fail("unclosed character class");
            if (c == ']' and !first) {
                self.bump();
                break;
            }
            first = false;
            if (c == '[' and self.peekAt(1) == ':') {
                try self.parsePosixClass(&class);
                continue;
            }
            if (c == '\\') {
                const esc = try self.parseEscape(true);
                switch (self.nodes[esc].kind) {
                    .class => |cl| mergeClass(&class, self.classes[cl]),
                    .char => |cp| {
                        if (self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']') {
                            self.bump();
                            const end_cp = try self.parseClassAtom();
                            if (end_cp < cp) return self.fail("invalid class range");
                            class.addRange(cp, end_cp);
                        } else {
                            class.addCodepoint(cp);
                        }
                    },
                    else => return self.fail("invalid class escape"),
                }
                continue;
            }
            const start_cp = try self.parseClassAtom();
            if (self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']') {
                self.bump();
                const end_cp = try self.parseClassAtom();
                if (end_cp < start_cp) return self.fail("invalid class range");
                class.addRange(start_cp, end_cp);
            } else {
                class.addCodepoint(start_cp);
            }
        }
        return self.classNode(loc, class);
    }

    fn parseClassAtom(self: *Parser) options.Error!u21 {
        const c = self.peek() orelse return self.fail("unclosed character class");
        if (c == '\\') {
            const esc = try self.parseEscape(true);
            return switch (self.nodes[esc].kind) {
                .char => |cp| cp,
                else => self.fail("invalid class range bound"),
            };
        }
        return self.parseLiteralChar();
    }

    fn parsePosixClass(self: *Parser, class: *Class) options.Error!void {
        std.debug.assert(self.eat('['));
        std.debug.assert(self.eat(':'));
        var neg = false;
        if (self.eat('^')) neg = true;
        const start = self.i;
        while (self.peek()) |c| {
            if (c == ':') break;
            self.bump();
        }
        const name = self.src[start..self.i];
        if (!self.eat(':') or !self.eat(']')) return self.fail("unclosed POSIX class");
        const prop: unicode.Property = blk: {
            if (std.mem.eql(u8, name, "alnum")) break :blk .alnum;
            if (std.mem.eql(u8, name, "alpha")) break :blk .alpha;
            if (std.mem.eql(u8, name, "ascii")) break :blk .ascii;
            if (std.mem.eql(u8, name, "blank")) break :blk .blank;
            if (std.mem.eql(u8, name, "cntrl")) break :blk .cntrl;
            if (std.mem.eql(u8, name, "digit")) break :blk .digit;
            if (std.mem.eql(u8, name, "graph")) break :blk .graph;
            if (std.mem.eql(u8, name, "lower")) break :blk .lower;
            if (std.mem.eql(u8, name, "print")) break :blk .print;
            if (std.mem.eql(u8, name, "punct")) break :blk .punct;
            if (std.mem.eql(u8, name, "space")) break :blk .space;
            if (std.mem.eql(u8, name, "upper")) break :blk .upper;
            if (std.mem.eql(u8, name, "word")) break :blk .word;
            if (std.mem.eql(u8, name, "xdigit")) break :blk .xdigit;
            return self.fail("unknown POSIX class");
        };
        if (self.flags.ucp or prop == .ascii or prop == .xdigit or prop == .blank) {
            class.addProp(prop, neg);
        } else {
            applyAsciiPosix(class, name, neg);
        }
    }

    fn parseEscape(self: *Parser, in_class: bool) options.Error!u32 {
        const loc = self.i;
        std.debug.assert(self.eat('\\'));
        const c = self.peek() orelse return self.fail("dangling backslash");
        self.bump();
        switch (c) {
            'n' => return self.charOrClass(loc, in_class, '\n'),
            'r' => return self.charOrClass(loc, in_class, '\r'),
            't' => return self.charOrClass(loc, in_class, '\t'),
            'f' => return self.charOrClass(loc, in_class, 0x0c),
            'a' => return self.charOrClass(loc, in_class, 0x07),
            'e' => return self.charOrClass(loc, in_class, 0x1b),
            'v' => {
                if (in_class) {
                    var class = Class{ .utf = self.flags.utf, .caseless = self.flags.caseless };
                    addVertical(&class);
                    return self.classNode(loc, class);
                }
                var class = Class{ .utf = self.flags.utf };
                addVertical(&class);
                return self.classNode(loc, class);
            },
            'V' => {
                var class = Class{ .utf = self.flags.utf, .negated = true };
                addVertical(&class);
                return self.classNode(loc, class);
            },
            'h' => {
                var class = Class{ .utf = self.flags.utf };
                addHorizontal(&class);
                return self.classNode(loc, class);
            },
            'H' => {
                var class = Class{ .utf = self.flags.utf, .negated = true };
                addHorizontal(&class);
                return self.classNode(loc, class);
            },
            'd' => return self.shorthand(loc, .digit, false),
            'D' => return self.shorthand(loc, .digit, true),
            'w' => return self.shorthand(loc, .word, false),
            'W' => return self.shorthand(loc, .word, true),
            's' => return self.shorthand(loc, .space, false),
            'S' => return self.shorthand(loc, .space, true),
            'p', 'P' => {
                const neg = c == 'P';
                const prop = try self.parsePProperty();
                var class = Class{ .utf = self.flags.utf, .negated = false };
                class.addProp(prop, neg);
                return self.classNode(loc, class);
            },
            'x' => {
                const cp = try self.parseHex();
                return self.charOrClass(loc, in_class, cp);
            },
            'o' => {
                if (!self.eat('{')) return self.fail("expected \\o{...}");
                var v: u21 = 0;
                var any = false;
                while (self.peek()) |d| {
                    if (d == '}') break;
                    if (d < '0' or d > '7') return self.fail("invalid octal");
                    v = v * 8 + (d - '0');
                    any = true;
                    self.bump();
                }
                if (!any or !self.eat('}')) return self.fail("invalid \\o{}");
                return self.charOrClass(loc, in_class, v);
            },
            '0' => {
                var v: u21 = 0;
                var n: u8 = 0;
                while (n < 2) : (n += 1) {
                    const d = self.peek() orelse break;
                    if (d < '0' or d > '7') break;
                    v = v * 8 + (d - '0');
                    self.bump();
                }
                return self.charOrClass(loc, in_class, v);
            },
            '1'...'9' => {
                if (in_class) return self.fail("backref in class");
                var v: u32 = c - '0';
                while (self.peek()) |d| {
                    if (!std.ascii.isDigit(d)) break;
                    const next = v * 10 + (d - '0');
                    if (next > 99) break;
                    v = next;
                    self.bump();
                }
                return self.newNode(loc, .{ .backref = .{ .index = v, .caseless = self.flags.caseless } });
            },
            'g' => {
                if (in_class) return self.fail("backref in class");
                return self.parseGBackref(loc);
            },
            'k' => {
                if (in_class) return self.fail("backref in class");
                const opener = self.peek() orelse return self.fail("bad \\k");
                const end: u8 = switch (opener) {
                    '<' => '>',
                    '\'' => '\'',
                    '{' => '}',
                    else => return self.fail("bad \\k"),
                };
                self.bump();
                const name = try self.parseNameUntil(end);
                if (!self.eat(end)) return self.fail("unclosed \\k");
                const idx = self.lookupName(name) orelse return self.fail("unknown group name");
                return self.newNode(loc, .{ .backref = .{ .index = idx, .caseless = self.flags.caseless } });
            },
            'b' => if (in_class) return self.charOrClass(loc, true, 0x08) else return self.newNode(loc, .{ .assert = .word_boundary }),
            'B' => if (in_class) return self.fail("\\B in class") else return self.newNode(loc, .{ .assert = .not_word_boundary }),
            'A' => return self.newNode(loc, .{ .assert = .bot }),
            'Z' => return self.newNode(loc, .{ .assert = .eot_nl }),
            'z' => return self.newNode(loc, .{ .assert = .eot }),
            'G' => return self.newNode(loc, .{ .assert = .start_match }),
            'K' => return self.newNode(loc, .reset_start),
            'R' => return self.newNode(loc, .newline_seq),
            'X' => return self.newNode(loc, .grapheme),
            'Q' => return self.parseQuoted(loc),
            'C' => return self.unsupported("\\C"),
            'N' => {
                if (self.peek() == '{') return self.unsupported("\\N{name}");
                // \N = any except newline
                return self.newNode(loc, .dot);
            },
            else => return self.charOrClass(loc, in_class, c),
        }
    }

    fn parseQuoted(self: *Parser, loc: usize) options.Error!u32 {
        var buf: [256]u32 = undefined;
        var count: u32 = 0;
        while (self.i < self.src.len) {
            if (self.src[self.i] == '\\' and self.i + 1 < self.src.len and self.src[self.i + 1] == 'E') {
                self.i += 2;
                break;
            }
            const cp = try self.parseLiteralChar();
            if (count >= buf.len) return error.PatternTooLarge;
            buf[count] = try self.newNode(self.i, .{ .char = cp });
            count += 1;
        }
        if (count == 0) return self.newNode(loc, .empty);
        if (count == 1) return buf[0];
        const start = self.n_extras;
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.pushExtra(buf[i]);
        return self.newNode(loc, .{ .concat = .{ .start = start, .len = count } });
    }

    fn parseGBackref(self: *Parser, loc: usize) options.Error!u32 {
        if (self.eat('{')) {
            if (self.peek() == '-' or self.peek() == '+') return self.unsupported("relative \\g");
            const v = try self.parseUint();
            if (!self.eat('}')) return self.fail("unclosed \\g{}");
            return self.newNode(loc, .{ .backref = .{ .index = v, .caseless = self.flags.caseless } });
        }
        if (self.eat('<')) {
            if (std.ascii.isDigit(self.peek() orelse 0)) {
                const v = try self.parseUint();
                if (!self.eat('>')) return self.fail("unclosed \\g<>");
                return self.newNode(loc, .{ .backref = .{ .index = v, .caseless = self.flags.caseless } });
            }
            const name = try self.parseNameUntil('>');
            if (!self.eat('>')) return self.fail("unclosed \\g<>");
            const idx = self.lookupName(name) orelse return self.fail("unknown group name");
            return self.newNode(loc, .{ .backref = .{ .index = idx, .caseless = self.flags.caseless } });
        }
        if (std.ascii.isDigit(self.peek() orelse 0)) {
            const v = try self.parseUint();
            return self.newNode(loc, .{ .backref = .{ .index = v, .caseless = self.flags.caseless } });
        }
        return self.fail("bad \\g");
    }

    fn parsePProperty(self: *Parser) options.Error!unicode.Property {
        if (self.eat('{')) {
            const start = self.i;
            while (self.peek()) |c| {
                if (c == '}') break;
                self.bump();
            }
            const name = self.src[start..self.i];
            if (!self.eat('}')) return self.fail("unclosed \\p{}");
            var n = name;
            if (std.mem.startsWith(u8, n, "Is")) n = n[2..];
            if (std.mem.startsWith(u8, n, "In")) return self.unsupported("unicode script/block");
            return unicode.parsePropertyName(n) orelse self.fail("unknown unicode property");
        }
        const c = self.peek() orelse return self.fail("dangling \\p");
        self.bump();
        const buf = [_]u8{c};
        return unicode.parsePropertyName(&buf) orelse self.fail("unknown unicode property");
    }

    fn parseHex(self: *Parser) options.Error!u21 {
        if (self.eat('{')) {
            var v: u21 = 0;
            var any = false;
            while (self.peek()) |c| {
                if (c == '}') break;
                const d = hexVal(c) orelse return self.fail("invalid hex");
                v = (v << 4) + d;
                any = true;
                self.bump();
                if (v > 0x10FFFF) return self.fail("codepoint too large");
            }
            if (!any or !self.eat('}')) return self.fail("invalid \\x{}");
            return v;
        }
        var v: u21 = 0;
        var n: u8 = 0;
        while (n < 2) : (n += 1) {
            const c = self.peek() orelse break;
            const d = hexVal(c) orelse break;
            v = (v << 4) + d;
            self.bump();
        }
        return v;
    }

    fn charOrClass(self: *Parser, loc: usize, in_class: bool, cp: u21) options.Error!u32 {
        _ = in_class;
        return self.newNode(loc, .{ .char = cp });
    }

    fn shorthand(self: *Parser, loc: usize, kind: enum { digit, word, space }, negated: bool) options.Error!u32 {
        var class = Class{ .utf = self.flags.utf, .caseless = false, .negated = negated };
        if (self.flags.ucp) {
            class.addProp(switch (kind) {
                .digit => .digit,
                .word => .word,
                .space => .space,
            }, false);
        } else {
            switch (kind) {
                .digit => class.addRange('0', '9'),
                .word => {
                    class.addRange('0', '9');
                    class.addRange('A', 'Z');
                    class.addRange('a', 'z');
                    class.addCodepoint('_');
                },
                .space => {
                    class.addCodepoint(' ');
                    class.addCodepoint('\t');
                    class.addCodepoint('\n');
                    class.addCodepoint('\r');
                    class.addCodepoint(0x0b);
                    class.addCodepoint(0x0c);
                },
            }
        }
        return self.classNode(loc, class);
    }

    fn classNode(self: *Parser, loc: usize, class: Class) options.Error!u32 {
        const idx = try self.addClass(class);
        return self.newNode(loc, .{ .class = idx });
    }

    fn resolveForwardBackrefs(self: *Parser, root: u32) void {
        _ = root;
        _ = self.capture_next;
    }
};

fn hexVal(c: u8) ?u21 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn mergeClass(dst: *Class, src: Class) void {
    dst.bits[0] |= src.bits[0];
    dst.bits[1] |= src.bits[1];
    dst.bits[2] |= src.bits[2];
    dst.bits[3] |= src.bits[3];
    var i: u8 = 0;
    while (i < src.range_count and dst.range_count < dst.ranges.len) : (i += 1) {
        dst.ranges[dst.range_count] = src.ranges[i];
        dst.range_count += 1;
    }
    i = 0;
    while (i < src.prop_count and dst.prop_count < dst.props.len) : (i += 1) {
        dst.props[dst.prop_count] = src.props[i];
        dst.prop_count += 1;
    }
}

fn addHorizontal(class: *Class) void {
    class.addCodepoint('\t');
    class.addCodepoint(' ');
    class.addCodepoint(0xa0);
    class.addRange(0x2000, 0x200A);
    class.addCodepoint(0x202F);
    class.addCodepoint(0x205F);
    class.addCodepoint(0x3000);
}

fn addVertical(class: *Class) void {
    class.addCodepoint(0x0a);
    class.addCodepoint(0x0b);
    class.addCodepoint(0x0c);
    class.addCodepoint(0x0d);
    class.addCodepoint(0x85);
    class.addCodepoint(0x2028);
    class.addCodepoint(0x2029);
}

fn applyAsciiPosix(class: *Class, name: []const u8, neg: bool) void {
    var tmp = Class{};
    if (std.mem.eql(u8, name, "digit")) tmp.addRange('0', '9');
    if (std.mem.eql(u8, name, "xdigit")) {
        tmp.addRange('0', '9');
        tmp.addRange('A', 'F');
        tmp.addRange('a', 'f');
    }
    if (std.mem.eql(u8, name, "alpha")) {
        tmp.addRange('A', 'Z');
        tmp.addRange('a', 'z');
    }
    if (std.mem.eql(u8, name, "alnum")) {
        tmp.addRange('0', '9');
        tmp.addRange('A', 'Z');
        tmp.addRange('a', 'z');
    }
    if (std.mem.eql(u8, name, "word")) {
        tmp.addRange('0', '9');
        tmp.addRange('A', 'Z');
        tmp.addRange('a', 'z');
        tmp.addCodepoint('_');
    }
    if (std.mem.eql(u8, name, "lower")) tmp.addRange('a', 'z');
    if (std.mem.eql(u8, name, "upper")) tmp.addRange('A', 'Z');
    if (std.mem.eql(u8, name, "space")) {
        tmp.addCodepoint(' ');
        tmp.addCodepoint('\t');
        tmp.addCodepoint('\n');
        tmp.addCodepoint('\r');
        tmp.addCodepoint(0x0b);
        tmp.addCodepoint(0x0c);
    }
    if (std.mem.eql(u8, name, "blank")) {
        tmp.addCodepoint(' ');
        tmp.addCodepoint('\t');
    }
    if (std.mem.eql(u8, name, "cntrl")) {
        tmp.addRange(0, 0x1f);
        tmp.addCodepoint(0x7f);
    }
    if (std.mem.eql(u8, name, "graph")) tmp.addRange(0x21, 0x7e);
    if (std.mem.eql(u8, name, "print")) tmp.addRange(0x20, 0x7e);
    if (std.mem.eql(u8, name, "punct")) {
        tmp.addRange(0x21, 0x2f);
        tmp.addRange(0x3a, 0x40);
        tmp.addRange(0x5b, 0x60);
        tmp.addRange(0x7b, 0x7e);
    }
    if (std.mem.eql(u8, name, "ascii")) tmp.addRange(0, 0x7f);
    tmp.negated = neg;
    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        if (tmp.matches(@intCast(b))) class.setBit(@intCast(b));
    }
}
