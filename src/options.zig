//! Compile-time and match options, aligned with PCRE2 10.47 flags.

pub const Options = struct {
    utf: bool = true,
    caseless: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    extended: bool = false,
    anchored: bool = false,
    ungreedy: bool = false,
    ucp: bool = false,
    dollar_endonly: bool = false,
    no_auto_capture: bool = false,
};

pub const Flags = packed struct(u8) {
    caseless: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    extended: bool = false,
    ungreedy: bool = false,
    ucp: bool = false,
    utf: bool = true,
    _pad: bool = false,

    pub fn fromOptions(options: Options) Flags {
        return .{
            .caseless = options.caseless,
            .multiline = options.multiline,
            .dotall = options.dotall,
            .extended = options.extended,
            .ungreedy = options.ungreedy,
            .ucp = options.ucp,
            .utf = options.utf,
        };
    }
};

pub const Diagnostics = struct {
    offset: usize = 0,
    message: []const u8 = "invalid pattern",
};

pub const Error = error{
    InvalidPattern,
    UnsupportedSyntax,
    PatternTooLarge,
    NestingTooDeep,
    TooManyCaptures,
    OutOfMemory,
};

pub const spec_version = "10.47";

pub const max_pattern_len: usize = 1 << 20;
pub const max_nesting: u32 = 250;
pub const max_captures: u32 = 65535;
pub const max_ops: usize = 1 << 20;
pub const default_match_limit: u32 = 10_000_000;
pub const default_depth_limit: u32 = 2500;
pub const default_recursion_limit: u32 = 255;
pub const unbounded: u32 = 0xffff_ffff;
