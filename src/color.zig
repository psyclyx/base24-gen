//! Color space conversions and utilities.
//!
//! Pipeline: sRGB ↔ linear RGB ↔ OKLab ↔ OKLCh.
//!
//! OKLab (Björn Ottosson, 2020) is perceptually uniform with correct hue
//! linearity, making it ideal for palette generation. OKLCh is its cylindrical
//! form: L (lightness 0–1), C (chroma ≥ 0), h (hue degrees 0–360).

const std = @import("std");
const math = std.math;

/// sRGB color; components in [0, 1].
pub const Srgb = struct {
    r: f32,
    g: f32,
    b: f32,

    pub fn fromBytes(r: u8, g: u8, b: u8) Srgb {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
        };
    }

    pub fn toHex(self: Srgb) u24 {
        const r: u24 = @intFromFloat(@round(clamp01(self.r) * 255.0));
        const g: u24 = @intFromFloat(@round(clamp01(self.g) * 255.0));
        const b: u24 = @intFromFloat(@round(clamp01(self.b) * 255.0));
        return (r << 16) | (g << 8) | b;
    }

    /// Write 6-char lowercase hex (no '#') into buf.
    pub fn toHexStr(self: Srgb, buf: *[6]u8) void {
        const h = self.toHex();
        _ = std.fmt.bufPrint(buf, "{x:0>6}", .{h}) catch unreachable;
    }
};

/// Linear (physical) RGB; components nominally in [0, 1].
pub const Linear = struct {
    r: f32,
    g: f32,
    b: f32,
};

/// OKLab; L ∈ [0, 1], a/b ∈ [−0.5, 0.5] for typical colours.
pub const Lab = struct {
    L: f32,
    a: f32,
    b: f32,
};

/// OKLCh; L ∈ [0, 1], C ≥ 0, h ∈ [0, 360).
pub const Lch = struct {
    L: f32,
    C: f32,
    h: f32,

    pub fn init(L: f32, C: f32, h: f32) Lch {
        return .{ .L = L, .C = C, .h = @mod(h + 3600.0, 360.0) };
    }
};

// ─── sRGB ↔ linear RGB ────────────────────────────────────────────────────────

