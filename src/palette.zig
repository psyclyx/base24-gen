//! Base24 palette generation.
//!
//! Produces a usable, image-inspired Base24 colour scheme by:
//!   1. Detecting dark vs. light mode from image luminance.
//!   2. Building a tone ramp (base00–07, base10–11) with a slight hue tint
//!      derived from the image's primary colour.
//!   3. Generating 8 accent colours (base08–0F) using image-first hue
//!      assignment: dominant image hues are extracted as peaks, greedily
//!      assigned to nearby accent slots, and rendered at boosted chroma.
//!      Unassigned slots keep their canonical hue at a moderate floor chroma.
//!   4. Deriving 6 bright accent colours (base12–17) from base08–0D.
//!   5. Clipping every colour to the sRGB gamut via chroma reduction.
//!
//! Accents are contrast-checked against base00, base01, and base02 to ensure
//! readability on both default and selection-highlight backgrounds.

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

// Chroma range for accents.
// MIN_ACCENT_C: floor for assigned accents (lerp base), ensures visibility.
// UNASSIGNED_ACCENT_C: chroma for accents with no matching image peak —
// identifiable by hue but clearly muted relative to image-derived accents.
// MAX_ACCENT_C: ceiling for the most dominant image hues.
const MIN_ACCENT_C: f32 = 0.10;
const UNASSIGNED_ACCENT_C: f32 = 0.05;
const MAX_ACCENT_C: f32 = 0.32;

// Image saturation reference for overall chroma scaling.
// Images with p85_chroma ≥ this get fully vivid dominant accents.
const CHROMA_SCALE_REF: f32 = 0.12;

// ─── Peak extraction / assignment constants ──────────────────────────────────

/// Fine bins with weight > SIGNIFICANCE_FACTOR / FINE_BINS are "significant".
const SIGNIFICANCE_FACTOR: f32 = 1.5;
/// Maximum angular distance (degrees) for a peak to claim an accent slot.
const MAX_ASSIGNMENT_DISTANCE: f32 = 45.0;
/// Maximum number of peaks to extract from the fine histogram.
const MAX_PEAKS: usize = 8;
/// Minimum contrast ratio for accents against base02 (selection highlight).
const MIN_ACCENT_CONTRAST_BG2: f32 = 2.5;

// ─── Public API ───────────────────────────────────────────────────────────────

pub fn generate(profile: analysis.ImageProfile, forced_mode: ?Mode) Palette {
    const mode: Mode = forced_mode orelse
        if (profile.median_lightness < 0.5) .dark else .light;

    const tones = buildToneRamp(profile, mode);
    const accents = buildAccents(profile, mode, tones);
    const bg = [3]color.Srgb{ tones[0], tones[1], tones[2] };

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
        .base12 = brightVariant(accents[0], bg),
        .base13 = brightVariant(accents[2], bg), // bright yellow ← base0A
        .base14 = brightVariant(accents[3], bg), // bright green  ← base0B
        .base15 = brightVariant(accents[4], bg), // bright cyan   ← base0C
        .base16 = brightVariant(accents[5], bg), // bright blue   ← base0D
        .base17 = brightVariant(accents[6], bg), // bright magenta← base0E
    };
}

// ─── Tone ramp ────────────────────────────────────────────────────────────────

/// Contrast pairs that must be satisfied across the tone ramp.
/// Indices refer to DARK_TONE_L positions (0=base00 .. 7=base07, 8=base10, 9=base11).
///
/// Thresholds are set to values the tone ramp can actually achieve. OKLab L maps
/// to WCAG relative luminance via Y ≈ L³, so perceptually reasonable L spacing
/// doesn't guarantee high WCAG ratios for close pairs (e.g. base03/base00 at
/// L=0.35/0.12 gives only ~1.8:1 — intentionally low-contrast for comments).
const ContrastPair = struct { fg: usize, bg: usize, min_ratio: f32 };
const TONE_CONTRAST_PAIRS = [_]ContrastPair{
    .{ .fg = 5, .bg = 0, .min_ratio = 7.0 }, // base05 on base00 (primary text, AAA)
    .{ .fg = 7, .bg = 0, .min_ratio = 7.0 }, // base07 on base00 (bright fg, AAA)
    .{ .fg = 5, .bg = 2, .min_ratio = 4.5 }, // base05 on base02 (text on selection, AA)
    .{ .fg = 4, .bg = 1, .min_ratio = 3.0 }, // base04 on base01 (status bar, AA-large)
};

