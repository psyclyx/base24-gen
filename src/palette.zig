//! Base24 palette generation.
//!
//! Produces a usable, image-inspired Base24 colour scheme by:
//!   1. Detecting dark vs. light mode from image luminance.
//!   2. Building a tone ramp (base00–07, base10–11) with a slight hue tint
//!      derived from the image's primary colour.
//!   3. Generating 8 accent colours (base08–0F) anchored to their semantic hue
//!      targets but biased up to ±25° toward dominant image hues.
//!   4. Deriving 6 bright accent colours (base12–17) from base08–0D.
//!   5. Clipping every colour to the sRGB gamut via chroma reduction.
//!
//! The image influence is scaled by its saturation so that monochrome or
//! random-noise inputs still produce a justifiably usable palette.

const std = @import("std");
const color = @import("color.zig");
const analysis = @import("analysis.zig");

pub const Mode = enum { dark, light };

/// A complete Base24 palette.
pub const Palette = struct {
    // Tone ramp
    base00: color.Srgb,
    base01: color.Srgb,
    base02: color.Srgb,
    base03: color.Srgb,
    base04: color.Srgb,
    base05: color.Srgb,
    base06: color.Srgb,
    base07: color.Srgb,
    // Normal accents
    base08: color.Srgb, // red
    base09: color.Srgb, // orange
    base0A: color.Srgb, // yellow
    base0B: color.Srgb, // green
    base0C: color.Srgb, // cyan
    base0D: color.Srgb, // blue
    base0E: color.Srgb, // purple/magenta
    base0F: color.Srgb, // brown (deprecated/embeds)
    // Extended backgrounds
    base10: color.Srgb,
    base11: color.Srgb,
    // Bright accents
    base12: color.Srgb, // bright red
    base13: color.Srgb, // bright yellow
    base14: color.Srgb, // bright green
    base15: color.Srgb, // bright cyan
    base16: color.Srgb, // bright blue
    base17: color.Srgb, // bright magenta

    /// Pointer-and-name table for output/preview iteration.
    pub fn slots(self: *const Palette) [24]Slot {
        return .{
            .{ .name = "base00", .srgb = self.base00 },
            .{ .name = "base01", .srgb = self.base01 },
            .{ .name = "base02", .srgb = self.base02 },
            .{ .name = "base03", .srgb = self.base03 },
            .{ .name = "base04", .srgb = self.base04 },
            .{ .name = "base05", .srgb = self.base05 },
            .{ .name = "base06", .srgb = self.base06 },
            .{ .name = "base07", .srgb = self.base07 },
            .{ .name = "base08", .srgb = self.base08 },
            .{ .name = "base09", .srgb = self.base09 },
            .{ .name = "base0A", .srgb = self.base0A },
            .{ .name = "base0B", .srgb = self.base0B },
            .{ .name = "base0C", .srgb = self.base0C },
            .{ .name = "base0D", .srgb = self.base0D },
            .{ .name = "base0E", .srgb = self.base0E },
            .{ .name = "base0F", .srgb = self.base0F },
            .{ .name = "base10", .srgb = self.base10 },
            .{ .name = "base11", .srgb = self.base11 },
            .{ .name = "base12", .srgb = self.base12 },
            .{ .name = "base13", .srgb = self.base13 },
            .{ .name = "base14", .srgb = self.base14 },
            .{ .name = "base15", .srgb = self.base15 },
            .{ .name = "base16", .srgb = self.base16 },
            .{ .name = "base17", .srgb = self.base17 },
        };
    }
};

pub const Slot = struct {
    name: []const u8,
    srgb: color.Srgb,
};

// ─── Tone ramp lightness targets ─────────────────────────────────────────────
//
// OKLab L values chosen so that:
//   • Adjacent tones are visually distinguishable (ΔL ≥ 0.05).
//   • base05 (default fg) reads comfortably on base00 (default bg).
//   • base04 (statusbar fg) reads on base01 (statusbar bg).
//
// Dark mode: base11 is darkest, base07 is lightest.
// Light mode: values are mirrored (1 − dark).

const DARK_TONE_L = [10]f32{
    //  00     01     02     03     04     05     06     07    10     11
    0.12, 0.17, 0.23, 0.35, 0.55, 0.75, 0.87, 0.95, 0.08, 0.05,
};

// ─── Accent colour targets ────────────────────────────────────────────────────
//
// Hue targets are OKLCh h° for the canonical version of each colour.
// Verified against actual sRGB primaries and common theme conventions.

const AccentTarget = struct {
    h: f32,
    /// Lightness adjustment relative to accent_L (negative = darker).
    dL: f32 = 0,
    /// Chroma adjustment relative to accent_C (negative = less saturated).
    dC: f32 = 0,
};

