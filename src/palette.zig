//! Base24 palette generation.
//!
//! Produces a usable, image-inspired Base24 colour scheme by:
//!   1. Detecting dark vs. light mode from image luminance.
//!   2. Building a tone ramp (base00–07, base10–11) with a slight hue tint
//!      derived from the image's primary colour.
//!   3. Generating 8 accent colours (base08–0F) using image-first hue
//!      assignment: dominant image hues are extracted as peaks and
//!      exhaustively matched to nearby accent slots at boosted chroma.
//!      Unassigned slots keep their canonical hue at a moderate floor chroma.
//!   4. Deriving 6 bright accent colours (base12–17) from base08–0D.
//!   5. Clipping every colour to the sRGB gamut via chroma reduction.
//!
//! Accents are contrast-checked against base00, base01, and base02 to ensure
//! readability on both default and selection-highlight backgrounds.

const std = @import("std");
const color = @import("color.zig");
const analysis = @import("analysis.zig");
const pks = @import("peaks.zig");

const AccentTarget = pks.AccentTarget;
const ACCENT_TARGETS = pks.ACCENT_TARGETS;
const Peak = pks.Peak;
const HueData = pks.HueData;
const extractPeaks = pks.extractPeaks;
const sampleHueData = pks.sampleHueData;
const isClosestSlot = pks.isClosestSlot;
const nearestNeighborDist = pks.nearestNeighborDist;
const MAX_PEAKS = pks.MAX_PEAKS;
const MAX_ASSIGNMENT_DISTANCE = pks.MAX_ASSIGNMENT_DISTANCE;
const MAX_HUE_PULL = pks.MAX_HUE_PULL;
const HUE_NEIGHBOR_PAIRS = pks.HUE_NEIGHBOR_PAIRS;
const SIGNIFICANCE_FACTOR = pks.SIGNIFICANCE_FACTOR;

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

const DARK_TONE_L = [10]f32{
    //  00     01     02     03     04     05     06     07    10     11
    0.12, 0.17, 0.23, 0.35, 0.55, 0.75, 0.87, 0.95, 0.08, 0.05,
};

/// Light mode gets its own tuned ramp rather than simple mirroring.
/// Key differences from 1−dark:
///   • base00 raised (0.93 vs 0.88) for a brighter "paper" feel
///   • base05 raised (0.32 vs 0.25) for softer body text (still 8:1+ contrast)
///   • base11/10 near-white for deeper light-mode backgrounds
const LIGHT_TONE_L = [10]f32{
    //  00     01     02     03     04     05     06     07    10     11
    0.93, 0.87, 0.78, 0.62, 0.47, 0.32, 0.18, 0.08, 0.96, 0.98,
};

const BRIGHT_DL: f32 = 0.10;
const BRIGHT_DC: f32 = 0.03;

/// Hard floor for peak-assigned accent C (kept low so muted images can yield
/// muted accents; the actual ceiling is image-derived).
const MIN_ACCENT_C: f32 = 0.07;
/// Hard floor for unassigned accent C — must be visible as colour, not gray.
const UNASSIGNED_ACCENT_C: f32 = 0.05;
/// Hard ceiling for accent C; the image-derived target is clamped here.
const MAX_ACCENT_C: f32 = 0.32;

/// 1.2× headroom above the image's vivid-cluster mean, so accents read as
/// semantic focal points rather than blending in with the rest of the image.
const ACCENT_BOOST: f32 = 1.2;
/// Hard cap on neutral chroma floor regardless of how tinted the image is —
/// past this point the bases stop reading as neutrals.
const TINT_C_CEILING: f32 = 0.04;
/// Maximum hue shift (degrees) toward the image's circular-mean hue.
/// Applied to unassigned accent slots only, scaled by mean_hue_strength,
/// so all accents share a hint of the image's overall temperature.
const TEMPERATURE_PULL: f32 = 5.0;
/// Maximum L spread across accents before the harmony soft penalty kicks
/// in. = max(dL) − min(dL) + 0.10 = 0.10 − (−0.15) + 0.10 = 0.35. The
/// first 0.25 is the intentional baseline from yellow's lift and brown's
/// drop; the +0.10 is image-induced variance we tolerate before pulling
/// accents back into a shared L band.
const ALLOWED_L_SPREAD: f32 = 0.35;

/// Minimum contrast ratio for accents against base02 (selection highlight).
const MIN_ACCENT_CONTRAST_BG2: f32 = 2.5;

/// Minimum OKLab ΔE between any two accents (perceptual distinctiveness).
const MIN_PAIRWISE_DE: f32 = 0.12;

/// Minimum OKLab ΔE between accent pairs under CVD simulation.
const MIN_CVD_DE: f32 = 0.08;

// ─── Public API ───────────────────────────────────────────────────────────────

/// Runtime-tunable generation parameters.
/// Default values match the compile-time constants; the TUI devtool exposes
/// these for interactive exploration of the tradeoff space.
pub const Config = struct {
    /// Accent L target for dark mode.
    accent_l_dark: f32 = 0.65,
    /// Accent L target for light mode.
    accent_l_light: f32 = 0.52,
    /// How strongly the image's per-hue lightness biases accent L targets.
    /// 0 = uniform L, 1 = fully image-driven differentiation.
    image_l_influence: f32 = 0.4,
    /// Minimum WCAG contrast ratio between diff-paired accents (green/red vs blue).
    min_diff_pair_cr: f32 = MIN_DIFF_PAIR_CR,
    /// Minimum contrast ratio for accents against base00/base01.
    min_accent_contrast: f32 = MIN_ACCENT_CONTRAST,
    /// Minimum contrast ratio for accents against base02 (selection highlight).
    min_accent_contrast_bg2: f32 = MIN_ACCENT_CONTRAST_BG2,
    /// Minimum OKLab ΔE between any two accents.
    min_pairwise_de: f32 = MIN_PAIRWISE_DE,
    /// Minimum OKLab ΔE between accent pairs under CVD simulation.
    min_cvd_de: f32 = MIN_CVD_DE,
    /// Bright variant lightness boost (maximum; actual boost is adaptive).
    bright_dl: f32 = BRIGHT_DL,
    /// Bright variant chroma boost.
    bright_dc: f32 = BRIGHT_DC,
};

pub fn generate(profile: analysis.ImageProfile, forced_mode: ?Mode, config: Config) Palette {
    const mode: Mode = forced_mode orelse
        if (profile.median_lightness < 0.5) .dark else .light;

    const tones = buildToneRamp(profile, mode);
    const accents = buildAccents(profile, mode, tones, config);
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
        .base12 = brightVariant(accents[0], bg, config),
        .base13 = brightVariant(accents[2], bg, config), // bright yellow ← base0A
        .base14 = brightVariant(accents[3], bg, config), // bright green  ← base0B
        .base15 = brightVariant(accents[4], bg, config), // bright cyan   ← base0C
        .base16 = brightVariant(accents[5], bg, config), // bright blue   ← base0D
        .base17 = brightVariant(accents[6], bg, config), // bright magenta← base0E
    };
}

// ─── Tone ramp ────────────────────────────────────────────────────────────────

const ContrastPair = struct { fg: usize, bg: usize, min_ratio: f32 };
const TONE_CONTRAST_PAIRS = [_]ContrastPair{
    .{ .fg = 5, .bg = 0, .min_ratio = 7.0 }, // base05 on base00 (primary text, AAA)
    .{ .fg = 7, .bg = 0, .min_ratio = 7.0 }, // base07 on base00 (bright fg, AAA)
    .{ .fg = 5, .bg = 2, .min_ratio = 4.5 }, // base05 on base02 (text on selection, AA)
    .{ .fg = 4, .bg = 1, .min_ratio = 3.0 }, // base04 on base01 (status bar, AA-large)
};