/// Build the 10-slot tone ramp with contrast-optimized tinting.
///
/// Binary-searches for the highest tint chroma where all required tone-pair
/// contrast ratios hold. The ceiling is driven by the image's vivid pixels
/// (p85_chroma) so that colorful images produce visibly tinted backgrounds.
fn buildToneRamp(profile: analysis.ImageProfile, mode: Mode) [10]color.Srgb {
    const tint_h = profile.bucket_hues[dominantBucket(profile.hue_weights)];

    // Ceiling from the vivid portion of the image (p85 captures the color
    // character better than mean, which is diluted by near-grey pixels).
    const tint_C_max = @min(@max(profile.mean_chroma * 0.5, profile.p85_chroma * 0.35), 0.06);

    // Binary search for the highest chroma that satisfies all contrast pairs
    var lo: f32 = 0.0;
    var hi: f32 = tint_C_max;
    for (0..20) |_| {
        const mid = (lo + hi) / 2.0;
        if (toneRampSatisfiesContrast(mid, tint_h, mode)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    const tint_C = lo;

    var result: [10]color.Srgb = undefined;
    for (DARK_TONE_L, 0..) |dark_L, i| {
        const L: f32 = if (mode == .dark) dark_L else 1.0 - dark_L;
        const lch = color.Lch.init(L, tint_C, tint_h);
        result[i] = color.lchToSrgb(color.clipToGamut(lch));
    }
    return result;
}

/// Check whether a given tint chroma satisfies all required contrast pairs.
fn toneRampSatisfiesContrast(tint_C: f32, tint_h: f32, mode: Mode) bool {
    // Build temporary sRGB tones at the candidate chroma
    var tones: [10]color.Srgb = undefined;
    for (DARK_TONE_L, 0..) |dark_L, i| {
        const L: f32 = if (mode == .dark) dark_L else 1.0 - dark_L;
        const lch = color.Lch.init(L, tint_C, tint_h);
        tones[i] = color.lchToSrgb(color.clipToGamut(lch));
    }
    for (TONE_CONTRAST_PAIRS) |pair| {
        if (color.contrastRatio(tones[pair.fg], tones[pair.bg]) < pair.min_ratio)
            return false;
    }
    return true;
}

// ─── Accent colours ───────────────────────────────────────────────────────────

// Accent contrast: minimum ratio against background tones.
// 3:1 is WCAG AA for large text / UI components — accents are used for
// syntax highlighting keywords, not body text.
const MIN_ACCENT_CONTRAST: f32 = 3.0;

/// A hue peak extracted from the fine histogram.
const Peak = struct {
    hue: f32, // circular weighted mean centroid
    weight: f32, // summed weight of merged bins
};

/// Build the 8 accent slots [base08..0F] using image-first hue assignment.
///
/// Three-stage pipeline:
///   1. Extract dominant hue peaks from the 36-bin fine histogram.
///   2. Greedily assign peaks to accent slots by angular proximity.
///   3. Generate accents: assigned slots get image hue at boosted chroma,
///      unassigned slots keep canonical hue at MIN_ACCENT_C.
fn buildAccents(profile: analysis.ImageProfile, mode: Mode, tones: [10]color.Srgb) [8]color.Srgb {
    const accent_L_target: f32 = if (mode == .dark) 0.65 else 0.52;
    const L_lo: f32 = if (mode == .dark) 0.45 else 0.30;
    const L_hi: f32 = if (mode == .dark) 0.85 else 0.70;

    const base00 = tones[0];
    const base01 = tones[1];
    const base02 = tones[2];

    // Overall image saturation ceiling
    const overall_scale = color.saturate(profile.p85_chroma / CHROMA_SCALE_REF);
    const C_ceiling = color.lerp(MIN_ACCENT_C, MAX_ACCENT_C, overall_scale);

    // Stage 1: extract peaks from fine histogram
    var peaks: [MAX_PEAKS]Peak = undefined;
    const n_peaks = extractPeaks(profile, &peaks);

    // Find max peak weight for chroma scaling
    var max_peak_weight: f32 = 0;
    for (peaks[0..n_peaks]) |p| {
        if (p.weight > max_peak_weight) max_peak_weight = p.weight;
    }

    // Stage 2: assign peaks to accent slots
    const assignments = assignPeaks(peaks[0..n_peaks]);

    // Stage 3: generate accents
    var result: [8]color.Srgb = undefined;
    for (ACCENT_TARGETS, 0..) |target, i| {
        var h: f32 = undefined;
        var C: f32 = undefined;

        if (assignments[i]) |peak_idx| {
            // Assigned: use image peak hue at boosted chroma
            h = peaks[peak_idx].hue;
            const weight_ratio = if (max_peak_weight > 1e-6)
                peaks[peak_idx].weight / max_peak_weight
            else
                0.0;
            C = color.lerp(MIN_ACCENT_C, C_ceiling, @sqrt(weight_ratio));
        } else {
            // Unassigned: canonical hue at muted chroma
            h = target.h;
            C = UNASSIGNED_ACCENT_C;
        }

        C = @max(0.0, C + target.dC);

        const L_target = accent_L_target + target.dL;
        const L = optimizeAccentL(L_target, L_lo, L_hi, C, h, base00, base01, base02, mode);

        result[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(L, C, h)));
    }
    return result;
}

/// Extract dominant hue peaks from the 36-bin fine histogram.
/// Merges adjacent significant bins into clusters. Returns count of peaks written.
fn extractPeaks(profile: analysis.ImageProfile, out: *[MAX_PEAKS]Peak) usize {
    const FINE_BINS = analysis.FINE_BINS;
    const threshold: f32 = SIGNIFICANCE_FACTOR / @as(f32, @floatFromInt(FINE_BINS));

    // Mark significant bins
    var significant: [FINE_BINS]bool = undefined;
    for (0..FINE_BINS) |bi| {
        significant[bi] = profile.fine_hue_weights[bi] > threshold;
    }

    // Walk circularly, merge adjacent significant bins into clusters
    var n_peaks: usize = 0;

    // Find first non-significant bin to start (avoid splitting a cluster that wraps)
    var start: usize = 0;
    var found_start = false;
    for (0..FINE_BINS) |bi| {
        if (!significant[bi]) {
            start = (bi + 1) % FINE_BINS;
            found_start = true;
            break;
        }
    }

    if (!found_start) {
        // Every bin is significant — entire histogram is one giant cluster
        var sin_acc: f64 = 0;
        var cos_acc: f64 = 0;
        var w_sum: f32 = 0;
        for (0..FINE_BINS) |bi| {
            const w: f64 = profile.fine_hue_weights[bi];
            const h_rad: f64 = profile.fine_hue_centroids[bi] * (std.math.pi / 180.0);
            sin_acc += w * @sin(h_rad);
            cos_acc += w * @cos(h_rad);
            w_sum += profile.fine_hue_weights[bi];
        }
        const angle = std.math.atan2(sin_acc, cos_acc) * (180.0 / std.math.pi);
        out[0] = .{
            .hue = @floatCast(@mod(angle + 360.0, 360.0)),
            .weight = w_sum,
        };
        return 1;
    }

    var bi: usize = start;
    var visited: usize = 0;
    while (visited < FINE_BINS) {
        if (!significant[bi]) {
            bi = (bi + 1) % FINE_BINS;
            visited += 1;
            continue;
        }

        // Start of a cluster
        var sin_acc: f64 = 0;
        var cos_acc: f64 = 0;
        var w_sum: f32 = 0;
        while (visited < FINE_BINS and significant[bi]) {
            const w: f64 = profile.fine_hue_weights[bi];
            const h_rad: f64 = profile.fine_hue_centroids[bi] * (std.math.pi / 180.0);
            sin_acc += w * @sin(h_rad);
            cos_acc += w * @cos(h_rad);
            w_sum += profile.fine_hue_weights[bi];
            bi = (bi + 1) % FINE_BINS;
            visited += 1;
        }

        if (n_peaks < MAX_PEAKS) {
            const angle = std.math.atan2(sin_acc, cos_acc) * (180.0 / std.math.pi);
            out[n_peaks] = .{
                .hue = @floatCast(@mod(angle + 360.0, 360.0)),
                .weight = w_sum,
            };
            n_peaks += 1;
        }
    }

    // Sort peaks by weight descending
    std.mem.sort(Peak, out[0..n_peaks], {}, struct {
        fn cmp(_: void, a: Peak, b: Peak) bool {
            return a.weight > b.weight;
        }
    }.cmp);

    return n_peaks;
}

/// Greedily assign peaks to accent slots by angular proximity.
/// Returns per-slot optional peak index (null = unassigned).
fn assignPeaks(peaks: []const Peak) [8]?usize {
    const Candidate = struct {
        peak_idx: usize,
        slot_idx: usize,
        distance: f32,
    };

    // Build all (peak, slot) candidate pairs
    var candidates: [MAX_PEAKS * 8]Candidate = undefined;
    var n_candidates: usize = 0;
    for (peaks, 0..) |peak, pi| {
        for (ACCENT_TARGETS, 0..) |target, si| {
            const dist = @abs(color.angularDiff(peak.hue, target.h));
            if (dist <= MAX_ASSIGNMENT_DISTANCE) {
                candidates[n_candidates] = .{
                    .peak_idx = pi,
                    .slot_idx = si,
                    .distance = dist,
                };
                n_candidates += 1;
            }
        }
    }

    // Sort by distance ascending
    std.mem.sort(Candidate, candidates[0..n_candidates], {}, struct {
        fn cmp(_: void, a: Candidate, b: Candidate) bool {
            return a.distance < b.distance;
        }
    }.cmp);

    // Greedy assignment: each peak and slot used at most once
    var result: [8]?usize = .{null} ** 8;
    var peak_used: [MAX_PEAKS]bool = .{false} ** MAX_PEAKS;

    for (candidates[0..n_candidates]) |c| {
        if (result[c.slot_idx] != null) continue; // slot taken
        if (peak_used[c.peak_idx]) continue; // peak taken
        result[c.slot_idx] = c.peak_idx;
        peak_used[c.peak_idx] = true;
    }

    return result;
}

/// Find the L closest to `target` within [lo, hi] that gives contrast >= MIN_ACCENT_CONTRAST
/// against bg0 and bg1, and >= MIN_ACCENT_CONTRAST_BG2 against bg2 (selection highlight).
/// In dark mode accents need to be light enough; in light mode they need to be dark enough.
fn optimizeAccentL(target: f32, lo: f32, hi: f32, C: f32, h: f32, bg0: color.Srgb, bg1: color.Srgb, bg2: color.Srgb, mode: Mode) f32 {
    // First check if the target itself satisfies contrast
    if (accentContrastOk(target, C, h, bg0, bg1, bg2)) return target;

    // Binary search: in dark mode, if target fails we need to go brighter;
    // in light mode, we need to go darker.
    var search_lo: f32 = undefined;
    var search_hi: f32 = undefined;
    if (mode == .dark) {
        search_lo = target;
        search_hi = hi;
    } else {
        search_lo = lo;
        search_hi = target;
    }

    for (0..20) |_| {
        const mid = (search_lo + search_hi) / 2.0;
        if (accentContrastOk(mid, C, h, bg0, bg1, bg2)) {
            if (mode == .dark) search_hi = mid else search_lo = mid;
        } else {
            if (mode == .dark) search_lo = mid else search_hi = mid;
        }
    }

    return if (mode == .dark) search_hi else search_lo;
}

fn accentContrastOk(L: f32, C: f32, h: f32, bg0: color.Srgb, bg1: color.Srgb, bg2: color.Srgb) bool {
    const srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(L, C, h)));
    return color.contrastRatio(srgb, bg0) >= MIN_ACCENT_CONTRAST and
        color.contrastRatio(srgb, bg1) >= MIN_ACCENT_CONTRAST and
        color.contrastRatio(srgb, bg2) >= MIN_ACCENT_CONTRAST_BG2;
}

