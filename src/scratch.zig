const std = @import("std");
const options = @import("options.zig");

const Allocator = std.mem.Allocator;

pub const Scratch = struct {
    slots: []?usize,
    capture_count: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capture_count: u32) Allocator.Error!Scratch {
        const n = 2 * (@as(usize, capture_count) + 1);
        const slots = try allocator.alloc(?usize, n);
        @memset(slots, null);
        return .{
            .slots = slots,
            .capture_count = capture_count,
            .allocator = allocator,
        };
    }

    pub fn reset(self: *Scratch) void {
        @memset(self.slots, null);
    }

    pub fn deinit(self: *Scratch) void {
        self.allocator.free(self.slots);
    }
};

pub const MatchLimits = struct {
    match_limit: u32 = options.default_match_limit,
    depth_limit: u32 = options.default_depth_limit,
    recursion_limit: u32 = options.default_recursion_limit,
};