fn buildToneRamp(profile: analysis.ImageProfile, mode: Mode) [10]color.Srgb {
    const primary = dominantBucket(profile.hue_weights);
    const split = splitToneHues(profile, primary);

    const tint_C_max = @min(profile.chroma_lower, TINT_C_CEILING);

    var lo: f32 = 0.0;
    var hi: f32 = tint_C_max;
    for (0..20) |_| {
        const mid = (lo + hi) / 2.0;
        if (toneRampSatisfiesContrast(mid, split.shadow_h, mode)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    const tint_C = lo;

    const tone_L = if (mode == .dark) DARK_TONE_L else LIGHT_TONE_L;
    var result: [10]color.Srgb = undefined;
    for (tone_L, 0..) |L, i| {
        // Interpolate hue from shadow to highlight across the ramp.
        // t=0 at darkest, t=1 at lightest.
        const t = color.saturate((L - 0.05) / (0.95 - 0.05));
        const tint_h = circLerp(split.shadow_h, split.highlight_h, t);
        const tone_C = tintChromaForL(tint_C, L, tint_h);
        const lch = color.Lch.init(L, tone_C, tint_h);
        result[i] = color.lchToSrgb(color.clipToGamut(lch));
    }
    return result;
}

fn tintChromaForL(base_C: f32, dark_L: f32, tint_h: f32) f32 {
    // σ=0.45 keeps a visible hint of tint at the L extremes (base11/base07)
    // instead of crushing chroma to ~0. Catppuccin's crust still reads as
    // purple-ish; with a narrower bell ours reverted to pure neutral.
    const center: f32 = 0.40;
    const sigma: f32 = 0.45;
    const t = (dark_L - center) / sigma;
    const envelope = std.math.exp(-0.5 * t * t);
    const gamut_max = color.maxGamutChroma(dark_L, tint_h);
    return @min(base_C * @as(f32, @floatCast(envelope)), gamut_max);
}

fn toneRampSatisfiesContrast(tint_C: f32, tint_h: f32, mode: Mode) bool {
    const tone_L = if (mode == .dark) DARK_TONE_L else LIGHT_TONE_L;
    var tones: [10]color.Srgb = undefined;
    for (tone_L, 0..) |L, i| {
        const tone_C = tintChromaForL(tint_C, L, tint_h);
        const lch = color.Lch.init(L, tone_C, tint_h);
        tones[i] = color.lchToSrgb(color.clipToGamut(lch));
    }
    for (TONE_CONTRAST_PAIRS) |pair| {
        if (color.contrastRatio(tones[pair.fg], tones[pair.bg]) < pair.min_ratio)
            return false;
    }
    return true;
}

// ─── Accent colours ───────────────────────────────────────────────────────────

const MIN_ACCENT_CONTRAST: f32 = 3.0;

fn buildAccents(profile: analysis.ImageProfile, mode: Mode, tones: [10]color.Srgb, config: Config) [8]color.Srgb {
    return solveAccents(profile, mode, tones, config);
}

fn solveAccents(profile: analysis.ImageProfile, mode: Mode, tones: [10]color.Srgb, config: Config) [8]color.Srgb {
    const accent_L_base: f32 = if (mode == .dark) config.accent_l_dark else config.accent_l_light;
    const L_lo: f32 = if (mode == .dark) 0.45 else 0.35;
    const L_hi: f32 = if (mode == .dark) 0.85 else 0.70;

    // Image-derived absolute vibrance target.
    const C_target_abs = std.math.clamp(profile.chroma_upper * ACCENT_BOOST, MIN_ACCENT_C, MAX_ACCENT_C);

    // Pre-compute per-accent gamut maxes at accent_L_base + dL. Harmonization
    // applies the same fraction of gamut max to every accent — so yellow
    // (high-gamut) and green (low-gamut) sit at the same perceptual saturation
    // instead of yellow dominating because it has more gamut headroom.
    var gamut_max_arr: [8]f32 = undefined;
    var max_gamut: f32 = 0;
    for (ACCENT_TARGETS, 0..) |target, i| {
        const test_L = std.math.clamp(accent_L_base + target.dL, L_lo, L_hi);
        gamut_max_arr[i] = color.maxGamutChroma(test_L, target.h);
        if (gamut_max_arr[i] > max_gamut) max_gamut = gamut_max_arr[i];
    }

    // Calibrate the fraction against the LARGEST accent gamut: the most-
    // saturable hue lands at C_target_abs at most, and lower-gamut hues
    // scale down proportionally to maintain harmony. This keeps the palette
    // restrained — no accent ever exceeds the image's absolute vibrance.
    const sat_fraction = std.math.clamp(C_target_abs / max_gamut, 0.35, 0.92);

    var c_ceiling: [8]f32 = undefined;
    for (0..8) |i| {
        c_ceiling[i] = @max(MIN_ACCENT_C, gamut_max_arr[i] * sat_fraction);
    }

    var effective_config = config;
    if (mode == .light) {
        effective_config.min_diff_pair_cr = @min(config.min_diff_pair_cr, 1.5);
    }

    var peaks: [MAX_PEAKS]Peak = undefined;
    const n_peaks = extractPeaks(profile, &peaks);

    var matchings: [MAX_MATCHINGS][8]?usize = undefined;
    var collect_ctx = CollectCtx{
        .peaks = peaks[0..n_peaks],
        .matchings = &matchings,
        .count = 0,
    };
    var current: [8]?usize = .{null} ** 8;
    var peak_used: [MAX_PEAKS]bool = .{false} ** MAX_PEAKS;
    collectRec(&collect_ctx, 0, &current, &peak_used);
    const n_matchings = collect_ctx.count;

    var scores: [MAX_MATCHINGS]f32 = .{-std.math.inf(f32)} ** MAX_MATCHINGS;

    if (n_matchings > 1) {
        var pool: std.Thread.Pool = undefined;
        pool.init(.{ .allocator = std.heap.page_allocator }) catch {
            for (0..n_matchings) |i| {
                evalMatchingTask(&scores, i, &matchings, peaks[0..n_peaks], profile, mode, effective_config, tones, c_ceiling, accent_L_base, L_lo, L_hi);
            }
            return finishSolve(&scores, n_matchings, &matchings, peaks, n_peaks, profile, mode, effective_config, tones, c_ceiling, accent_L_base, L_lo, L_hi);
        };
        defer pool.deinit();

        var wg: std.Thread.WaitGroup = .{};
        for (0..n_matchings) |i| {
            pool.spawnWg(&wg, evalMatchingTask, .{ &scores, i, &matchings, peaks[0..n_peaks], profile, mode, effective_config, tones, c_ceiling, accent_L_base, L_lo, L_hi });
        }
        pool.waitAndWork(&wg);
    } else if (n_matchings == 1) {
        evalMatchingTask(&scores, 0, &matchings, peaks[0..n_peaks], profile, mode, effective_config, tones, c_ceiling, accent_L_base, L_lo, L_hi);
    }

    return finishSolve(&scores, n_matchings, &matchings, peaks, n_peaks, profile, mode, effective_config, tones, c_ceiling, accent_L_base, L_lo, L_hi);
}

fn finishSolve(
    scores: *const [MAX_MATCHINGS]f32,
    n_matchings: usize,
    matchings: *const [MAX_MATCHINGS][8]?usize,
    peaks: [MAX_PEAKS]Peak,
    n_peaks: usize,
    profile: analysis.ImageProfile,
    mode: Mode,
    config: Config,
    tones: [10]color.Srgb,
    c_ceiling: [8]f32,
    accent_L_base: f32,
    L_lo: f32,
    L_hi: f32,
) [8]color.Srgb {
    var best_idx: usize = 0;
    var best_score: f32 = -std.math.inf(f32);
    for (0..n_matchings) |i| {
        if (scores[i] > best_score) {
            best_score = scores[i];
            best_idx = i;
        }
    }

    const best_matching = if (n_matchings > 0) matchings[best_idx] else [_]?usize{null} ** 8;
    const eval = evaluateMatching(best_matching, peaks[0..n_peaks], profile, mode, config, tones, c_ceiling, accent_L_base, L_lo, L_hi, true);
    return eval.result;
}

// ─── Assignment enumeration ──────────────────────────────────────────────────

const MAX_MATCHINGS: usize = 256;

const CollectCtx = struct {
    peaks: []const Peak,
    matchings: *[MAX_MATCHINGS][8]?usize,
    count: usize,
};

fn collectRec(ctx: *CollectCtx, slot: usize, current: *[8]?usize, peak_used: *[MAX_PEAKS]bool) void {
    if (slot == 8) {
        if (ctx.count < MAX_MATCHINGS) {
            ctx.matchings[ctx.count] = current.*;
            ctx.count += 1;
        }
        return;
    }

    collectRec(ctx, slot + 1, current, peak_used);

    for (ctx.peaks, 0..) |p, pi| {
        if (peak_used[pi]) continue;
        const dist = @abs(color.angularDiff(p.hue, ACCENT_TARGETS[slot].h));
        if (dist > MAX_ASSIGNMENT_DISTANCE) continue;
        if (!isClosestSlot(slot, p.hue)) continue;
        current[slot] = pi;
        peak_used[pi] = true;
        collectRec(ctx, slot + 1, current, peak_used);
        current[slot] = null;
        peak_used[pi] = false;
    }
}

fn evalMatchingTask(
    scores: *[MAX_MATCHINGS]f32,
    idx: usize,
    matchings: *const [MAX_MATCHINGS][8]?usize,
    peaks: []const Peak,
    profile: analysis.ImageProfile,
    mode: Mode,
    config: Config,
    tones: [10]color.Srgb,
    c_ceiling: [8]f32,
    accent_L_base: f32,
    L_lo: f32,
    L_hi: f32,
) void {
    const eval = evaluateMatching(matchings[idx], peaks, profile, mode, config, tones, c_ceiling, accent_L_base, L_lo, L_hi, false);
    scores[idx] = eval.score;
}

// ─── Matching evaluation ─────────────────────────────────────────────────────

const EvalResult = struct {
    result: [8]color.Srgb,
    score: f32,
};

fn evaluateMatching(
    matching: [8]?usize,
    peaks: []const Peak,
    profile: analysis.ImageProfile,
    mode: Mode,
    config: Config,
    tones: [10]color.Srgb,
    c_ceiling: [8]f32,
    accent_L_base: f32,
    L_lo: f32,
    L_hi: f32,
    comptime full: bool,
) EvalResult {
    const base00 = tones[0];
    const base01 = tones[1];
    const base02 = tones[2];

    var accent_h: [8]f32 = undefined;
    var img_data: [8]HueData = undefined;

    for (ACCENT_TARGETS, 0..) |target, i| {
        if (matching[i]) |peak_idx| {
            accent_h[i] = peaks[peak_idx].hue;
        } else {
            // Local pull: toward whatever image data exists near this slot.
            const sample = sampleHueData(profile, target.h);
            var h: f32 = target.h;
            if (sample.weight > 1e-6) {
                const max_pull = @min(MAX_HUE_PULL, nearestNeighborDist(i) * 0.4);
                // sample.weight is a Gaussian-weighted sum over clusters;
                // total cluster weight sums to 1, so 0.25 of total nearby is
                // the saturation point for "this image strongly wants a
                // colour here."
                const evidence = color.saturate(sample.weight / 0.25);
                const raw_pull = std.math.clamp(
                    color.angularDiff(sample.centroid_h, target.h),
                    -max_pull,
                    max_pull,
                );
                h = @mod(target.h + raw_pull * evidence + 360.0, 360.0);
            }
            // Global pull: small bias toward the image's overall temperature,
            // scaled by how concentrated the hue distribution is.
            const temp_max = TEMPERATURE_PULL * profile.mean_hue_strength;
            const temp_pull = std.math.clamp(
                color.angularDiff(profile.mean_hue, h),
                -temp_max,
                temp_max,
            );
            accent_h[i] = @mod(h + temp_pull + 360.0, 360.0);
        }
    }

    // For peak-assigned slots, use the matched cluster's (L, C, weight)
    // directly — this is the actual colour the image has there, not a
    // Gaussian-band aggregate. Unassigned slots fall back to sampleHueData,
    // which Gaussians over all clusters near the canonical hue.
    for (0..8) |i| {
        if (matching[i]) |peak_idx| {
            const p = peaks[peak_idx];
            img_data[i] = .{
                .L = p.L,
                .C = p.C,
                .weight = p.weight,
                .centroid_h = p.hue,
            };
        } else {
            img_data[i] = sampleHueData(profile, accent_h[i]);
        }
    }

    var max_weight: f32 = 0;
    for (img_data) |d| {
        if (d.weight > max_weight) max_weight = d.weight;
    }

    var affinity: [8]f32 = undefined;
    var accent_C: [8]f32 = undefined;
    var ideal_L: [8]f32 = undefined;

    for (ACCENT_TARGETS, 0..) |target, i| {
        affinity[i] = if (max_weight > 1e-6) img_data[i].weight / max_weight else 0.0;
        const C_floor: f32 = if (matching[i] != null) MIN_ACCENT_C else UNASSIGNED_ACCENT_C;
        ideal_L[i] = std.math.clamp(
            color.lerp(accent_L_base, img_data[i].L, affinity[i] * config.image_l_influence) + target.dL,
            L_lo,
            L_hi,
        );
        const gamut_max = @max(
            color.maxGamutChroma(ideal_L[i], accent_h[i]),
            color.maxGamutChroma(accent_L_base, accent_h[i]),
        );
        const raw_C = @max(0.0, color.lerp(C_floor, c_ceiling[i], @sqrt(affinity[i])) + target.dC);
        accent_C[i] = @min(raw_C, gamut_max);
    }

    // Reduce chroma on hue-neighbor pairs to prevent gamut-clip collapse
    for (HUE_NEIGHBOR_PAIRS) |pair| {
        const a = pair[0];
        const b = pair[1];
        const test_L = accent_L_base;
        const srgb_a = color.lchToSrgb(color.clipToGamut(color.Lch.init(test_L, accent_C[a], accent_h[a])));
        const srgb_b = color.lchToSrgb(color.clipToGamut(color.Lch.init(test_L, accent_C[b], accent_h[b])));
        const lch_a = color.srgbToLch(srgb_a);
        const lch_b = color.srgbToLch(srgb_b);
        const hue_sep = @abs(color.angularDiff(lch_a.h, lch_b.h));
        if (hue_sep < 10.0) {
            const reduce_idx: usize = if (affinity[a] < affinity[b]) a else b;
            var lo_c: f32 = 0.02;
            var hi_c: f32 = accent_C[reduce_idx];
            for (0..16) |_| {
                const mid_c = (lo_c + hi_c) / 2.0;
                const test_srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(test_L, mid_c, accent_h[reduce_idx])));
                const test_lch = color.srgbToLch(test_srgb);
                const other_idx: usize = if (reduce_idx == a) b else a;
                const other_srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(test_L, accent_C[other_idx], accent_h[other_idx])));
                const other_lch = color.srgbToLch(other_srgb);
                const sep = @abs(color.angularDiff(test_lch.h, other_lch.h));
                if (sep >= 15.0) lo_c = mid_c else hi_c = mid_c;
            }
            accent_C[reduce_idx] = lo_c;
        }
    }

    // Feasibility-first (L, C) optimisation — see DESIGN.md §3.
    var param_L = ideal_L;
    var param_C = accent_C;

    for (0..8) |i| {
        const bound = computeLBound(param_C[i], accent_h[i], base00, base01, base02, mode, L_lo, L_hi, config);
        if (mode == .dark) {
            param_L[i] = @max(param_L[i], bound);
        } else {
            param_L[i] = @min(param_L[i], bound);
        }
    }

    const penalty_weight: f32 = 500.0;

    var c_lo: [8]f32 = undefined;
    var c_hi: [8]f32 = undefined;
    for (0..8) |i| {
        const C_floor: f32 = if (matching[i] != null) MIN_ACCENT_C else UNASSIGNED_ACCENT_C;
        c_lo[i] = C_floor;
        c_hi[i] = @min(c_ceiling[i], accent_C[i] + 0.03);
    }

    const INDEPENDENT = [_]usize{ 1, 2, 4, 6, 7 }; // orange, yellow, cyan, purple, brown
    const COUPLED = [_]usize{ 0, 3, 5 }; // red, green, blue

    var cur_srgb: [8]color.Srgb = undefined;
    for (0..8) |i| {
        cur_srgb[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[i], param_C[i], accent_h[i])));
    }

    for (INDEPENDENT) |i| {
        const l_steps: usize = if (full) 48 else 32;
        const c_steps: usize = if (full) 12 else 8;
        var best_obj: f32 = -std.math.inf(f32);
        var best_L: f32 = param_L[i];
        var best_C: f32 = param_C[i];

        var li: usize = 0;
        while (li <= l_steps) : (li += 1) {
            const trial_L = L_lo + (L_hi - L_lo) * @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(l_steps));
            var ci: usize = 0;
            while (ci <= c_steps) : (ci += 1) {
                const trial_C = color.lerp(c_lo[i], c_hi[i], @as(f32, @floatFromInt(ci)) / @as(f32, @floatFromInt(c_steps)));
                const obj = evalAccentContribution(i, trial_L, trial_C, &accent_h, &cur_srgb, &affinity, &ideal_L, &accent_C, base00, base01, base02, L_lo, L_hi, c_ceiling[i], penalty_weight, config);
                if (obj > best_obj) {
                    best_obj = obj;
                    best_L = trial_L;
                    best_C = trial_C;
                }
            }
        }
        param_L[i] = best_L;
        param_C[i] = best_C;
        cur_srgb[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(best_L, best_C, accent_h[i])));
    }

    const max_rounds: usize = if (full) 6 else 3;
    const min_rounds: usize = if (full) 2 else 1;

    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        var any_moved = false;

        for (0..4) |_| {
            for (COUPLED) |i| {
                var best_obj: f32 = -std.math.inf(f32);
                var best_L: f32 = param_L[i];
                var best_C: f32 = param_C[i];

                const l_steps: usize = if (full) 48 else 32;
                const c_steps: usize = if (full) 12 else 8;
                var li: usize = 0;
                while (li <= l_steps) : (li += 1) {
                    const trial_L = L_lo + (L_hi - L_lo) * @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(l_steps));
                    var ci: usize = 0;
                    while (ci <= c_steps) : (ci += 1) {
                        const trial_C = color.lerp(c_lo[i], c_hi[i], @as(f32, @floatFromInt(ci)) / @as(f32, @floatFromInt(c_steps)));

                        const obj = evalAccentContribution(i, trial_L, trial_C, &accent_h, &cur_srgb, &affinity, &ideal_L, &accent_C, base00, base01, base02, L_lo, L_hi, c_ceiling[i], penalty_weight, config);

                        if (obj > best_obj) {
                            best_obj = obj;
                            best_L = trial_L;
                            best_C = trial_C;
                        }
                    }
                }

                if (@abs(best_L - param_L[i]) > 0.002 or @abs(best_C - param_C[i]) > 0.002) {
                    any_moved = true;
                }
                param_L[i] = best_L;
                param_C[i] = best_C;
                cur_srgb[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(best_L, best_C, accent_h[i])));
            }
        }

        // Joint 3D grid search over coupled (r, g, b) L values
        {
            const ri: usize = 0; // red
            const gi: usize = 3; // green
            const bi: usize = 5; // blue
            const joint_steps: usize = if (round < max_rounds - 1) 12 else if (full) 32 else 24;
            const step_size = (L_hi - L_lo) / @as(f32, @floatFromInt(joint_steps));

            var best_obj: f32 = -std.math.inf(f32);
            var best_Lr = param_L[ri];
            var best_Lg = param_L[gi];
            var best_Lb = param_L[bi];

            var jri: usize = 0;
            while (jri <= joint_steps) : (jri += 1) {
                const trial_Lr = L_lo + step_size * @as(f32, @floatFromInt(jri));
                const srgb_r = color.lchToSrgb(color.clipToGamut(color.Lch.init(trial_Lr, param_C[ri], accent_h[ri])));
                const lch_r = color.srgbToLch(srgb_r);

                var jgi: usize = 0;
                while (jgi <= joint_steps) : (jgi += 1) {
                    const trial_Lg = L_lo + step_size * @as(f32, @floatFromInt(jgi));
                    const srgb_g = color.lchToSrgb(color.clipToGamut(color.Lch.init(trial_Lg, param_C[gi], accent_h[gi])));
                    const lch_g = color.srgbToLch(srgb_g);

                    var jbi: usize = 0;
                    while (jbi <= joint_steps) : (jbi += 1) {
                        const trial_Lb = L_lo + step_size * @as(f32, @floatFromInt(jbi));
                        const srgb_b = color.lchToSrgb(color.clipToGamut(color.Lch.init(trial_Lb, param_C[bi], accent_h[bi])));
                        const lch_b = color.srgbToLch(srgb_b);

                        const L_range = L_hi - L_lo;
                        var fidelity: f32 = 0;
                        fidelity += (affinity[ri] + 0.01) * @max(0.0, 1.0 - @abs(lch_r.L - ideal_L[ri]) / L_range);
                        fidelity += (affinity[gi] + 0.01) * @max(0.0, 1.0 - @abs(lch_g.L - ideal_L[gi]) / L_range);
                        fidelity += (affinity[bi] + 0.01) * @max(0.0, 1.0 - @abs(lch_b.L - ideal_L[bi]) / L_range);

                        var joint_violation: f32 = 0;
                        for ([3]color.Srgb{ srgb_r, srgb_g, srgb_b }) |s| {
                            const cr0 = color.contrastRatio(s, base00);
                            const cr1 = color.contrastRatio(s, base01);
                            const cr2 = color.contrastRatio(s, base02);
                            if (cr0 < config.min_accent_contrast)
                                joint_violation += sq(config.min_accent_contrast - cr0);
                            if (cr1 < config.min_accent_contrast)
                                joint_violation += sq(config.min_accent_contrast - cr1);
                            if (cr2 < config.min_accent_contrast_bg2)
                                joint_violation += sq(config.min_accent_contrast_bg2 - cr2);
                        }

                        const cr_rb = color.contrastRatio(srgb_r, srgb_b);
                        const cr_gb = color.contrastRatio(srgb_g, srgb_b);
                        const cr_rg = color.contrastRatio(srgb_r, srgb_g);
                        if (cr_rb < config.min_diff_pair_cr)
                            joint_violation += sq(config.min_diff_pair_cr - cr_rb);
                        if (cr_gb < config.min_diff_pair_cr)
                            joint_violation += sq(config.min_diff_pair_cr - cr_gb);
                        const rg_min: f32 = 1.8;
                        if (cr_rg < rg_min)
                            joint_violation += sq(rg_min - cr_rg);

                        var joint_soft: f32 = 0;
                        const joint_srgbs = [3]color.Srgb{ srgb_r, srgb_g, srgb_b };
                        var joint_labs: [3]color.Lab = undefined;
                        for (0..3) |ji| {
                            joint_labs[ji] = color.linearToLab(color.srgbToLinear(joint_srgbs[ji]));
                        }
                        for (0..3) |ji| {
                            for (ji + 1..3) |jj| {
                                const de = color.labDist(joint_labs[ji], joint_labs[jj]);
                                if (de < config.min_pairwise_de)
                                    joint_soft += sq(config.min_pairwise_de - de);
                            }
                            for (0..8) |k| {
                                if (k == ri or k == gi or k == bi) continue;
                                const lab_k = color.linearToLab(color.srgbToLinear(cur_srgb[k]));
                                const de = color.labDist(joint_labs[ji], lab_k);
                                if (de < config.min_pairwise_de)
                                    joint_soft += sq(config.min_pairwise_de - de);
                            }
                        }
                        for (CVD_PAIRS) |cvd_pair| {
                            const a_in = (cvd_pair.a == ri or cvd_pair.a == gi or cvd_pair.a == bi);
                            const b_in = (cvd_pair.b == ri or cvd_pair.b == gi or cvd_pair.b == bi);
                            if (!a_in and !b_in) continue;
                            const sa = if (cvd_pair.a == ri) srgb_r else if (cvd_pair.a == gi) srgb_g else if (cvd_pair.a == bi) srgb_b else cur_srgb[cvd_pair.a];
                            const sb = if (cvd_pair.b == ri) srgb_r else if (cvd_pair.b == gi) srgb_g else if (cvd_pair.b == bi) srgb_b else cur_srgb[cvd_pair.b];
                            const cvd_de = switch (cvd_pair.cvd) {
                                .protan => color.cvdDist(sa, sb, .protan),
                                .deutan => color.cvdDist(sa, sb, .deutan),
                            };
                            if (cvd_de < config.min_cvd_de)
                                joint_soft += sq(config.min_cvd_de - cvd_de);
                        }

                        // L-spread harmony penalty over the full palette.
                        var min_L: f32 = @min(@min(lch_r.L, lch_g.L), lch_b.L);
                        var max_L: f32 = @max(@max(lch_r.L, lch_g.L), lch_b.L);
                        for (cur_srgb, 0..) |s, k| {
                            if (k == ri or k == gi or k == bi) continue;
                            const Lk = color.srgbToLch(s).L;
                            if (Lk < min_L) min_L = Lk;
                            if (Lk > max_L) max_L = Lk;
                        }
                        const L_spread = max_L - min_L;
                        if (L_spread > ALLOWED_L_SPREAD)
                            joint_soft += sq(L_spread - ALLOWED_L_SPREAD);

                        const obj: f32 = if (joint_violation > 1e-6)
                            -1000.0 - penalty_weight * joint_violation
                        else
                            fidelity - 150.0 * joint_soft;

                        if (obj > best_obj) {
                            best_obj = obj;
                            best_Lr = trial_Lr;
                            best_Lg = trial_Lg;
                            best_Lb = trial_Lb;
                        }
                    }
                }
            }
            if (@abs(best_Lr - param_L[ri]) > 0.002 or
                @abs(best_Lg - param_L[gi]) > 0.002 or
                @abs(best_Lb - param_L[bi]) > 0.002)
            {
                any_moved = true;
            }
            param_L[ri] = best_Lr;
            param_L[gi] = best_Lg;
            param_L[bi] = best_Lb;
        }

        if (round >= min_rounds and !any_moved) break;
    }

    // Refinement pass
    {
            for (0..8) |k| {
                cur_srgb[k] = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[k], param_C[k], accent_h[k])));
            }
            for (0..8) |i| {
                var best_obj: f32 = -std.math.inf(f32);
                var best_L: f32 = param_L[i];
                var best_C: f32 = param_C[i];
                const radius: f32 = 0.10;
                const refine_steps: usize = 40;
                const search_lo = @max(L_lo, param_L[i] - radius);
                const search_hi = @min(L_hi, param_L[i] + radius);
                var li: usize = 0;
                while (li <= refine_steps) : (li += 1) {
                    const trial_L = search_lo + (search_hi - search_lo) * @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(refine_steps));
                    const c_search_lo = @max(c_lo[i], param_C[i] - 0.02);
                    const c_search_hi = @min(c_hi[i], param_C[i] + 0.02);
                    var ci: usize = 0;
                    while (ci <= 8) : (ci += 1) {
                        const trial_C = color.lerp(c_search_lo, c_search_hi, @as(f32, @floatFromInt(ci)) / 8.0);
                        const obj = evalAccentContribution(i, trial_L, trial_C, &accent_h, &cur_srgb, &affinity, &ideal_L, &accent_C, base00, base01, base02, L_lo, L_hi, c_ceiling[i], penalty_weight, config);
                        if (obj > best_obj) {
                            best_obj = obj;
                            best_L = trial_L;
                            best_C = trial_C;
                        }
                    }
                }
                param_L[i] = best_L;
                param_C[i] = best_C;
                cur_srgb[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(best_L, best_C, accent_h[i])));
            }
    }

    // Hard enforcement: clamp any remaining violations
    for (0..8) |i| {
        if (!accentContrastOk(param_L[i], param_C[i], accent_h[i], base00, base01, base02, config)) {
            const bound = computeLBound(param_C[i], accent_h[i], base00, base01, base02, mode, L_lo, L_hi, config);
            if (mode == .dark) {
                param_L[i] = @max(param_L[i], bound);
            } else {
                param_L[i] = @min(param_L[i], bound);
            }
        }
    }

    for (SEPARATION_PAIRS) |pair| {
        const min_cr = pair.cr orelse config.min_diff_pair_cr;
        const srgb_a = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[pair.a], param_C[pair.a], accent_h[pair.a])));
        const srgb_b = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[pair.b], param_C[pair.b], accent_h[pair.b])));
        if (color.contrastRatio(srgb_a, srgb_b) >= min_cr) continue;

        // Try moving each accent, preferring the lower-affinity one
        const order: [2]usize = if (affinity[pair.a] < affinity[pair.b])
            .{ pair.a, pair.b }
        else
            .{ pair.b, pair.a };

        for (order) |move_idx| {
            const fixed_idx: usize = if (move_idx == pair.a) pair.b else pair.a;
            const fixed_srgb_inner = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[fixed_idx], param_C[fixed_idx], accent_h[fixed_idx])));
            const fixed_Y = color.relativeLuminance(fixed_srgb_inner);
            const move_srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[move_idx], param_C[move_idx], accent_h[move_idx])));
            const move_Y = color.relativeLuminance(move_srgb);

            const push_up = move_Y > fixed_Y;
            var lo_s: f32 = param_L[move_idx];
            var hi_s: f32 = if (push_up) L_hi else L_lo;
            if (lo_s > hi_s) std.mem.swap(f32, &lo_s, &hi_s);

            for (0..20) |_| {
                const mid = (lo_s + hi_s) / 2.0;
                const trial = color.lchToSrgb(color.clipToGamut(color.Lch.init(mid, param_C[move_idx], accent_h[move_idx])));
                if (color.contrastRatio(trial, fixed_srgb_inner) >= min_cr) {
                    if (push_up) hi_s = mid else lo_s = mid;
                } else {
                    if (push_up) lo_s = mid else hi_s = mid;
                }
            }
            const candidate_L = if (push_up) lo_s else hi_s;
            const test_srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(candidate_L, param_C[move_idx], accent_h[move_idx])));
            if (color.contrastRatio(test_srgb, fixed_srgb_inner) >= min_cr and
                accentContrastOk(candidate_L, param_C[move_idx], accent_h[move_idx], base00, base01, base02, config))
            {
                param_L[move_idx] = candidate_L;
                break;
            }
        }
    }

    // Hue identity guarantee: each accent must remain within its semantic
    // band of its canonical target. Stacked pulls (peak + temperature) are
    // bounded by MAX_HUE_PULL and TEMPERATURE_PULL, and peak assignment is
    // gated by MAX_ASSIGNMENT_DISTANCE — so this assert should never fire.
    // It catches future regressions where new pulls or solver moves drift
    // an accent out of its band.
    if (std.debug.runtime_safety) {
        for (ACCENT_TARGETS, 0..) |target, i| {
            const dist = @abs(color.angularDiff(accent_h[i], target.h));
            std.debug.assert(dist <= MAX_ASSIGNMENT_DISTANCE);
        }
    }

    var result: [8]color.Srgb = undefined;
    var final_L: [8]f32 = undefined;
    for (0..8) |i| {
        result[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(param_L[i], param_C[i], accent_h[i])));
        final_L[i] = color.srgbToLch(result[i]).L;
    }

    const L_range = L_hi - L_lo;
    var score: f32 = 0;
    for (0..8) |i| {
        score += affinity[i] * @max(0.0, 1.0 - @abs(final_L[i] - ideal_L[i]) / L_range);
    }

    return .{ .result = result, .score = score };
}