/// Bright variant of an accent colour: lighter + slightly more chromatic.
/// Contrast-checked against base00, base01, and base02 (same backgrounds
/// as normal accents) to ensure readability on all relevant surfaces.
fn brightVariant(base: color.Srgb, backgrounds: [3]color.Srgb) color.Srgb {
    var lch = color.srgbToLch(base);
    lch.L = @min(1.0, lch.L + BRIGHT_DL);
    lch.C += BRIGHT_DC;

    const candidate = color.clipToGamut(lch);
    const srgb = color.lchToSrgb(candidate);
    if (brightContrastOk(srgb, backgrounds))
        return srgb;

    // Determine search direction from relative luminance against base00.
    const accent_Y = color.relativeLuminance(srgb);
    const bg_Y = color.relativeLuminance(backgrounds[0]);
    const search_up = accent_Y > bg_Y;

    var lo_s: f32 = if (search_up) lch.L else 0.0;
    var hi_s: f32 = if (search_up) 1.0 else lch.L;

    for (0..20) |_| {
        const mid = (lo_s + hi_s) / 2.0;
        const trial = color.lchToSrgb(color.clipToGamut(color.Lch.init(mid, lch.C, lch.h)));
        const ok = brightContrastOk(trial, backgrounds);
        if (search_up) {
            if (ok) hi_s = mid else lo_s = mid;
        } else {
            if (ok) lo_s = mid else hi_s = mid;
        }
    }

    const result_L = if (search_up) hi_s else lo_s;
    return color.lchToSrgb(color.clipToGamut(color.Lch.init(result_L, lch.C, lch.h)));
}