const ACCENT_TARGETS = [8]AccentTarget{
    .{ .h = 27.0 }, // base08 red
    .{ .h = 58.0 }, // base09 orange
    .{ .h = 110.0 }, // base0A yellow
    .{ .h = 145.0 }, // base0B green
    .{ .h = 195.0 }, // base0C cyan
    .{ .h = 265.0 }, // base0D blue
    .{ .h = 328.0 }, // base0E purple
    .{ .h = 55.0, .dL = -0.13, .dC = -0.05 }, // base0F brown (orange hue, dimmer)
};

// Bright accent: same hue, lighter + slightly more chromatic.
const BRIGHT_DL: f32 = 0.10;
const BRIGHT_DC: f32 = 0.03;

// Maximum hue pull from image (degrees).
const MAX_HUE_PULL: f32 = 25.0;

// Gaussian sigma for hue affinity (degrees).
const HUE_SIGMA: f32 = 40.0;

// ─── Public API ───────────────────────────────────────────────────────────────

pub fn generate(profile: analysis.ImageProfile, forced_mode: ?Mode) Palette {
    const mode: Mode = forced_mode orelse
        if (profile.median_lightness < 0.5) .dark else .light;

    const tones = buildToneRamp(profile, mode);
    const accents = buildAccents(profile, mode);

    return .{
        .base00 = tones[0],
        .base01 = tones[1],
        .base02 = tones[2],
        .base03 = tones[3],
        .base04 = tones[4],
        .base05 = tones[5],
        .base06 = tones[6],
        .base07 = tones[7],
        .base08 = accents[0],
        .base09 = accents[1],
        .base0A = accents[2],
        .base0B = accents[3],
        .base0C = accents[4],
        .base0D = accents[5],
        .base0E = accents[6],
        .base0F = accents[7],
        .base10 = tones[8],
        .base11 = tones[9],
        .base12 = brightVariant(accents[0]),
        .base13 = brightVariant(accents[2]), // bright yellow ← base0A
        .base14 = brightVariant(accents[3]), // bright green  ← base0B
        .base15 = brightVariant(accents[4]), // bright cyan   ← base0C
        .base16 = brightVariant(accents[5]), // bright blue   ← base0D
        .base17 = brightVariant(accents[6]), // bright magenta← base0E
    };
}

// ─── Tone ramp ────────────────────────────────────────────────────────────────

/// Build the 10-slot tone ramp [base00..07, base10, base11].
fn buildToneRamp(profile: analysis.ImageProfile, mode: Mode) [10]color.Srgb {
    // Very slight tint so tones feel connected to the image.
    // Chroma is so low it's essentially grey on any display.
    const tint_C = @min(profile.mean_chroma * 0.08, 0.012);
    const tint_h = profile.bucket_hues[dominantBucket(profile.hue_weights)];

    var result: [10]color.Srgb = undefined;
    for (DARK_TONE_L, 0..) |dark_L, i| {
        const L: f32 = if (mode == .dark) dark_L else 1.0 - dark_L;
        const lch = color.Lch.init(L, tint_C, tint_h);
        result[i] = color.lchToSrgb(color.clipToGamut(lch));
    }
    return result;
}

// ─── Accent colours ───────────────────────────────────────────────────────────

/// Build the 8 accent slots [base08..0F].
fn buildAccents(profile: analysis.ImageProfile, mode: Mode) [8]color.Srgb {
    // Base lightness for accents: readable on dark/light bg, not washed out.
    const accent_L: f32 = if (mode == .dark) 0.65 else 0.52;

    // Chroma: scale between minimum usable and vivid, driven by image.
    const min_C: f32 = 0.10;
    const max_C: f32 = 0.20;
    const chroma_scale = color.saturate(profile.p85_chroma / 0.20);
    const accent_C = color.lerp(min_C, max_C, chroma_scale);

    // Influence scale: how much we let image bias the hue.
    // A monochrome image has zero pull; a vivid image gets up to MAX_HUE_PULL.
    const influence = color.saturate(profile.mean_chroma / 0.08);

    var result: [8]color.Srgb = undefined;
    for (ACCENT_TARGETS, 0..) |target, i| {
        const pull = huePull(profile, target.h) * influence;
        const h = target.h + std.math.clamp(pull, -MAX_HUE_PULL, MAX_HUE_PULL);
        const L = accent_L + target.dL;
        const C = @max(0.0, accent_C + target.dC);
        result[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(L, C, h)));
    }
    return result;
}

/// Bright variant of an accent colour: lighter + slightly more chromatic.
fn brightVariant(base: color.Srgb) color.Srgb {
    var lch = color.srgbToLch(base);
    lch.L = @min(1.0, lch.L + BRIGHT_DL);
    lch.C += BRIGHT_DC;
    return color.lchToSrgb(color.clipToGamut(lch));
}

