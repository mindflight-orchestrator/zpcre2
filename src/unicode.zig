//! UTF-8 helpers and a useful Unicode property subset (PCRE2-style \p{}).

const std = @import("std");

pub const Category = enum(u8) {
    Lu,
    Ll,
    Lt,
    Lm,
    Lo,
    Mn,
    Mc,
    Me,
    Nd,
    Nl,
    No,
    Pc,
    Pd,
    Ps,
    Pe,
    Pi,
    Pf,
    Po,
    Sm,
    Sc,
    Sk,
    So,
    Zs,
    Zl,
    Zp,
    Cc,
    Cf,
    Cs,
    Co,
    Cn,
};

pub const Property = enum {
    L,
    Lu,
    Ll,
    Lt,
    Lm,
    Lo,
    M,
    Mn,
    Mc,
    Me,
    N,
    Nd,
    Nl,
    No,
    P,
    Pc,
    Pd,
    Ps,
    Pe,
    Pi,
    Pf,
    Po,
    S,
    Sm,
    Sc,
    Sk,
    So,
    Z,
    Zs,
    Zl,
    Zp,
    C,
    Cc,
    Cf,
    Cs,
    Co,
    Cn,
    alpha,
    alnum,
    ascii,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    word,
    xdigit,
};

pub const DecodeError = error{InvalidUtf8};

pub fn utf8ByteLen(first: u8) DecodeError!u3 {
    return std.unicode.utf8ByteSequenceLength(first) catch error.InvalidUtf8;
}

pub fn decodeAt(bytes: []const u8, index: usize) DecodeError!struct { cp: u21, len: u3 } {
    if (index >= bytes.len) return error.InvalidUtf8;
    const len = try utf8ByteLen(bytes[index]);
    if (index + len > bytes.len) return error.InvalidUtf8;
    const cp = std.unicode.utf8Decode(bytes[index..][0..len]) catch return error.InvalidUtf8;
    return .{ .cp = cp, .len = len };
}

pub fn decodeAtOrfffd(bytes: []const u8, index: usize) struct { cp: u21, len: u3 } {
    return decodeAt(bytes, index) catch .{ .cp = 0xfffd, .len = 1 };
}

pub fn nextCodepoint(bytes: []const u8, index: usize, utf: bool) ?struct { cp: u21, len: usize } {
    if (index >= bytes.len) return null;
    if (!utf) return .{ .cp = bytes[index], .len = 1 };
    const decoded = decodeAt(bytes, index) catch return .{ .cp = bytes[index], .len = 1 };
    return .{ .cp = decoded.cp, .len = decoded.len };
}

pub fn isAsciiNewline(cp: u21) bool {
    return cp == '\n' or cp == '\r';
}