fn brightContrastOk(srgb: color.Srgb, backgrounds: [3]color.Srgb) bool {
    return color.contrastRatio(srgb, backgrounds[0]) >= MIN_ACCENT_CONTRAST and
        color.contrastRatio(srgb, backgrounds[1]) >= MIN_ACCENT_CONTRAST and
        color.contrastRatio(srgb, backgrounds[2]) >= MIN_ACCENT_CONTRAST_BG2;
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

/// Uniform fine histogram for monochrome/uniform test profiles.
const uniform_fine_weights = [_]f32{1.0 / @as(f32, @floatFromInt(analysis.FINE_BINS))} ** analysis.FINE_BINS;
const uniform_fine_centroids = blk: {
    var c: [analysis.FINE_BINS]f32 = undefined;
    for (0..analysis.FINE_BINS) |i| c[i] = @as(f32, @floatFromInt(i)) * 10.0 + 5.0;
    break :blk c;
};

/// Build fine histogram from 8-bucket weights: distribute each bucket's weight
/// evenly across its corresponding fine bins. Used to make test profiles consistent.
fn testFineBinsFromBuckets(bucket_weights: [8]f32) struct { w: [analysis.FINE_BINS]f32, c: [analysis.FINE_BINS]f32 } {
    // Each 45° bucket covers fine bins [bucket*4.5 .. (bucket+1)*4.5)
    // Approximate: bucket i → fine bins i*4 .. i*4+3 (4 bins, 40°), plus partial into i*4+4
    // For simplicity, just spread uniformly across the 4 nearest fine bins.
    var w = [_]f32{0} ** analysis.FINE_BINS;
    for (0..8) |bi| {
        if (bucket_weights[bi] <= 0) continue;
        // Bucket bi covers [bi*45°, (bi+1)*45°), fine bins roughly bi*4.5 to (bi+1)*4.5
        const start_f: f32 = @as(f32, @floatFromInt(bi)) * 4.5;
        const start: usize = @intFromFloat(@floor(start_f));
        const end_f: f32 = start_f + 4.5;
        const end: usize = @min(analysis.FINE_BINS, @as(usize, @intFromFloat(@ceil(end_f))));
        const n_bins: f32 = @floatFromInt(end - start);
        for (start..end) |fi| {
            w[fi % analysis.FINE_BINS] += bucket_weights[bi] / n_bins;
        }
    }
    // Normalize
    var total: f32 = 0;
    for (w) |v| total += v;
    if (total > 0) {
        for (&w) |*v| v.* /= total;
    }
    var c: [analysis.FINE_BINS]f32 = undefined;
    for (0..analysis.FINE_BINS) |i| c[i] = @as(f32, @floatFromInt(i)) * 10.0 + 5.0;
    return .{ .w = w, .c = c };
}

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
        .fine_hue_weights = uniform_fine_weights,
        .fine_hue_centroids = uniform_fine_centroids,
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
        .fine_hue_weights = uniform_fine_weights,
        .fine_hue_centroids = uniform_fine_centroids,
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

    // Fine bins: concentrate weight in bin 2 [20°, 30°) ≈ red
    var fine_w = [_]f32{0} ** analysis.FINE_BINS;
    fine_w[2] = 0.7;
    fine_w[1] = 0.2;
    fine_w[3] = 0.1;

    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = weights,
        .bucket_hues = hues,
        .mean_chroma = 0.15,
        .p85_chroma = 0.20,
        .fine_hue_weights = fine_w,
        .fine_hue_centroids = uniform_fine_centroids,
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
        .fine_hue_weights = uniform_fine_weights,
        .fine_hue_centroids = uniform_fine_centroids,
    };

    const p = generate(profile, .dark);

    // base12 (bright red) must be lighter than base08 (red)
    const r_L = color.srgbToLch(p.base08).L;
    const br_L = color.srgbToLch(p.base12).L;
    try testing.expect(br_L > r_L - 1e-4); // allow tiny floating-point slack
}

