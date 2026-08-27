const bytecode = @import("bytecode.zig");
const options = @import("options.zig");

pub const Assert = enum {
    bol,
    eol,
    bot,
    eot,
    eot_nl,
    word_boundary,
    not_word_boundary,
    start_match,
};

pub const Control = enum {
    accept,
    fail,
    commit,
    prune,
    skip,
    then,
};

pub const List = struct {
    start: u32,
    len: u32,
};

pub const Repeat = struct {
    inner: u32,
    min: u32,
    max: u32,
    greedy: bool,
    possessive: bool,
};

pub const Group = struct {
    capture: ?u32,
    name: ?[]const u8,
    body: u32,
    branch_reset: bool = false,
};

pub const LookNode = struct {
    behind: bool,
    negate: bool,
    body: u32,
};

pub const Backref = struct {
    index: u32,
    caseless: bool,
};

pub const Cond = struct {
    group: ?u32,
    look: ?u32,
    look_negate: bool = false,
    yes: u32,
    no: u32,
};

pub const Call = struct {
    group: u32,
};

pub const OptSet = struct {
    set: options.Flags,
    unset: options.Flags,
    body: ?u32,
};

pub const Node = struct {
    loc: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        empty,
        char: u21,
        class: u16,
        dot,
        concat: List,
        alt: List,
        group: Group,
        repeat: Repeat,
        assert: Assert,
        backref: Backref,
        look: LookNode,
        atomic: u32,
        cond: Cond,
        call: Call,
        control: Control,
        reset_start,
        newline_seq,
        grapheme,
        opt_set: OptSet,
    };
};

pub const max_nodes: u32 = 4096;
pub const max_extras: u32 = 8192;
pub const max_classes: u32 = 256;
pub const max_names: u32 = 256;
pub const max_ops: u32 = 8192;
