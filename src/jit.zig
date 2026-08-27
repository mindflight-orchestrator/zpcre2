//! Copy-and-patch JIT for linear ASCII chains (Linux x86_64).
//! Other targets keep the interpreter. Mapping or encode failure is silent.

const std = @import("std");
const builtin = @import("builtin");
const analyze = @import("analyze.zig");
const bytecode = @import("bytecode.zig");

const page_size_min = std.heap.page_size_min;
const unbounded: u32 = 0xffff_ffff;

pub const Entry = *const fn (
    subject: [*]const u8,
    len: usize,
    start: usize,
    match_start: *usize,
    match_end: *usize,
) callconv(.c) bool;

pub const Jit = union(enum) {
    none,
    mapped: struct {
        mem: []align(page_size_min) u8,
        entry: Entry,
    },

    pub fn deinit(self: *Jit) void {
        switch (self.*) {
            .none => {},
            .mapped => |m| std.posix.munmap(m.mem),
        }
        self.* = .none;
    }

    pub fn active(self: Jit) bool {
        return self == .mapped;
    }

    pub fn find(self: Jit, subject: []const u8, start: usize) ?struct { start: usize, end: usize } {
        const mapped = switch (self) {
            .none => return null,
            .mapped => |m| m,
        };
        if (start > subject.len) return null;
        var mstart: usize = undefined;
        var mend: usize = undefined;
        if (!mapped.entry(subject.ptr, subject.len, start, &mstart, &mend)) return null;
        return .{ .start = mstart, .end = mend };
    }
};

pub fn compile(program: bytecode.Program, info: analyze.Info) Jit {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return .none;
    if (info.chain.n < 2) return .none;
    const skip_len = switch (info.chain.atoms[info.chain.skip]) {
        .lit => |lit| lit.len,
        else => return .none,
    };
    if (skip_len < 2) return .none;

    const page = std.heap.pageSize();
    const mem = std.posix.mmap(
        null,
        page,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return .none;

    var enc = Encoder{ .buf = mem };
    if (!enc.emitProgram(program, info) or !enc.ok) {
        std.posix.munmap(mem);
        return .none;
    }

    const rc = std.os.linux.mprotect(mem.ptr, mem.len, .{ .READ = true, .EXEC = true });
    if (std.posix.errno(rc) != .SUCCESS) {
        std.posix.munmap(mem);
        return .none;
    }

    return .{ .mapped = .{ .mem = mem, .entry = @ptrCast(mem.ptr) } };
}

const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    fn low(self: Reg) u3 {
        return @truncate(@intFromEnum(self));
    }
    fn hi(self: Reg) bool {
        return @intFromEnum(self) >= 8;
    }
};

const RipFix = struct { disp_at: usize, data_off: u16 };