fn sq(x: f32) f32 {
    return x * x;
}

/// Evaluate a single accent's objective contribution (feasibility-first).
fn evalAccentContribution(
    i: usize,
    trial_L: f32,
    trial_C: f32,
    h: *const [8]f32,
    all_srgb: *const [8]color.Srgb,
    affinity: *const [8]f32,
    ideal_L: *const [8]f32,
    ideal_C: *const [8]f32,
    bg0: color.Srgb,
    bg1: color.Srgb,
    bg2: color.Srgb,
    L_lo: f32,
    L_hi: f32,
    C_range: f32,
    penalty_weight: f32,
    config: Config,
) f32 {
    const L_range = L_hi - L_lo;
    const srgb_i = color.lchToSrgb(color.clipToGamut(color.Lch.init(trial_L, trial_C, h[i])));
    const actual_lch = color.srgbToLch(srgb_i);

    const a = affinity[i] + 0.01;
    const l_score = @max(0.0, 1.0 - @abs(actual_lch.L - ideal_L[i]) / L_range);
    const c_score = if (C_range > 0) @max(0.0, 1.0 - @abs(actual_lch.C - ideal_C[i]) / C_range) else 1.0;
    const fidelity_i: f32 = a * (l_score + 0.3 * c_score);

    var violation: f32 = 0;
    const cr0 = color.contrastRatio(srgb_i, bg0);
    const cr1 = color.contrastRatio(srgb_i, bg1);
    const cr2 = color.contrastRatio(srgb_i, bg2);
    if (cr0 < config.min_accent_contrast) violation += sq(config.min_accent_contrast - cr0);
    if (cr1 < config.min_accent_contrast) violation += sq(config.min_accent_contrast - cr1);
    if (cr2 < config.min_accent_contrast_bg2) violation += sq(config.min_accent_contrast_bg2 - cr2);

    for (SEPARATION_PAIRS) |pair| {
        if (pair.a != i and pair.b != i) continue;
        const other_idx: usize = if (pair.a == i) pair.b else pair.a;
        const cr = color.contrastRatio(srgb_i, all_srgb[other_idx]);
        const min_cr = pair.cr orelse config.min_diff_pair_cr;
        if (cr < min_cr) violation += sq(min_cr - cr);
    }

    var soft_penalty: f32 = 0;
    const lab_i = color.linearToLab(color.srgbToLinear(srgb_i));
    for (0..8) |j| {
        if (j == i) continue;
        const lab_j = color.linearToLab(color.srgbToLinear(all_srgb[j]));
        const de = color.labDist(lab_i, lab_j);
        if (de < config.min_pairwise_de) {
            soft_penalty += sq(config.min_pairwise_de - de);
        }
    }

    for (CVD_PAIRS) |cvd_pair| {
        if (cvd_pair.a != i and cvd_pair.b != i) continue;
        const other_idx: usize = if (cvd_pair.a == i) cvd_pair.b else cvd_pair.a;
        const cvd_de = switch (cvd_pair.cvd) {
            .protan => color.cvdDist(srgb_i, all_srgb[other_idx], .protan),
            .deutan => color.cvdDist(srgb_i, all_srgb[other_idx], .deutan),
        };
        if (cvd_de < config.min_cvd_de) {
            soft_penalty += sq(config.min_cvd_de - cvd_de);
        }
    }

    // L-spread harmony penalty: a vivid image can pull individual accents
    // to wildly different L values; this reins them back into a shared
    // band so the palette feels intentional rather than scattered.
    var min_other_L: f32 = std.math.floatMax(f32);
    var max_other_L: f32 = -std.math.floatMax(f32);
    for (all_srgb, 0..) |s, j| {
        if (j == i) continue;
        const Lj = color.srgbToLch(s).L;
        if (Lj < min_other_L) min_other_L = Lj;
        if (Lj > max_other_L) max_other_L = Lj;
    }
    const L_spread = @max(max_other_L, actual_lch.L) - @min(min_other_L, actual_lch.L);
    if (L_spread > ALLOWED_L_SPREAD) {
        soft_penalty += sq(L_spread - ALLOWED_L_SPREAD);
    }

    if (violation > 1e-6) {
        return -1000.0 - penalty_weight * violation;
    }
    return fidelity_i - 150.0 * soft_penalty;
}