test "contrast: primary text (base05 on base00) meets AAA" {
    const testing = std.testing;
    const vivid_bw = blk: {
        var w = [_]f32{0} ** 8;
        w[0] = 0.6;
        w[1] = 0.3;
        w[2] = 0.1;
        break :blk w;
    };
    const vivid_fine = testFineBinsFromBuckets(vivid_bw);
    const profiles = [_]analysis.ImageProfile{
        // Vivid image
        .{
            .median_lightness = 0.3,
            .p10_lightness = 0.1,
            .p90_lightness = 0.6,
            .hue_weights = vivid_bw,
            .bucket_hues = blk: {
                var h: [8]f32 = undefined;
                for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
                break :blk h;
            },
            .mean_chroma = 0.18,
            .p85_chroma = 0.25,
            .fine_hue_weights = vivid_fine.w,
            .fine_hue_centroids = vivid_fine.c,
        },
        // All-black degenerate
        .{
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
            .fine_hue_weights = uniform_fine_weights,
            .fine_hue_centroids = uniform_fine_centroids,
        },
    };
    const modes = [_]Mode{ .dark, .light };

    for (profiles) |profile| {
        for (modes) |mode| {
            const p = generate(profile, mode);
            const cr = color.contrastRatio(p.base05, p.base00);
            try testing.expect(cr >= 7.0);
        }
    }
}