const Encoder = struct {
    buf: []u8,
    n: usize = 0,
    ok: bool = true,
    rip: [24]RipFix = undefined,
    n_rip: u8 = 0,
    end_at: [8]usize = undefined,
    n_end: u8 = 0,
    next_at: [48]usize = undefined,
    n_next: u8 = 0,

    fn emitProgram(self: *Encoder, program: bytecode.Program, info: analyze.Info) bool {
        const chain = info.chain;
        const skip = switch (chain.atoms[chain.skip]) {
            .lit => |lit| lit,
            else => return false,
        };
        const lits_off: u16 = 0;
        const bitmap_base: u16 = @intCast(std.mem.alignForward(usize, chain.lit_n, 32));

        self.push(.rbx);
        self.push(.r12);
        self.push(.r13);
        self.push(.r14);
        self.push(.r15);
        self.push(.rbp);

        self.movRR(.r12, .rdi);
        self.movRR(.r13, .rsi);
        self.movRR(.rbp, .rdx);
        self.movRR(.r14, .rdx);
        self.movRR(.r15, .rcx);
        self.movRR(.rbx, .r8);

        self.cmpRR(.r14, .r13);
        self.jumpEnd(.ja);

        const skip_bytes = chain.litSlice(skip.off, skip.len);
        const search = self.n;
        self.movRR(.rax, .r13);
        self.subRR(.rax, .r14);
        self.cmpImm(.rax, skip.len);
        self.jumpEnd(.jb);

        self.cmpMem(.r14, 0, 1, skip_bytes[0]);
        self.jumpNext(.jne);
        self.emitLitImm(.r14, skip_bytes[1..], 1, .next);

        self.movRR(.r10, .r14);
        self.leaDisp(.r11, .r14, skip.len);

        var i: u8 = chain.skip + 1;
        while (i < chain.n) : (i += 1) {
            if (!self.emitAtomFwd(program, chain, i, bitmap_base))
                return false;
        }
        i = chain.skip;
        while (i > 0) {
            i -= 1;
            if (!self.emitAtomBwd(program, chain, i, bitmap_base))
                return false;
        }

        self.cmpRR(.r10, .rbp);
        self.jumpNext(.jb);

        self.movStore(.r15, .r10);
        self.movStore(.rbx, .r11);
        self.byte(0xb8);
        self.imm32(1);
        const jmp_epi = self.jmpRaw();

        const search_next = self.n;
        self.patchSlice(self.next_at[0..self.n_next], search_next);
        self.inc(.r14);
        self.jmpTo(search);

        const fail = self.n;
        self.patchSlice(self.end_at[0..self.n_end], fail);
        self.byte(0x31);
        self.byte(0xc0);

        const epi = self.n;
        self.patch(jmp_epi, epi);
        self.pop(.rbp);
        self.pop(.r15);
        self.pop(.r14);
        self.pop(.r13);
        self.pop(.r12);
        self.pop(.rbx);
        self.byte(0xc3);

        return self.finishData(chain, program, lits_off, bitmap_base);
    }

    fn emitAtomFwd(
        self: *Encoder,
        program: bytecode.Program,
        chain: analyze.Chain,
        atom_i: u8,
        bitmap_base: u16,
    ) bool {
        switch (chain.atoms[atom_i]) {
            .lit => |lit| {
                self.emitLitFwd(chain.litSlice(lit.off, lit.len), .next);
                return self.ok;
            },
            .cls => |c| return self.emitClsFwd(program, c.idx, c.min, c.max, atom_i, bitmap_base),
            .alt => |a| return self.emitAltFwd(chain, a),
        }
    }

    fn emitAtomBwd(
        self: *Encoder,
        program: bytecode.Program,
        chain: analyze.Chain,
        atom_i: u8,
        bitmap_base: u16,
    ) bool {
        switch (chain.atoms[atom_i]) {
            .lit => |lit| {
                self.emitLitBwd(chain.litSlice(lit.off, lit.len), .next);
                return self.ok;
            },
            .cls => |c| return self.emitClsBwd(program, c.idx, c.min, c.max, atom_i, bitmap_base),
            .alt => |a| return self.emitAltBwd(chain, a),
        }
    }

    const FailTo = enum { next, end };

    fn emitLitFwd(self: *Encoder, bytes: []const u8, fail: FailTo) void {
        if (bytes.len == 0) return;
        self.leaDisp(.rax, .r11, bytes.len);
        self.cmpRR(.rax, .r13);
        self.jump(fail, .ja);
        self.emitLitImm(.r11, bytes, 0, fail);
        self.addImm(.r11, bytes.len);
    }

    fn emitLitBwd(self: *Encoder, bytes: []const u8, fail: FailTo) void {
        if (bytes.len == 0) return;
        self.cmpImm(.r10, bytes.len);
        self.jump(fail, .jb);
        self.movRR(.rax, .r10);
        self.subImm(.rax, bytes.len);
        self.emitLitImm(.rax, bytes, 0, fail);
        self.subImm(.r10, bytes.len);
    }

    fn emitClsFwd(
        self: *Encoder,
        program: bytecode.Program,
        idx: u16,
        min: u32,
        max: u32,
        atom_i: u8,
        bitmap_base: u16,
    ) bool {
        if (idx >= program.classes.len) return false;
        const bm = bitmap_base + @as(u16, atom_i) * 32;
        self.xorRR(.r9, .r9);
        const loop = self.n;
        var done_at: [4]usize = undefined;
        var n_done: u8 = 0;
        if (max != unbounded) {
            self.cmpImm32(.r9, max);
            done_at[n_done] = self.jcc(.jae);
            n_done += 1;
        }
        self.cmpRR(.r11, .r13);
        done_at[n_done] = self.jcc(.jae);
        n_done += 1;
        self.movzxBaseIndex(.rax, .r12, .r11);
        self.cmpEaxImm(128);
        done_at[n_done] = self.jcc(.jae);
        n_done += 1;
        if (!self.btRip(.rax, bm)) return false;
        done_at[n_done] = self.jcc(.jae); // jnc
        n_done += 1;
        self.inc(.r11);
        self.inc(.r9);
        self.jmpTo(loop);
        const done = self.n;
        self.patchSlice(done_at[0..n_done], done);
        self.cmpImm32(.r9, min);
        self.jumpNext(.jb);
        return self.ok;
    }

    fn emitClsBwd(
        self: *Encoder,
        program: bytecode.Program,
        idx: u16,
        min: u32,
        max: u32,
        atom_i: u8,
        bitmap_base: u16,
    ) bool {
        if (idx >= program.classes.len) return false;
        const bm = bitmap_base + @as(u16, atom_i) * 32;
        self.xorRR(.r9, .r9);
        const loop = self.n;
        var done_at: [4]usize = undefined;
        var n_done: u8 = 0;
        if (max != unbounded) {
            self.cmpImm32(.r9, max);
            done_at[n_done] = self.jcc(.jae);
            n_done += 1;
        }
        self.testRR(.r10, .r10);
        done_at[n_done] = self.jcc(.je);
        n_done += 1;
        self.movzxBaseIndexDisp8(.rax, .r12, .r10, -1);
        self.cmpEaxImm(128);
        done_at[n_done] = self.jcc(.jae);
        n_done += 1;
        if (!self.btRip(.rax, bm)) return false;
        done_at[n_done] = self.jcc(.jae);
        n_done += 1;
        self.dec(.r10);
        self.inc(.r9);
        self.jmpTo(loop);
        const done = self.n;
        self.patchSlice(done_at[0..n_done], done);
        self.cmpImm32(.r9, min);
        self.jumpNext(.jb);
        return self.ok;
    }

    fn emitAltFwd(self: *Encoder, chain: analyze.Chain, a: anytype) bool {
        self.movRR(.rsi, .r11);
        const saved_next = self.n_next;
        self.emitLitFwd(chain.litSlice(a.a_off, a.a_len), .next);
        const a_fail = self.next_at[saved_next..self.n_next];
        const jmp_done = self.jmpRaw();
        const try_b = self.n;
        self.patchSlice(a_fail, try_b);
        self.n_next = saved_next;
        self.movRR(.r11, .rsi);
        self.emitLitFwd(chain.litSlice(a.b_off, a.b_len), .next);
        self.patch(jmp_done, self.n);
        return self.ok;
    }

    fn emitAltBwd(self: *Encoder, chain: analyze.Chain, a: anytype) bool {
        self.movRR(.rsi, .r10);
        const saved_next = self.n_next;
        self.emitLitBwd(chain.litSlice(a.a_off, a.a_len), .next);
        const a_fail = self.next_at[saved_next..self.n_next];
        const jmp_done = self.jmpRaw();
        const try_b = self.n;
        self.patchSlice(a_fail, try_b);
        self.n_next = saved_next;
        self.movRR(.r10, .rsi);
        self.emitLitBwd(chain.litSlice(a.b_off, a.b_len), .next);
        self.patch(jmp_done, self.n);
        return self.ok;
    }

    fn emitLitImm(self: *Encoder, pos: Reg, bytes: []const u8, disp0: usize, fail: FailTo) void {
        var d = disp0;
        var i: usize = 0;
        while (i < bytes.len) {
            const rest = bytes.len - i;
            if (rest >= 4) {
                self.cmpMem(pos, d, 4, std.mem.readInt(u32, bytes[i..][0..4], .little));
                self.jump(fail, .jne);
                i += 4;
                d += 4;
            } else if (rest >= 2) {
                self.cmpMem(pos, d, 2, std.mem.readInt(u16, bytes[i..][0..2], .little));
                self.jump(fail, .jne);
                i += 2;
                d += 2;
            } else {
                self.cmpMem(pos, d, 1, bytes[i]);
                self.jump(fail, .jne);
                i += 1;
                d += 1;
            }
        }
    }

    fn cmpMem(self: *Encoder, pos: Reg, disp: usize, size: u8, imm: u32) void {
        if (size == 2) self.byte(0x66);
        self.rex(false, false, pos.hi(), true);
        self.byte(if (size == 1) 0x80 else 0x81);
        const mod: u2 = if (disp == 0) 0b00 else if (disp <= 127) 0b01 else 0b10;
        self.byte((@as(u8, mod) << 6) | (0b111 << 3) | 0b100);
        self.byte((@as(u8, pos.low()) << 3) | @as(u8, Reg.r12.low()));
        if (disp == 0) {} else if (disp <= 127) self.byte(@intCast(disp)) else self.imm32(@intCast(disp));
        switch (size) {
            1 => self.byte(@intCast(imm)),
            2 => self.imm16(@intCast(imm)),
            else => self.imm32(imm),
        }
    }

    fn finishData(
        self: *Encoder,
        chain: analyze.Chain,
        program: bytecode.Program,
        lits_off: u16,
        bitmap_base: u16,
    ) bool {
        if (!self.ok) return false;
        const data_at = std.mem.alignForward(usize, self.n, 16);
        const data_bytes = @as(usize, bitmap_base) + 8 * 32;
        if (data_at + data_bytes > self.buf.len) return false;
        @memset(self.buf[self.n..data_at], 0x90);
        @memset(self.buf[data_at .. data_at + data_bytes], 0);
        @memcpy(self.buf[data_at + lits_off ..][0..chain.lit_n], chain.lits[0..chain.lit_n]);
        var ai: u8 = 0;
        while (ai < chain.n) : (ai += 1) {
            switch (chain.atoms[ai]) {
                .cls => |c| {
                    if (c.idx >= program.classes.len) return false;
                    const dest = self.buf[data_at + bitmap_base + @as(usize, ai) * 32 ..];
                    @memcpy(dest[0..32], std.mem.asBytes(&program.classes[c.idx].bits)[0..32]);
                },
                else => {},
            }
        }
        var fi: u8 = 0;
        while (fi < self.n_rip) : (fi += 1) {
            const f = self.rip[fi];
            const rel = @as(i32, @intCast(@as(i64, @intCast(data_at + f.data_off)) -
                @as(i64, @intCast(f.disp_at + 4))));
            std.mem.writeInt(i32, self.buf[f.disp_at..][0..4], rel, .little);
        }
        return true;
    }

    const Cc = enum(u8) { ja = 7, jae = 3, jb = 2, je = 4, jne = 5 };

    fn jumpEnd(self: *Encoder, cc: Cc) void {
        self.end_at[self.n_end] = self.jcc(cc);
        self.n_end += 1;
    }

    fn jumpNext(self: *Encoder, cc: Cc) void {
        self.next_at[self.n_next] = self.jcc(cc);
        self.n_next += 1;
    }

    fn jump(self: *Encoder, to: FailTo, cc: Cc) void {
        switch (to) {
            .next => self.jumpNext(cc),
            .end => self.jumpEnd(cc),
        }
    }

    fn byte(self: *Encoder, b: u8) void {
        if (self.n >= self.buf.len) {
            self.ok = false;
            return;
        }
        self.buf[self.n] = b;
        self.n += 1;
    }

    fn imm16(self: *Encoder, v: u16) void {
        if (self.n + 2 > self.buf.len) {
            self.ok = false;
            return;
        }
        std.mem.writeInt(u16, self.buf[self.n..][0..2], v, .little);
        self.n += 2;
    }

    fn imm32(self: *Encoder, v: u32) void {
        if (self.n + 4 > self.buf.len) {
            self.ok = false;
            return;
        }
        std.mem.writeInt(u32, self.buf[self.n..][0..4], v, .little);
        self.n += 4;
    }

    fn rex(self: *Encoder, w: bool, r: bool, x: bool, b: bool) void {
        if (!w and !r and !x and !b) return;
        var v: u8 = 0x40;
        if (w) v |= 8;
        if (r) v |= 4;
        if (x) v |= 2;
        if (b) v |= 1;
        self.byte(v);
    }

    fn modrm(self: *Encoder, mod: u2, reg: Reg, rm: Reg) void {
        self.byte((@as(u8, mod) << 6) | (@as(u8, reg.low()) << 3) | rm.low());
    }

    fn push(self: *Encoder, r: Reg) void {
        self.rex(false, false, false, r.hi());
        self.byte(0x50 + @as(u8, r.low()));
    }

    fn pop(self: *Encoder, r: Reg) void {
        self.rex(false, false, false, r.hi());
        self.byte(0x58 + @as(u8, r.low()));
    }

    fn movRR(self: *Encoder, dst: Reg, src: Reg) void {
        self.rex(true, src.hi(), false, dst.hi());
        self.byte(0x89);
        self.modrm(0b11, src, dst);
    }

    fn xorRR(self: *Encoder, dst: Reg, src: Reg) void {
        self.rex(true, dst.hi(), false, src.hi());
        self.byte(0x33);
        self.modrm(0b11, dst, src);
    }

    fn cmpRR(self: *Encoder, dst: Reg, src: Reg) void {
        self.rex(true, dst.hi(), false, src.hi());
        self.byte(0x3b);
        self.modrm(0b11, dst, src);
    }

    fn subRR(self: *Encoder, dst: Reg, src: Reg) void {
        self.rex(true, dst.hi(), false, src.hi());
        self.byte(0x2b);
        self.modrm(0b11, dst, src);
    }

    fn testRR(self: *Encoder, a: Reg, b: Reg) void {
        self.rex(true, b.hi(), false, a.hi());
        self.byte(0x85);
        self.modrm(0b11, b, a);
    }

    fn cmpImm(self: *Encoder, r: Reg, imm: usize) void {
        self.rex(true, false, false, r.hi());
        self.byte(0x83);
        self.modrm(0b11, @enumFromInt(7), r);
        self.byte(@intCast(imm));
    }

    fn cmpImm32(self: *Encoder, r: Reg, imm: u32) void {
        if (imm <= 127) {
            self.cmpImm(r, imm);
            return;
        }
        self.rex(true, false, false, r.hi());
        self.byte(0x81);
        self.modrm(0b11, @enumFromInt(7), r);
        self.imm32(imm);
    }

    fn cmpEaxImm(self: *Encoder, imm: u32) void {
        self.byte(0x3d);
        self.imm32(imm);
    }

    fn addImm(self: *Encoder, r: Reg, imm: usize) void {
        self.rex(true, false, false, r.hi());
        self.byte(0x83);
        self.modrm(0b11, @enumFromInt(0), r);
        self.byte(@intCast(imm));
    }

    fn subImm(self: *Encoder, r: Reg, imm: usize) void {
        self.rex(true, false, false, r.hi());
        self.byte(0x83);
        self.modrm(0b11, @enumFromInt(5), r);
        self.byte(@intCast(imm));
    }

    fn inc(self: *Encoder, r: Reg) void {
        self.rex(true, false, false, r.hi());
        self.byte(0xff);
        self.modrm(0b11, @enumFromInt(0), r);
    }

    fn dec(self: *Encoder, r: Reg) void {
        self.rex(true, false, false, r.hi());
        self.byte(0xff);
        self.modrm(0b11, @enumFromInt(1), r);
    }

    fn leaDisp(self: *Encoder, dst: Reg, base: Reg, disp: usize) void {
        const needs_sib = base == .rsp or base == .r12;
        self.rex(true, dst.hi(), false, base.hi());
        self.byte(0x8d);
        const mod: u2 = if (disp <= 127) 0b01 else 0b10;
        if (needs_sib) {
            self.byte((@as(u8, mod) << 6) | (@as(u8, dst.low()) << 3) | 0b100);
            self.byte((@as(u8, 0b100) << 3) | base.low());
        } else {
            self.modrm(mod, dst, base);
        }
        if (disp <= 127) self.byte(@intCast(disp)) else self.imm32(@intCast(disp));
    }

    fn movzxBaseIndex(self: *Encoder, dst: Reg, base: Reg, index: Reg) void {
        self.rex(false, dst.hi(), index.hi(), base.hi());
        self.byte(0x0f);
        self.byte(0xb6);
        self.byte((@as(u8, dst.low()) << 3) | 0b100);
        self.byte((@as(u8, index.low()) << 3) | base.low());
    }

    fn movzxBaseIndexDisp8(self: *Encoder, dst: Reg, base: Reg, index: Reg, disp: i8) void {
        self.rex(false, dst.hi(), index.hi(), base.hi());
        self.byte(0x0f);
        self.byte(0xb6);
        self.byte(0b01 << 6 | @as(u8, dst.low()) << 3 | 0b100);
        self.byte((@as(u8, index.low()) << 3) | base.low());
        self.byte(@bitCast(disp));
    }

    fn btRip(self: *Encoder, bit: Reg, data_off: u16) bool {
        if (self.n_rip >= self.rip.len) {
            self.ok = false;
            return false;
        }
        self.rex(false, bit.hi(), false, false);
        self.byte(0x0f);
        self.byte(0xa3);
        self.byte((@as(u8, bit.low()) << 3) | 0b101);
        self.rip[self.n_rip] = .{ .disp_at = self.n, .data_off = data_off };
        self.n_rip += 1;
        self.imm32(0);
        return self.ok;
    }

    fn movStore(self: *Encoder, addr: Reg, src: Reg) void {
        self.rex(true, src.hi(), false, addr.hi());
        self.byte(0x89);
        if (addr == .rbp or addr == .r13) {
            self.modrm(0b01, src, addr);
            self.byte(0);
        } else if (addr == .rsp or addr == .r12) {
            self.byte((@as(u8, src.low()) << 3) | 0b100);
            self.byte((@as(u8, 0b100) << 3) | addr.low());
        } else {
            self.modrm(0b00, src, addr);
        }
    }

    fn jcc(self: *Encoder, cc: Cc) usize {
        self.byte(0x0f);
        self.byte(0x80 + @intFromEnum(cc));
        const at = self.n;
        self.imm32(0);
        return at;
    }

    fn jmpRaw(self: *Encoder) usize {
        self.byte(0xe9);
        const at = self.n;
        self.imm32(0);
        return at;
    }

    fn jmpTo(self: *Encoder, target: usize) void {
        self.patch(self.jmpRaw(), target);
    }

    fn patch(self: *Encoder, disp_at: usize, target: usize) void {
        if (disp_at + 4 > self.buf.len) {
            self.ok = false;
            return;
        }
        const rel = @as(i32, @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(disp_at + 4))));
        std.mem.writeInt(i32, self.buf[disp_at..][0..4], rel, .little);
    }

    fn patchSlice(self: *Encoder, sites: []const usize, target: usize) void {
        for (sites) |at| self.patch(at, target);
    }
};