fn computeLBound(C: f32, h: f32, bg0: color.Srgb, bg1: color.Srgb, bg2: color.Srgb, mode: Mode, L_lo: f32, L_hi: f32, config: Config) f32 {
    if (mode == .dark) {
        if (accentContrastOk(L_lo, C, h, bg0, bg1, bg2, config)) return L_lo;
        if (!accentContrastOk(L_hi, C, h, bg0, bg1, bg2, config)) return L_hi;
        var lo = L_lo;
        var hi = L_hi;
        for (0..24) |_| {
            const mid = (lo + hi) / 2.0;
            if (accentContrastOk(mid, C, h, bg0, bg1, bg2, config)) hi = mid else lo = mid;
        }
        return hi;
    } else {
        if (accentContrastOk(L_hi, C, h, bg0, bg1, bg2, config)) return L_hi;
        if (!accentContrastOk(L_lo, C, h, bg0, bg1, bg2, config)) return L_lo;
        var lo = L_lo;
        var hi = L_hi;
        for (0..24) |_| {
            const mid = (lo + hi) / 2.0;
            if (accentContrastOk(mid, C, h, bg0, bg1, bg2, config)) lo = mid else hi = mid;
        }
        return lo;
    }
}

// ─── Inter-accent contrast ────────────────────────────────────────────────────