pub fn isNewline(cp: u21) bool {
    return switch (cp) {
        '\n', '\r', 0x0b, 0x0c, 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

pub fn isCrlf(subject: []const u8, index: usize) bool {
    return index + 1 < subject.len and subject[index] == '\r' and subject[index + 1] == '\n';
}

pub fn isHorizontalSpace(cp: u21) bool {
    return switch (cp) {
        '\t', ' ', 0xa0, 0x1680, 0x180e => true,
        0x2000...0x200a => true,
        0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

pub fn isVerticalSpace(cp: u21) bool {
    return switch (cp) {
        0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

pub fn isAsciiWord(cp: u21) bool {
    return switch (cp) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

pub fn isUnicodeWord(cp: u21) bool {
    if (cp == '_') return true;
    return switch (generalCategory(cp)) {
        .Lu, .Ll, .Lt, .Lm, .Lo, .Mn, .Mc, .Me, .Nd, .Nl, .No, .Pc => true,
        else => false,
    };
}

pub fn isWord(cp: u21, ucp: bool) bool {
    return if (ucp) isUnicodeWord(cp) else isAsciiWord(cp);
}

pub fn isDigit(cp: u21, ucp: bool) bool {
    if (!ucp) return cp >= '0' and cp <= '9';
    return generalCategory(cp) == .Nd;
}

pub fn isSpace(cp: u21, ucp: bool) bool {
    if (!ucp) {
        return switch (cp) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
            else => false,
        };
    }
    if (isVerticalSpace(cp) or isHorizontalSpace(cp)) return true;
    return switch (generalCategory(cp)) {
        .Zs, .Zl, .Zp => true,
        else => false,
    };
}

pub fn asciiFold(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

pub fn simpleFold(cp: u21) u21 {
    const ascii = asciiFold(cp);
    if (ascii != cp) return ascii;
    return switch (cp) {
        'a'...'z' => cp - 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
        0xE0...0xF6, 0xF8...0xFE => cp - 0x20,
        0x0178 => 0x00FF,
        0x00FF => 0x0178,
        else => cp,
    };
}

pub fn equalFold(a: u21, b: u21, unicode: bool) bool {
    if (a == b) return true;
    if (!unicode) return asciiFold(a) == asciiFold(b);
    return simpleFold(a) == simpleFold(b) or asciiFold(a) == asciiFold(b);
}

pub fn parsePropertyName(name: []const u8) ?Property {
    if (std.meta.stringToEnum(Property, name)) |p| return p;
    if (name.len == 1) {
        return switch (name[0]) {
            'L' => .L,
            'M' => .M,
            'N' => .N,
            'P' => .P,
            'S' => .S,
            'Z' => .Z,
            'C' => .C,
            else => null,
        };
    }
    const aliased: []const struct { []const u8, Property } = &.{
        .{ "Letter", .L },
        .{ "Lowercase_Letter", .Ll },
        .{ "Uppercase_Letter", .Lu },
        .{ "Titlecase_Letter", .Lt },
        .{ "Modifier_Letter", .Lm },
        .{ "Other_Letter", .Lo },
        .{ "Mark", .M },
        .{ "Nonspacing_Mark", .Mn },
        .{ "Spacing_Mark", .Mc },
        .{ "Enclosing_Mark", .Me },
        .{ "Number", .N },
        .{ "Decimal_Number", .Nd },
        .{ "Letter_Number", .Nl },
        .{ "Other_Number", .No },
        .{ "Punctuation", .P },
        .{ "Connector_Punctuation", .Pc },
        .{ "Dash_Punctuation", .Pd },
        .{ "Open_Punctuation", .Ps },
        .{ "Close_Punctuation", .Pe },
        .{ "Initial_Punctuation", .Pi },
        .{ "Final_Punctuation", .Pf },
        .{ "Other_Punctuation", .Po },
        .{ "Symbol", .S },
        .{ "Math_Symbol", .Sm },
        .{ "Currency_Symbol", .Sc },
        .{ "Modifier_Symbol", .Sk },
        .{ "Other_Symbol", .So },
        .{ "Separator", .Z },
        .{ "Space_Separator", .Zs },
        .{ "Line_Separator", .Zl },
        .{ "Paragraph_Separator", .Zp },
        .{ "Other", .C },
        .{ "Control", .Cc },
        .{ "Format", .Cf },
        .{ "Surrogate", .Cs },
        .{ "Private_Use", .Co },
        .{ "Unassigned", .Cn },
        .{ "Alphabetic", .alpha },
        .{ "ASCII", .ascii },
        .{ "Blank", .blank },
        .{ "XDigit", .xdigit },
        .{ "White_Space", .space },
    };
    for (aliased) |pair| {
        if (std.ascii.eqlIgnoreCase(pair[0], name)) return pair[1];
    }
    return null;
}

pub fn hasProperty(cp: u21, prop: Property) bool {
    const cat = generalCategory(cp);
    return switch (prop) {
        .L => isLetterCat(cat),
        .Lu => cat == .Lu,
        .Ll => cat == .Ll,
        .Lt => cat == .Lt,
        .Lm => cat == .Lm,
        .Lo => cat == .Lo,
        .M => isMarkCat(cat),
        .Mn => cat == .Mn,
        .Mc => cat == .Mc,
        .Me => cat == .Me,
        .N => isNumberCat(cat),
        .Nd => cat == .Nd,
        .Nl => cat == .Nl,
        .No => cat == .No,
        .P => isPunctCat(cat),
        .Pc => cat == .Pc,
        .Pd => cat == .Pd,
        .Ps => cat == .Ps,
        .Pe => cat == .Pe,
        .Pi => cat == .Pi,
        .Pf => cat == .Pf,
        .Po => cat == .Po,
        .S => isSymbolCat(cat),
        .Sm => cat == .Sm,
        .Sc => cat == .Sc,
        .Sk => cat == .Sk,
        .So => cat == .So,
        .Z => isSepCat(cat),
        .Zs => cat == .Zs,
        .Zl => cat == .Zl,
        .Zp => cat == .Zp,
        .C => isOtherCat(cat),
        .Cc => cat == .Cc,
        .Cf => cat == .Cf,
        .Cs => cat == .Cs,
        .Co => cat == .Co,
        .Cn => cat == .Cn,
        .alpha => isLetterCat(cat),
        .alnum => isLetterCat(cat) or isNumberCat(cat),
        .ascii => cp <= 0x7f,
        .blank => cp == '\t' or cat == .Zs,
        .cntrl => cat == .Cc,
        .digit => cat == .Nd,
        .graph => !isSepCat(cat) and !isOtherCat(cat),
        .lower => cat == .Ll,
        .print => cat != .Cc and cat != .Cs and cat != .Cn,
        .punct => isPunctCat(cat),
        .space => isSpace(cp, true),
        .upper => cat == .Lu or cat == .Lt,
        .word => isUnicodeWord(cp),
        .xdigit => (cp >= '0' and cp <= '9') or
            (cp >= 'A' and cp <= 'F') or
            (cp >= 'a' and cp <= 'f'),
    };
}

fn isLetterCat(cat: Category) bool {
    return switch (cat) {
        .Lu, .Ll, .Lt, .Lm, .Lo => true,
        else => false,
    };
}

fn isMarkCat(cat: Category) bool {
    return switch (cat) {
        .Mn, .Mc, .Me => true,
        else => false,
    };
}

fn isNumberCat(cat: Category) bool {
    return switch (cat) {
        .Nd, .Nl, .No => true,
        else => false,
    };
}

fn isPunctCat(cat: Category) bool {
    return switch (cat) {
        .Pc, .Pd, .Ps, .Pe, .Pi, .Pf, .Po => true,
        else => false,
    };
}

fn isSymbolCat(cat: Category) bool {
    return switch (cat) {
        .Sm, .Sc, .Sk, .So => true,
        else => false,
    };
}

fn isSepCat(cat: Category) bool {
    return switch (cat) {
        .Zs, .Zl, .Zp => true,
        else => false,
    };
}

fn isOtherCat(cat: Category) bool {
    return switch (cat) {
        .Cc, .Cf, .Cs, .Co, .Cn => true,
        else => false,
    };
}

const Range = struct {
    start: u21,
    end: u21,
    cat: Category,
};

/// Compact BMP-oriented general-category ranges. Unlisted code points are Cn.
const ranges = [_]Range{
    .{ .start = 0x0000, .end = 0x001F, .cat = .Cc },
    .{ .start = 0x0020, .end = 0x0020, .cat = .Zs },
    .{ .start = 0x0021, .end = 0x0023, .cat = .Po },
    .{ .start = 0x0024, .end = 0x0024, .cat = .Sc },
    .{ .start = 0x0025, .end = 0x0027, .cat = .Po },
    .{ .start = 0x0028, .end = 0x0028, .cat = .Ps },
    .{ .start = 0x0029, .end = 0x0029, .cat = .Pe },
    .{ .start = 0x002A, .end = 0x002A, .cat = .Po },
    .{ .start = 0x002B, .end = 0x002B, .cat = .Sm },
    .{ .start = 0x002C, .end = 0x002C, .cat = .Po },
    .{ .start = 0x002D, .end = 0x002D, .cat = .Pd },
    .{ .start = 0x002E, .end = 0x002F, .cat = .Po },
    .{ .start = 0x0030, .end = 0x0039, .cat = .Nd },
    .{ .start = 0x003A, .end = 0x003B, .cat = .Po },
    .{ .start = 0x003C, .end = 0x003E, .cat = .Sm },
    .{ .start = 0x003F, .end = 0x0040, .cat = .Po },
    .{ .start = 0x0041, .end = 0x005A, .cat = .Lu },
    .{ .start = 0x005B, .end = 0x005B, .cat = .Ps },
    .{ .start = 0x005C, .end = 0x005C, .cat = .Po },
    .{ .start = 0x005D, .end = 0x005D, .cat = .Pe },
    .{ .start = 0x005E, .end = 0x005E, .cat = .Sk },
    .{ .start = 0x005F, .end = 0x005F, .cat = .Pc },
    .{ .start = 0x0060, .end = 0x0060, .cat = .Sk },
    .{ .start = 0x0061, .end = 0x007A, .cat = .Ll },
    .{ .start = 0x007B, .end = 0x007B, .cat = .Ps },
    .{ .start = 0x007C, .end = 0x007C, .cat = .Sm },
    .{ .start = 0x007D, .end = 0x007D, .cat = .Pe },
    .{ .start = 0x007E, .end = 0x007E, .cat = .Sm },
    .{ .start = 0x007F, .end = 0x009F, .cat = .Cc },
    .{ .start = 0x00A0, .end = 0x00A0, .cat = .Zs },
    .{ .start = 0x00A1, .end = 0x00A1, .cat = .Po },
    .{ .start = 0x00A2, .end = 0x00A5, .cat = .Sc },
    .{ .start = 0x00A6, .end = 0x00A7, .cat = .So },
    .{ .start = 0x00A8, .end = 0x00A8, .cat = .Sk },
    .{ .start = 0x00A9, .end = 0x00A9, .cat = .So },
    .{ .start = 0x00AA, .end = 0x00AA, .cat = .Lo },
    .{ .start = 0x00AB, .end = 0x00AB, .cat = .Pi },
    .{ .start = 0x00AC, .end = 0x00AC, .cat = .Sm },
    .{ .start = 0x00AD, .end = 0x00AD, .cat = .Cf },
    .{ .start = 0x00AE, .end = 0x00AE, .cat = .So },
    .{ .start = 0x00AF, .end = 0x00AF, .cat = .Sk },
    .{ .start = 0x00B0, .end = 0x00B0, .cat = .So },
    .{ .start = 0x00B1, .end = 0x00B1, .cat = .Sm },
    .{ .start = 0x00B2, .end = 0x00B3, .cat = .No },
    .{ .start = 0x00B4, .end = 0x00B4, .cat = .Sk },
    .{ .start = 0x00B5, .end = 0x00B5, .cat = .Ll },
    .{ .start = 0x00B6, .end = 0x00B7, .cat = .Po },
    .{ .start = 0x00B8, .end = 0x00B8, .cat = .Sk },
    .{ .start = 0x00B9, .end = 0x00B9, .cat = .No },
    .{ .start = 0x00BA, .end = 0x00BA, .cat = .Lo },
    .{ .start = 0x00BB, .end = 0x00BB, .cat = .Pf },
    .{ .start = 0x00BC, .end = 0x00BE, .cat = .No },
    .{ .start = 0x00BF, .end = 0x00BF, .cat = .Po },
    .{ .start = 0x00C0, .end = 0x00D6, .cat = .Lu },
    .{ .start = 0x00D7, .end = 0x00D7, .cat = .Sm },
    .{ .start = 0x00D8, .end = 0x00DE, .cat = .Lu },
    .{ .start = 0x00DF, .end = 0x00F6, .cat = .Ll },
    .{ .start = 0x00F7, .end = 0x00F7, .cat = .Sm },
    .{ .start = 0x00F8, .end = 0x00FF, .cat = .Ll },
    .{ .start = 0x0100, .end = 0x017F, .cat = .Lu }, // Latin Extended-A mixed; refined below
    .{ .start = 0x0180, .end = 0x024F, .cat = .Ll },
    .{ .start = 0x0250, .end = 0x02AF, .cat = .Ll },
    .{ .start = 0x02B0, .end = 0x02C1, .cat = .Lm },
    .{ .start = 0x02C6, .end = 0x02D1, .cat = .Lm },
    .{ .start = 0x02E0, .end = 0x02E4, .cat = .Lm },
    .{ .start = 0x0300, .end = 0x036F, .cat = .Mn },
    .{ .start = 0x0370, .end = 0x03FF, .cat = .Lu },
    .{ .start = 0x0400, .end = 0x04FF, .cat = .Lu },
    .{ .start = 0x0500, .end = 0x052F, .cat = .Lu },
    .{ .start = 0x0531, .end = 0x0556, .cat = .Lu },
    .{ .start = 0x0561, .end = 0x0587, .cat = .Ll },
    .{ .start = 0x0591, .end = 0x05BD, .cat = .Mn },
    .{ .start = 0x05D0, .end = 0x05EA, .cat = .Lo },
    .{ .start = 0x0600, .end = 0x0605, .cat = .Cf },
    .{ .start = 0x0620, .end = 0x064A, .cat = .Lo },
    .{ .start = 0x064B, .end = 0x065F, .cat = .Mn },
    .{ .start = 0x0660, .end = 0x0669, .cat = .Nd },
    .{ .start = 0x06F0, .end = 0x06F9, .cat = .Nd },
    .{ .start = 0x0900, .end = 0x0902, .cat = .Mn },
    .{ .start = 0x0903, .end = 0x0903, .cat = .Mc },
    .{ .start = 0x0904, .end = 0x0939, .cat = .Lo },
    .{ .start = 0x0966, .end = 0x096F, .cat = .Nd },
    .{ .start = 0x0E01, .end = 0x0E30, .cat = .Lo },
    .{ .start = 0x0E50, .end = 0x0E59, .cat = .Nd },
    .{ .start = 0x1100, .end = 0x11FF, .cat = .Lo },
    .{ .start = 0x2000, .end = 0x200A, .cat = .Zs },
    .{ .start = 0x200B, .end = 0x200F, .cat = .Cf },
    .{ .start = 0x2010, .end = 0x2015, .cat = .Pd },
    .{ .start = 0x2018, .end = 0x2018, .cat = .Pi },
    .{ .start = 0x2019, .end = 0x2019, .cat = .Pf },
    .{ .start = 0x201C, .end = 0x201C, .cat = .Pi },
    .{ .start = 0x201D, .end = 0x201D, .cat = .Pf },
    .{ .start = 0x2028, .end = 0x2028, .cat = .Zl },
    .{ .start = 0x2029, .end = 0x2029, .cat = .Zp },
    .{ .start = 0x202A, .end = 0x202E, .cat = .Cf },
    .{ .start = 0x202F, .end = 0x202F, .cat = .Zs },
    .{ .start = 0x2039, .end = 0x2039, .cat = .Pi },
    .{ .start = 0x203A, .end = 0x203A, .cat = .Pf },
    .{ .start = 0x205F, .end = 0x205F, .cat = .Zs },
    .{ .start = 0x2060, .end = 0x2064, .cat = .Cf },
    .{ .start = 0x20A0, .end = 0x20CF, .cat = .Sc },
    .{ .start = 0x2100, .end = 0x214F, .cat = .So },
    .{ .start = 0x2190, .end = 0x21FF, .cat = .Sm },
    .{ .start = 0x2200, .end = 0x22FF, .cat = .Sm },
    .{ .start = 0x3000, .end = 0x3000, .cat = .Zs },
    .{ .start = 0x3041, .end = 0x3096, .cat = .Lo },
    .{ .start = 0x30A1, .end = 0x30FA, .cat = .Lo },
    .{ .start = 0x3400, .end = 0x4DBF, .cat = .Lo },
    .{ .start = 0x4E00, .end = 0x9FFF, .cat = .Lo },
    .{ .start = 0xAC00, .end = 0xD7AF, .cat = .Lo },
    .{ .start = 0xD800, .end = 0xDFFF, .cat = .Cs },
    .{ .start = 0xE000, .end = 0xF8FF, .cat = .Co },
    .{ .start = 0xF900, .end = 0xFAFF, .cat = .Lo },
    .{ .start = 0xFE00, .end = 0xFE0F, .cat = .Mn },
    .{ .start = 0xFEFF, .end = 0xFEFF, .cat = .Cf },
    .{ .start = 0xFF10, .end = 0xFF19, .cat = .Nd },
    .{ .start = 0xFF21, .end = 0xFF3A, .cat = .Lu },
    .{ .start = 0xFF41, .end = 0xFF5A, .cat = .Ll },
    .{ .start = 0xFF70, .end = 0xFF9D, .cat = .Lo },
    .{ .start = 0x10000, .end = 0x10FFFF, .cat = .Lo },
};

fn latinExtendedA(cp: u21) Category {
    // Even code points in 0x0100-0x0177 are Lu, odd are Ll, with known exceptions.
    return switch (cp) {
        0x0138, 0x0149, 0x017F => .Ll,
        0x0178 => .Lu,
        else => if (cp >= 0x0100 and cp <= 0x0177)
            (if (cp % 2 == 0) Category.Lu else Category.Ll)
        else
            .Ll,
    };
}

pub fn generalCategory(cp: u21) Category {
    if (cp <= 0x7F) {
        return switch (cp) {
            0x00...0x1F, 0x7F => .Cc,
            0x20 => .Zs,
            '0'...'9' => .Nd,
            'A'...'Z' => .Lu,
            'a'...'z' => .Ll,
            '$' => .Sc,
            '+' => .Sm,
            '-' => .Pd,
            '<'...'>' => .Sm,
            '|' => .Sm,
            '~' => .Sm,
            '(' => .Ps,
            ')' => .Pe,
            '[' => .Ps,
            ']' => .Pe,
            '{' => .Ps,
            '}' => .Pe,
            '^', '`' => .Sk,
            '_' => .Pc,
            else => .Po,
        };
    }
    if (cp >= 0x0100 and cp <= 0x017F) return latinExtendedA(cp);
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return refineBlock(cp, r.cat);
        }
    }
    return .Cn;
}

fn refineBlock(cp: u21, cat: Category) Category {
    if (cp >= 0x0370 and cp <= 0x03FF) {
        return switch (cp) {
            0x03AC...0x03CE, 0x03D9, 0x03DB, 0x03DD, 0x03DF, 0x03E1, 0x03E3, 0x03E5, 0x03E7, 0x03E9, 0x03EB, 0x03ED, 0x03EF => .Ll,
            0x03F3 => .Ll,
            0x037A => .Lm,
            else => .Lu,
        };
    }
    if (cp >= 0x0400 and cp <= 0x04FF) {
        return switch (cp) {
            0x0430...0x045F => .Ll,
            0x04C2, 0x04C4, 0x04C6, 0x04C8, 0x04CA, 0x04CC, 0x04CE => .Ll,
            else => if (cp >= 0x0410 and cp <= 0x042F) .Lu else cat,
        };
    }
    return cat;
}

test "ascii categories" {
    try std.testing.expectEqual(Category.Lu, generalCategory('A'));
    try std.testing.expectEqual(Category.Ll, generalCategory('z'));
    try std.testing.expectEqual(Category.Nd, generalCategory('5'));
    try std.testing.expect(hasProperty('é', .L));
    try std.testing.expect(hasProperty('你', .Lo));
}