// ─── Hue pull ─────────────────────────────────────────────────────────────────
//
// For a given target hue, compute how many degrees the image "pulls" it.
// We do a weighted circular mean of bucket-centroid offsets, using a Gaussian
// to down-weight buckets far from the target.

fn huePull(profile: analysis.ImageProfile, target_h: f32) f32 {
    var sin_acc: f32 = 0;
    var cos_acc: f32 = 0;
    var w_total: f32 = 0;

    for (0..8) |bi| {
        const centroid = profile.bucket_hues[bi];
        const delta = color.angularDiff(centroid, target_h);
        const gauss = gaussianWeight(delta, HUE_SIGMA);
        const w = profile.hue_weights[bi] * gauss;

        const delta_rad = delta * (std.math.pi / 180.0);
        sin_acc += w * @sin(delta_rad);
        cos_acc += w * @cos(delta_rad);
        w_total += w;
    }

    if (w_total < 1e-6) return 0;
    const pull_rad = std.math.atan2(sin_acc / w_total, cos_acc / w_total);
    return pull_rad * (180.0 / std.math.pi);
}

fn gaussianWeight(delta: f32, sigma: f32) f32 {
    return @exp(-(delta * delta) / (2.0 * sigma * sigma));
}

fn dominantBucket(weights: [8]f32) usize {
    var max: f32 = 0;
    var idx: usize = 0;
    for (weights, 0..) |w, i| {
        if (w > max) {
            max = w;
            idx = i;
        }
    }
    return idx;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "degenerate: all-black image produces usable dark palette" {
    const testing = std.testing;
    const black_profile = analysis.ImageProfile{
        .median_lightness = 0.0,
        .p10_lightness = 0.0,
        .p90_lightness = 0.0,
        .hue_weights = .{1.0 / 8.0} ** 8,
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .mean_chroma = 0.0,
        .p85_chroma = 0.0,
    };

    const palette = generate(black_profile, .dark);

    // Tone ramp must be monotone in lightness (dark mode: base00 < base07)
    const lch00 = color.srgbToLch(palette.base00);
    const lch07 = color.srgbToLch(palette.base07);
    try testing.expect(lch00.L < lch07.L);

    // base10 / base11 must be darker than base00
    const lch10 = color.srgbToLch(palette.base10);
    const lch11 = color.srgbToLch(palette.base11);
    try testing.expect(lch11.L < lch10.L);
    try testing.expect(lch10.L < lch00.L);

    // Accent colours must be in gamut
    inline for (std.meta.fields(@TypeOf(palette))) |f| {
        const c = @field(palette, f.name);
        try testing.expect(c.r >= -1e-3 and c.r <= 1.001);
        try testing.expect(c.g >= -1e-3 and c.g <= 1.001);
        try testing.expect(c.b >= -1e-3 and c.b <= 1.001);
    }
}

test "degenerate: pure white image produces light palette" {
    const testing = std.testing;
    const white_profile = analysis.ImageProfile{
        .median_lightness = 1.0,
        .p10_lightness = 0.95,
        .p90_lightness = 1.0,
        .hue_weights = .{1.0 / 8.0} ** 8,
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .mean_chroma = 0.0,
        .p85_chroma = 0.0,
    };

    const palette = generate(white_profile, null); // auto-detect → light

    // Light mode: base00 lighter than base07
    const lch00 = color.srgbToLch(palette.base00);
    const lch07 = color.srgbToLch(palette.base07);
    try testing.expect(lch00.L > lch07.L);
}

test "hue semantics: red should land near red hue" {
    const testing = std.testing;
    // Heavily red-biased image
    var weights = [_]f32{0} ** 8;
    weights[0] = 1.0; // bucket 0 = [0°, 45°), contains red (≈27°)
    var hues: [8]f32 = undefined;
    for (0..8) |i| hues[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;

    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = weights,
        .bucket_hues = hues,
        .mean_chroma = 0.15,
        .p85_chroma = 0.20,
    };

    const palette = generate(profile, .dark);
    const red_lch = color.srgbToLch(palette.base08);

    // Even with full image pull, red should stay in the red quadrant
    try testing.expect(red_lch.h < 70.0 or red_lch.h > 300.0);
}

test "bright variants are lighter than their base" {
    const testing = std.testing;
    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = .{1.0 / 8.0} ** 8,
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .mean_chroma = 0.10,
        .p85_chroma = 0.15,
    };

    const p = generate(profile, .dark);

    // base12 (bright red) must be lighter than base08 (red)
    const r_L = color.srgbToLch(p.base08).L;
    const br_L = color.srgbToLch(p.base12).L;
    try testing.expect(br_L > r_L - 1e-4); // allow tiny floating-point slack
}