const MIN_DIFF_PAIR_CR: f32 = 2.5;

const SeparationPair = struct { a: usize, b: usize, cr: ?f32 = null };
const SEPARATION_PAIRS = [_]SeparationPair{
    .{ .a = 0, .b = 5 }, // red   vs blue  (diff deletions on selection bg)
    .{ .a = 3, .b = 5 }, // green vs blue  (diff additions on selection bg)
    .{ .a = 0, .b = 3, .cr = 1.8 }, // red vs green (CVD: lower target, hue already distinct)
    .{ .a = 1, .b = 7, .cr = 1.5 }, // orange vs brown (prevent collapse, same hue family)
};

const CvdPair = struct { a: usize, b: usize, cvd: enum { protan, deutan } };
const CVD_PAIRS = [_]CvdPair{
    .{ .a = 0, .b = 3, .cvd = .deutan }, // red/green
    .{ .a = 5, .b = 6, .cvd = .protan }, // blue/purple
    .{ .a = 4, .b = 6, .cvd = .deutan }, // cyan/purple
    .{ .a = 1, .b = 3, .cvd = .protan }, // orange/green (protan)
    .{ .a = 1, .b = 3, .cvd = .deutan }, // orange/green (deutan)
};

fn accentContrastOk(L: f32, C: f32, h: f32, bg0: color.Srgb, bg1: color.Srgb, bg2: color.Srgb, config: Config) bool {
    const srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(L, C, h)));
    return color.contrastRatio(srgb, bg0) >= config.min_accent_contrast and
        color.contrastRatio(srgb, bg1) >= config.min_accent_contrast and
        color.contrastRatio(srgb, bg2) >= config.min_accent_contrast_bg2;
}

