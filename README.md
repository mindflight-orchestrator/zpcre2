# zpcre2

Perl-compatible regular expressions for [Zig 0.16](https://ziglang.org/download/0.16.0/release-notes.html), rewritten from the [PCRE2 10.47](https://github.com/PCRE2Project/pcre2/releases) specification.

This is a **Zig-native engine**, not a C translation. Patterns compile at comptime or at runtime into bytecode; matching uses a backtracking VM with PCRE2-style captures.

## Status

Early implementation. Syntax coverage grows toward PCRE2 10.47. Unsupported constructs fail at compile time rather than matching incorrectly.

| Item | Value |
|---|---|
| Spec | PCRE2 10.47 (8-bit / UTF-8) |
| Toolchain | Zig 0.16.0 |
| C / libc | none in the library |
| JIT | Linux x86_64 copy-and-patch for linear ASCII chains (`compileAlloc`). Other patterns and targets use the interpreter. `compile` still bakes bytecode at comptime. |

## Quick start

```zig
const zpcre2 = @import("zpcre2");

// Pattern baked into the binary.
const Re = zpcre2.compile("(\\d{4})-(\\d{2})-(\\d{2})", .{});

pub fn main() void {
    if (Re.find("date 2026-08-27")) |m| {
        _ = m.slice("date 2026-08-27"); // "2026-08-27"
    }
}
```

Runtime compilation (CLI patterns):

```zig
var re = try zpcre2.compileAlloc(allocator, user_pattern, .{ .caseless = true });
defer re.deinit();
_ = re.isMatch(line);
```

## Build

```sh
zig build test --error-style minimal --test-timeout 60s
```

`zig build test` also runs differential checks against bundled PCRE2 10.47 (from `ext/pcre2`). Oracle-only:

```sh
zig build test-oracle
```

Match throughput vs the PCRE2 interpreter (ReleaseFast, compile once / match many):

```sh
zig build bench
zig build bench -- --size 1048576 --filter literal
```

## Spec source

`ext/pcre2` is a local clone of [PCRE2 10.47](https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.47) for testdata, documentation, and the test/bench oracle. The Zig library itself does not compile or link C.

```sh
git clone --branch pcre2-10.47 --depth 1 https://github.com/PCRE2Project/pcre2.git ext/pcre2
```

## License

BSD 3-Clause. PCRE2 testdata and Unicode-inspired tables follow the PCRE2 project license.