fn linearize(x: f32) f32 {
    return if (x <= 0.04045)
        x / 12.92
    else
        math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn delinearize(x: f32) f32 {
    const c = @max(0.0, x);
    return if (c <= 0.0031308)
        12.92 * c
    else
        1.055 * math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

pub fn srgbToLinear(c: Srgb) Linear {
    return .{ .r = linearize(c.r), .g = linearize(c.g), .b = linearize(c.b) };
}

pub fn linearToSrgb(c: Linear) Srgb {
    return .{ .r = delinearize(c.r), .g = delinearize(c.g), .b = delinearize(c.b) };
}

// ─── linear RGB ↔ OKLab ──────────────────────────────────────────────────────

pub fn linearToLab(c: Linear) Lab {
    const l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    const m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    const s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;

    const l_ = cbrt(l);
    const m_ = cbrt(m);
    const s_ = cbrt(s);

    return .{
        .L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        .a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        .b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    };
}

pub fn labToLinear(c: Lab) Linear {
    const l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b;
    const m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b;
    const s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    return .{
        .r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        .g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        .b = -0.0041960863 * l - 0.7034186147 * m + 1.6956082560 * s,
    };
}

// ─── OKLab ↔ OKLCh ───────────────────────────────────────────────────────────

pub fn labToLch(c: Lab) Lch {
    const C = @sqrt(c.a * c.a + c.b * c.b);
    const h = if (C < 1e-6) 0.0 else math.atan2(c.b, c.a) * (180.0 / math.pi);
    return .{ .L = c.L, .C = C, .h = @mod(h + 360.0, 360.0) };
}

pub fn lchToLab(c: Lch) Lab {
    const h_rad = c.h * (math.pi / 180.0);
    return .{ .L = c.L, .a = c.C * @cos(h_rad), .b = c.C * @sin(h_rad) };
}

// ─── Convenience round-trips ──────────────────────────────────────────────────

pub fn srgbToLch(c: Srgb) Lch {
    return labToLch(linearToLab(srgbToLinear(c)));
}

pub fn lchToSrgb(c: Lch) Srgb {
    return linearToSrgb(labToLinear(lchToLab(c)));
}

// ─── Gamut clipping ───────────────────────────────────────────────────────────

fn linearInGamut(c: Linear) bool {
    return c.r >= -1e-4 and c.r <= 1.0001 and
        c.g >= -1e-4 and c.g <= 1.0001 and
        c.b >= -1e-4 and c.b <= 1.0001;
}

/// Reduce chroma until all linear RGB components are in [0, 1].
/// Preserves L and h. Zero-chroma (grey) is always in gamut.
pub fn clipToGamut(c: Lch) Lch {
    if (linearInGamut(labToLinear(lchToLab(c)))) return c;

    var lo: f32 = 0.0;
    var hi: f32 = c.C;
    for (0..20) |_| {
        const mid = (lo + hi) / 2.0;
        const trial = Lch.init(c.L, mid, c.h);
        if (linearInGamut(labToLinear(lchToLab(trial)))) lo = mid else hi = mid;
    }
    return Lch.init(c.L, lo, c.h);
}

/// Maximum in-gamut chroma for a given L and h (binary search).
pub fn maxGamutChroma(L: f32, h: f32) f32 {
    var lo: f32 = 0.0;
    var hi: f32 = 0.5;
    for (0..20) |_| {
        const mid = (lo + hi) / 2.0;
        if (linearInGamut(labToLinear(lchToLab(Lch.init(L, mid, h))))) lo = mid else hi = mid;
    }
    return lo;
}

// ─── Contrast ─────────────────────────────────────────────────────────────────

/// WCAG relative luminance (linear combination of linearised RGB).
pub fn relativeLuminance(c: Srgb) f32 {
    const lin = srgbToLinear(c);
    return 0.2126 * lin.r + 0.7152 * lin.g + 0.0722 * lin.b;
}

/// WCAG 2.1 contrast ratio; always ≥ 1.
pub fn contrastRatio(a: Srgb, b: Srgb) f32 {
    const la = relativeLuminance(a) + 0.05;
    const lb = relativeLuminance(b) + 0.05;
    return if (la > lb) la / lb else lb / la;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn clamp01(x: f32) f32 {
    return @max(0.0, @min(1.0, x));
}

/// Signed cube root, safe for negative values.
fn cbrt(x: f32) f32 {
    if (x < 0.0) return -math.pow(f32, -x, 1.0 / 3.0);
    return math.pow(f32, x, 1.0 / 3.0);
}

/// Circular angular difference a − b, result in (−180, 180].
pub fn angularDiff(a: f32, b: f32) f32 {
    const d = @mod(a - b + 540.0, 360.0) - 180.0;
    return d;
}

/// Euclidean distance in OKLab (perceptual colour difference).
pub fn labDist(a: Lab, b: Lab) f32 {
    const dL = a.L - b.L;
    const da = a.a - b.a;
    const db = a.b - b.b;
    return @sqrt(dL * dL + da * da + db * db);
}

/// OKLab distance between two sRGB colours.
pub fn srgbDist(a: Srgb, b: Srgb) f32 {
    return labDist(linearToLab(srgbToLinear(a)), linearToLab(srgbToLinear(b)));
}

/// Linear interpolation.
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn saturate(x: f32) f32 {
    return clamp01(x);
}

// ─── CVD simulation (Viénot 1999) ────────────────────────────────────────────

/// Simulate protanopia (red-blind) on linear RGB.
pub fn simulateProtanopia(c: Linear) Linear {
    return .{
        .r = 0.152286 * c.r + 1.052583 * c.g - 0.204868 * c.b,
        .g = 0.114503 * c.r + 0.786281 * c.g + 0.099216 * c.b,
        .b = -0.003882 * c.r - 0.048116 * c.g + 1.051998 * c.b,
    };
}

/// Simulate deuteranopia (green-blind) on linear RGB.
pub fn simulateDeuteranopia(c: Linear) Linear {
    return .{
        .r = 0.367322 * c.r + 0.860646 * c.g - 0.227968 * c.b,
        .g = 0.280085 * c.r + 0.672501 * c.g + 0.047413 * c.b,
        .b = -0.011820 * c.r + 0.042940 * c.g + 0.968881 * c.b,
    };
}

/// OKLab distance between two sRGB colours under CVD simulation.
pub fn cvdDist(a: Srgb, b: Srgb, comptime cvd: enum { protan, deutan }) f32 {
    const sim = if (cvd == .protan) simulateProtanopia else simulateDeuteranopia;
    const lab_a = linearToLab(sim(srgbToLinear(a)));
    const lab_b = linearToLab(sim(srgbToLinear(b)));
    return labDist(lab_a, lab_b);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "sRGB round-trip through OKLCh" {
    const testing = std.testing;
    const cases = [_]Srgb{
        .{ .r = 1, .g = 0, .b = 0 }, // red
        .{ .r = 0, .g = 1, .b = 0 }, // green
        .{ .r = 0, .g = 0, .b = 1 }, // blue
        .{ .r = 1, .g = 1, .b = 0 }, // yellow
        .{ .r = 0, .g = 0, .b = 0 }, // black
        .{ .r = 1, .g = 1, .b = 1 }, // white
        .{ .r = 0.5, .g = 0.3, .b = 0.7 },
    };
    for (cases) |original| {
        const lch = srgbToLch(original);
        const back = lchToSrgb(lch);
        try testing.expectApproxEqAbs(original.r, back.r, 1e-2);
        try testing.expectApproxEqAbs(original.g, back.g, 1e-2);
        try testing.expectApproxEqAbs(original.b, back.b, 1e-2);
    }
}

test "gamut clip produces in-gamut colours" {
    const testing = std.testing;
    const cases = [_]Lch{
        Lch.init(0.5, 0.5, 30.0),
        Lch.init(0.7, 0.4, 145.0),
        Lch.init(0.3, 0.6, 265.0),
        Lch.init(0.5, 0.0, 0.0), // grey, already in gamut
    };
    for (cases) |lch| {
        const clipped = clipToGamut(lch);
        const rgb = lchToSrgb(clipped);
        try testing.expect(rgb.r >= -1e-3 and rgb.r <= 1.001);
        try testing.expect(rgb.g >= -1e-3 and rgb.g <= 1.001);
        try testing.expect(rgb.b >= -1e-3 and rgb.b <= 1.001);
        try testing.expectApproxEqAbs(lch.L, clipped.L, 1e-6);
        try testing.expectApproxEqAbs(lch.h, clipped.h, 1e-6);
        try testing.expect(clipped.C <= lch.C + 1e-6);
    }
}

test "contrast ratio: white on black is 21" {
    const testing = std.testing;
    const white = Srgb{ .r = 1, .g = 1, .b = 1 };
    const black = Srgb{ .r = 0, .g = 0, .b = 0 };
    try testing.expectApproxEqAbs(21.0, contrastRatio(white, black), 0.01);
}

test "OKLCh hue angles for canonical colours" {
    const testing = std.testing;
    const red_lch = srgbToLch(.{ .r = 1, .g = 0, .b = 0 });
    try testing.expect(red_lch.h > 20.0 and red_lch.h < 40.0);
    const green_lch = srgbToLch(.{ .r = 0, .g = 1, .b = 0 });
    try testing.expect(green_lch.h > 130.0 and green_lch.h < 160.0);
    const blue_lch = srgbToLch(.{ .r = 0, .g = 0, .b = 1 });
    try testing.expect(blue_lch.h > 250.0 and blue_lch.h < 280.0);
}

test "gamut clip reduces chroma for out-of-gamut orange" {
    const testing = std.testing;
    const orange = Lch.init(0.65, 0.30, 58.0);
    const clipped = clipToGamut(orange);
    try testing.expect(clipped.C < orange.C);
    try testing.expect(@abs(angularDiff(clipped.h, orange.h)) < 2.0);
}

test "maxGamutChroma returns positive values" {
    const testing = std.testing;
    const cases = [_]struct { L: f32, h: f32 }{
        .{ .L = 0.65, .h = 27.0 }, // red
        .{ .L = 0.65, .h = 58.0 }, // orange
        .{ .L = 0.75, .h = 110.0 }, // yellow
        .{ .L = 0.65, .h = 145.0 }, // green
        .{ .L = 0.65, .h = 195.0 }, // cyan
        .{ .L = 0.55, .h = 265.0 }, // blue
        .{ .L = 0.65, .h = 328.0 }, // purple
    };
    for (cases) |c| {
        const max_c = maxGamutChroma(c.L, c.h);
        try testing.expect(max_c > 0.01);
    }
}

test "OKLab distance: identical colours have zero distance" {
    const testing = std.testing;
    const red = Srgb{ .r = 1, .g = 0, .b = 0 };
    try testing.expectApproxEqAbs(0.0, srgbDist(red, red), 1e-6);
    const green = Srgb{ .r = 0, .g = 1, .b = 0 };
    try testing.expect(srgbDist(red, green) > 0.2);
    const almost_red = Srgb{ .r = 0.95, .g = 0.05, .b = 0 };
    try testing.expect(srgbDist(red, almost_red) < 0.05);
}

test "CVD simulation: red and green collapse under deuteranopia" {
    const testing = std.testing;
    const red = Srgb{ .r = 0.8, .g = 0.2, .b = 0.1 };
    const green = Srgb{ .r = 0.2, .g = 0.7, .b = 0.2 };
    try testing.expect(srgbDist(red, green) > 0.15);
    try testing.expect(cvdDist(red, green, .deutan) < srgbDist(red, green));
}

test "angularDiff wraps correctly" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(10.0, angularDiff(370.0, 0.0), 1e-4);
    try testing.expectApproxEqAbs(-10.0, angularDiff(350.0, 0.0), 1e-4);
    try testing.expectApproxEqAbs(180.0, @abs(angularDiff(180.0, 0.0)), 1e-4);
    try testing.expectApproxEqAbs(30.0, angularDiff(90.0, 60.0), 1e-4);
    try testing.expectApproxEqAbs(-30.0, angularDiff(30.0, 60.0), 1e-4);
}