fn brightVariant(base: color.Srgb, backgrounds: [3]color.Srgb, config: Config) color.Srgb {
    var lch = color.srgbToLch(base);
    const target_L: f32 = @min(0.92, lch.L + config.bright_dl);
    lch.L = target_L;
    const gamut_max = color.maxGamutChroma(lch.L, lch.h);
    const c_headroom = @max(0.0, gamut_max - lch.C);
    lch.C += std.math.clamp(c_headroom * 0.3, 0.01, config.bright_dc + 0.02);

    const candidate = color.clipToGamut(lch);
    const srgb = color.lchToSrgb(candidate);
    if (brightContrastOk(srgb, backgrounds, config))
        return srgb;

    const accent_Y = color.relativeLuminance(srgb);
    const bg_Y = color.relativeLuminance(backgrounds[0]);
    const search_up = accent_Y > bg_Y;

    var lo_s: f32 = if (search_up) lch.L else 0.0;
    var hi_s: f32 = if (search_up) 1.0 else lch.L;

    for (0..20) |_| {
        const mid = (lo_s + hi_s) / 2.0;
        const trial = color.lchToSrgb(color.clipToGamut(color.Lch.init(mid, lch.C, lch.h)));
        const ok = brightContrastOk(trial, backgrounds, config);
        if (search_up) {
            if (ok) hi_s = mid else lo_s = mid;
        } else {
            if (ok) lo_s = mid else hi_s = mid;
        }
    }

    const result_L = if (search_up) hi_s else lo_s;
    return color.lchToSrgb(color.clipToGamut(color.Lch.init(result_L, lch.C, lch.h)));
}

