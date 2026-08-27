const bytecode = @import("bytecode.zig");
const options = @import("options.zig");

pub const Info = struct {
    min_length: u32 = 0,
    first_byte: ?u8 = null,
};

pub fn analyze(program: bytecode.Program) Info {
    var info = Info{};
    if (program.ops.len == 0) return info;
    var i: usize = 0;
    while (i < program.ops.len) : (i += 1) {
        switch (program.ops[i]) {
            .save => continue,
            .char => |cp| {
                if (cp <= 255) info.first_byte = @intCast(cp);
                info.min_length = 1;
                break;
            },
            .char_i => {
                info.min_length = 1;
                break;
            },
            .any, .any_nl, .class => {
                info.min_length = 1;
                break;
            },
            else => break,
        }
    }
    _ = options.spec_version;
    return info;
}