test "contrast: all accents meet minimum contrast against base00 and base02" {
    const testing = std.testing;
    const accent_bw = blk: {
        var w = [_]f32{0} ** 8;
        w[0] = 0.6;
        w[3] = 0.3;
        w[5] = 0.1;
        break :blk w;
    };
    const accent_fine = testFineBinsFromBuckets(accent_bw);
    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = accent_bw,
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .mean_chroma = 0.15,
        .p85_chroma = 0.20,
        .fine_hue_weights = accent_fine.w,
        .fine_hue_centroids = accent_fine.c,
    };

    for ([_]Mode{ .dark, .light }) |mode| {
        const p = generate(profile, mode);
        const accents = [_]color.Srgb{
            p.base08, p.base09, p.base0A, p.base0B,
            p.base0C, p.base0D, p.base0E, p.base0F,
        };
        for (accents) |accent| {
            try testing.expect(color.contrastRatio(accent, p.base00) >= MIN_ACCENT_CONTRAST);
            try testing.expect(color.contrastRatio(accent, p.base02) >= MIN_ACCENT_CONTRAST_BG2);
        }
        // Bright variants: same contract as normal accents
        const brights = [_]color.Srgb{
            p.base12, p.base13, p.base14, p.base15, p.base16, p.base17,
        };
        for (brights) |bright| {
            try testing.expect(color.contrastRatio(bright, p.base00) >= MIN_ACCENT_CONTRAST);
            try testing.expect(color.contrastRatio(bright, p.base01) >= MIN_ACCENT_CONTRAST);
            try testing.expect(color.contrastRatio(bright, p.base02) >= MIN_ACCENT_CONTRAST_BG2);
        }
    }
}

test "tint visibility: vivid image produces tint above old ceiling" {
    const testing = std.testing;
    // A vivid image with high chroma
    const tint_bw = blk: {
        var w = [_]f32{0} ** 8;
        w[0] = 0.8;
        w[1] = 0.2;
        break :blk w;
    };
    const tint_fine = testFineBinsFromBuckets(tint_bw);
    const profile = analysis.ImageProfile{
        .median_lightness = 0.4,
        .p10_lightness = 0.1,
        .p90_lightness = 0.7,
        .hue_weights = tint_bw,
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .mean_chroma = 0.20,
        .p85_chroma = 0.28,
        .fine_hue_weights = tint_fine.w,
        .fine_hue_centroids = tint_fine.c,
    };

    const palette = generate(profile, .dark);

    // Tones should have visible chroma (above the old 0.012 cap)
    // Check a mid-tone where tint is clearly visible
    const lch03 = color.srgbToLch(palette.base03);
    try testing.expect(lch03.C > 0.012);
}

test "degenerate: all-black produces zero tint" {
    const testing = std.testing;
    const profile = analysis.ImageProfile{
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
        .fine_hue_weights = uniform_fine_weights,
        .fine_hue_centroids = uniform_fine_centroids,
    };

    const palette = generate(profile, .dark);

    // Zero mean_chroma → tint_C_max = 0 → all tones should be achromatic
    // (tolerance accounts for f32 round-trip error through sRGB ↔ OKLCh)
    const lch00 = color.srgbToLch(palette.base00);
    const lch05 = color.srgbToLch(palette.base05);
    try testing.expectApproxEqAbs(0.0, lch00.C, 0.005);
    try testing.expectApproxEqAbs(0.0, lch05.C, 0.005);
}