fn brightContrastOk(srgb: color.Srgb, backgrounds: [3]color.Srgb, config: Config) bool {
    return color.contrastRatio(srgb, backgrounds[0]) >= config.min_accent_contrast and
        color.contrastRatio(srgb, backgrounds[1]) >= config.min_accent_contrast and
        color.contrastRatio(srgb, backgrounds[2]) >= config.min_accent_contrast_bg2;
}

/// Circular linear interpolation between two hue angles.
fn circLerp(a: f32, b: f32, t: f32) f32 {
    const diff = color.angularDiff(b, a); // signed shortest path
    return @mod(a + diff * t + 360.0, 360.0);
}

const SplitTone = struct { shadow_h: f32, highlight_h: f32 };

fn splitToneHues(profile: analysis.ImageProfile, primary: usize) SplitTone {
    const primary_h = profile.bucket_hues[primary];

    var second: usize = 0;
    var second_w: f32 = -1.0;
    for (profile.hue_weights, 0..) |w, bi| {
        if (bi == primary) continue;
        if (w > second_w) {
            second_w = w;
            second = bi;
        }
    }

    const hue_sep = @abs(color.angularDiff(primary_h, profile.bucket_hues[second]));
    if (hue_sep < 30.0 or second_w < profile.hue_weights[primary] * 0.15) {
        return .{ .shadow_h = primary_h, .highlight_h = primary_h };
    }

    const primary_L = profile.bucket_mean_L[primary];
    const second_L = profile.bucket_mean_L[second];
    if (primary_L <= second_L) {
        return .{ .shadow_h = primary_h, .highlight_h = profile.bucket_hues[second] };
    } else {
        return .{ .shadow_h = profile.bucket_hues[second], .highlight_h = primary_h };
    }
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

/// Build a synthetic cluster array for tests that need image-derived peaks.
/// Each (hue, weight) pair becomes one cluster at L=0.5, C=0.18.
fn testClusters(comptime entries: []const struct { h: f32, w: f32 }) struct {
    list: [analysis.MAX_CLUSTERS]analysis.ColorCluster,
    n: usize,
} {
    var out: [analysis.MAX_CLUSTERS]analysis.ColorCluster =
        .{analysis.ColorCluster{ .L = 0, .a = 0, .b = 0, .weight = 0 }} ** analysis.MAX_CLUSTERS;
    inline for (entries, 0..) |e, i| {
        const h_rad = e.h * std.math.pi / 180.0;
        out[i] = .{
            .L = 0.5,
            .a = 0.18 * @cos(h_rad),
            .b = 0.18 * @sin(h_rad),
            .weight = e.w,
        };
    }
    return .{ .list = out, .n = entries.len };
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
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.0,
        .chroma_upper = 0.0,
    };

    const palette = generate(black_profile, .dark, .{});

    const lch00 = color.srgbToLch(palette.base00);
    const lch07 = color.srgbToLch(palette.base07);
    try testing.expect(lch00.L < lch07.L);

    const lch10 = color.srgbToLch(palette.base10);
    const lch11 = color.srgbToLch(palette.base11);
    try testing.expect(lch11.L < lch10.L);
    try testing.expect(lch10.L < lch00.L);

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
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.0,
        .chroma_upper = 0.0,
    };

    const palette = generate(white_profile, null, .{}); // auto-detect → light

    const lch00 = color.srgbToLch(palette.base00);
    const lch07 = color.srgbToLch(palette.base07);
    try testing.expect(lch00.L > lch07.L);
}

test "hue semantics: red should land near red hue" {
    const testing = std.testing;
    var weights = [_]f32{0} ** 8;
    weights[0] = 1.0;
    var hues: [8]f32 = undefined;
    for (0..8) |i| hues[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;

    const cs = testClusters(&.{
        .{ .h = 25.0, .w = 0.7 },
        .{ .h = 15.0, .w = 0.2 },
        .{ .h = 35.0, .w = 0.1 },
    });

    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = weights,
        .bucket_hues = hues,
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.04,
        .chroma_upper = 0.20,
        .clusters = cs.list,
        .n_clusters = cs.n,
    };

    const palette = generate(profile, .dark, .{});
    const red_lch = color.srgbToLch(palette.base08);

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
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.03,
        .chroma_upper = 0.15,
    };

    const p = generate(profile, .dark, .{});

    const r_L = color.srgbToLch(p.base08).L;
    const br_L = color.srgbToLch(p.base12).L;
    try testing.expect(br_L > r_L - 1e-4);
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
    const vivid_cs = testClusters(&.{
        .{ .h = 22.0, .w = 0.6 },
        .{ .h = 60.0, .w = 0.3 },
        .{ .h = 100.0, .w = 0.1 },
    });
    const profiles = [_]analysis.ImageProfile{
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
            .bucket_mean_L = .{0.5} ** 8,
            .mean_hue = 0,
            .mean_hue_strength = 0,
            .chroma_lower = 0.05,
            .chroma_upper = 0.25,
            .clusters = vivid_cs.list,
            .n_clusters = vivid_cs.n,
        },
        // All-black degenerate (no clusters → all unassigned canonical hues)
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
            .bucket_mean_L = .{0.5} ** 8,
            .mean_hue = 0,
            .mean_hue_strength = 0,
            .chroma_lower = 0.0,
            .chroma_upper = 0.0,
        },
    };
    const modes = [_]Mode{ .dark, .light };

    for (profiles) |profile| {
        for (modes) |mode| {
            const p = generate(profile, mode, .{});
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
    const accent_cs = testClusters(&.{
        .{ .h = 25.0, .w = 0.6 },
        .{ .h = 145.0, .w = 0.3 },
        .{ .h = 265.0, .w = 0.1 },
    });
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
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.04,
        .chroma_upper = 0.20,
        .clusters = accent_cs.list,
        .n_clusters = accent_cs.n,
    };

    for ([_]Mode{ .dark, .light }) |mode| {
        const p = generate(profile, mode, .{});
        const accents = [_]color.Srgb{
            p.base08, p.base09, p.base0A, p.base0B,
            p.base0C, p.base0D, p.base0E, p.base0F,
        };
        for (accents) |accent| {
            try testing.expect(color.contrastRatio(accent, p.base00) >= MIN_ACCENT_CONTRAST);
            try testing.expect(color.contrastRatio(accent, p.base02) >= MIN_ACCENT_CONTRAST_BG2);
        }
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
    const tint_cs = testClusters(&.{
        .{ .h = 25.0, .w = 0.8 },
        .{ .h = 60.0, .w = 0.2 },
    });
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
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.05,
        .chroma_upper = 0.28,
        .clusters = tint_cs.list,
        .n_clusters = tint_cs.n,
    };

    const palette = generate(profile, .dark, .{});

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
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.0,
        .chroma_upper = 0.0,
    };

    const palette = generate(profile, .dark, .{});

    const lch00 = color.srgbToLch(palette.base00);
    const lch05 = color.srgbToLch(palette.base05);
    try testing.expectApproxEqAbs(0.0, lch00.C, 0.005);
    try testing.expectApproxEqAbs(0.0, lch05.C, 0.005);
}

test "diff-pair contrast: red and green are distinct from blue" {
    const testing = std.testing;
    const cs = testClusters(&.{
        .{ .h = 25.0, .w = 0.4 },
        .{ .h = 55.0, .w = 0.3 },
        .{ .h = 145.0, .w = 0.2 },
        .{ .h = 265.0, .w = 0.1 },
    });

    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = blk: {
            var w = [_]f32{0} ** 8;
            w[0] = 0.5;
            w[3] = 0.3;
            w[5] = 0.2;
            break :blk w;
        },
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.05,
        .chroma_upper = 0.22,
        .clusters = cs.list,
        .n_clusters = cs.n,
    };

    for ([_]Mode{ .dark, .light }) |mode| {
        const p = generate(profile, mode, .{});
        const cr_rb = color.contrastRatio(p.base08, p.base0D);
        const cr_gb = color.contrastRatio(p.base0B, p.base0D);
        const min_cr: f32 = if (mode == .light) 1.5 else MIN_DIFF_PAIR_CR;
        try testing.expect(cr_rb >= min_cr - 0.5);
        try testing.expect(cr_gb >= min_cr - 0.5);
        const cr_rg = color.contrastRatio(p.base08, p.base0B);
        try testing.expect(cr_rg >= 1.3);
    }
}

test "hue identity: each accent stays within its semantic range" {
    const testing = std.testing;
    const cs = testClusters(&.{
        .{ .h = 25.0, .w = 0.25 },
        .{ .h = 35.0, .w = 0.10 },
        .{ .h = 55.0, .w = 0.25 },
        .{ .h = 65.0, .w = 0.15 },
        .{ .h = 105.0, .w = 0.15 },
        .{ .h = 115.0, .w = 0.10 },
    });

    const profile = analysis.ImageProfile{
        .median_lightness = 0.35,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = blk: {
            var w = [_]f32{0} ** 8;
            w[0] = 0.5;
            w[1] = 0.3;
            w[2] = 0.2;
            break :blk w;
        },
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.05,
        .chroma_upper = 0.25,
        .clusters = cs.list,
        .n_clusters = cs.n,
    };

    const p = generate(profile, .dark, .{});

    const accents = [8]color.Srgb{
        p.base08, p.base09, p.base0A, p.base0B,
        p.base0C, p.base0D, p.base0E, p.base0F,
    };
    for (accents, 0..) |accent, i| {
        const lch = color.srgbToLch(accent);
        const dist = @abs(color.angularDiff(lch.h, ACCENT_TARGETS[i].h));
        try testing.expect(dist <= MAX_ASSIGNMENT_DISTANCE + 10.0);
    }
}

test "isClosestSlot: red peak assigned to red, not orange" {
    try std.testing.expect(isClosestSlot(0, 35.0));
    try std.testing.expect(!isClosestSlot(1, 35.0));
    try std.testing.expect(!isClosestSlot(0, 85.0));
}

test "nearestNeighborDist: expected distances" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(31.0, nearestNeighborDist(0), 0.1);
    try testing.expectApproxEqAbs(63.0, nearestNeighborDist(5), 0.1);
}

test "light mode accents are not too dark" {
    const testing = std.testing;
    const cs = testClusters(&.{
        .{ .h = 25.0, .w = 0.3 },
        .{ .h = 145.0, .w = 0.3 },
        .{ .h = 195.0, .w = 0.2 },
        .{ .h = 265.0, .w = 0.2 },
    });

    const profile = analysis.ImageProfile{
        .median_lightness = 0.65,
        .p10_lightness = 0.3,
        .p90_lightness = 0.9,
        .hue_weights = blk: {
            var w = [_]f32{0} ** 8;
            w[0] = 0.3;
            w[3] = 0.3;
            w[4] = 0.2;
            w[5] = 0.2;
            break :blk w;
        },
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .bucket_mean_L = .{0.5} ** 8,
        .mean_hue = 0,
        .mean_hue_strength = 0,
        .chroma_lower = 0.05,
        .chroma_upper = 0.22,
        .clusters = cs.list,
        .n_clusters = cs.n,
    };

    const p = generate(profile, .light, .{});
    const accents = [_]color.Srgb{
        p.base08, p.base09, p.base0A, p.base0B,
        p.base0C, p.base0D, p.base0E, p.base0F,
    };
    for (accents) |accent| {
        const lch = color.srgbToLch(accent);
        try testing.expect(lch.L >= 0.25);
    }
}
