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

/// Minimum contrast ratio for accents against base02 (selection highlight).
const MIN_ACCENT_CONTRAST_BG2: f32 = 2.5;

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
    /// Bright variant lightness boost.
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

/// Metrics for evaluating a palette's quality on both axes.
pub const Metrics = struct {
    /// Minimum WCAG contrast ratio across all accent-on-bg pairs.
    min_accent_bg_contrast: f32,
    /// Minimum WCAG contrast ratio across diff pairs (green/red on blue).
    min_diff_pair_contrast: f32,
    /// Number of accent slots filled from image peaks (0–8).
    slots_from_image: u8,
    /// Per-accent affinity (how much image data supports each accent).
    affinity: [8]f32,
    /// Per-accent OKLab Delta-L from image ideal (0 = perfect match).
    delta_L: [8]f32,
    /// Weighted fidelity cost: sum of |delta_L| * affinity.
    fidelity_cost: f32,
};

/// Compute quality metrics for a palette generated from a given profile + config.
pub fn metrics(profile: analysis.ImageProfile, forced_mode: ?Mode, config: Config) Metrics {
    const mode: Mode = forced_mode orelse
        if (profile.median_lightness < 0.5) .dark else .light;

    const tones = buildToneRamp(profile, mode);
    const sol = solveAccents(profile, mode, tones, config);
    const accents = sol.result;

    // Count image-influenced slots (continuous: affinity > threshold)
    var slots_from_image: u8 = 0;
    for (0..8) |i| {
        if (sol.affinity[i] > 0.05) slots_from_image += 1;
    }

    // Compute metrics
    var min_bg: f32 = 999.0;
    var delta: [8]f32 = undefined;
    var cost: f32 = 0;
    for (0..8) |i| {
        const cr0 = color.contrastRatio(accents[i], tones[0]);
        const cr1 = color.contrastRatio(accents[i], tones[1]);
        const cr2 = color.contrastRatio(accents[i], tones[2]);
        min_bg = @min(min_bg, @min(cr0, @min(cr1, cr2)));
        const lch = color.srgbToLch(accents[i]);
        delta[i] = lch.L - sol.ideal_L[i];
        cost += @abs(delta[i]) * sol.affinity[i];
    }

    var min_pair: f32 = 999.0;
    for (SEPARATION_PAIRS) |pair| {
        min_pair = @min(min_pair, color.contrastRatio(accents[pair[0]], accents[pair[1]]));
    }

    return .{
        .min_accent_bg_contrast = min_bg,
        .min_diff_pair_contrast = min_pair,
        .slots_from_image = slots_from_image,
        .affinity = sol.affinity,
        .delta_L = delta,
        .fidelity_cost = cost,
    };
}

/// Full trace of the accent solver's decisions at every stage.
/// Used by the devtui to show exactly how the palette was derived.
pub const AccentTrace = struct {
    // Image analysis inputs
    overall_scale: f32,
    c_ceiling: f32,

    // Stage 1: peak extraction
    peaks: [MAX_PEAKS]Peak,
    n_peaks: usize,
    sig_threshold: f32,
    sig_bins: [analysis.FINE_BINS]bool,

    // Stage 2: peak-to-slot assignment + hue selection
    assignments: [8]?usize,
    accent_h: [8]f32,

    // Stage 3: continuous affinity + ideal
    accent_C: [8]f32,
    ideal_L: [8]f32,
    affinity: [8]f32,
    img_data: [8]HueData,
    accent_L_base: f32,

    // Stage 4: iterative penalty-method optimisation
    L_bound: [8]f32,
    final_L: [8]f32,
    n_matchings_tried: usize,
    best_score: f32,

    // Final sRGB
    result: [8]color.Srgb,

    // Constants used
    L_lo: f32,
    L_hi: f32,
};

pub const ACCENT_NAMES = [8][]const u8{ "red", "orange", "yellow", "green", "cyan", "blue", "purple", "brown" };

/// Run the accent solver with full tracing of every intermediate value.
/// Delegates to solveAccents (same code path as generate()) and packages
/// the results for the devtui.
pub fn traceAccents(profile: analysis.ImageProfile, forced_mode: ?Mode, config: Config) AccentTrace {
    const mode: Mode = forced_mode orelse
        if (profile.median_lightness < 0.5) .dark else .light;
    const tones = buildToneRamp(profile, mode);
    const sol = solveAccents(profile, mode, tones, config);

    const sig_threshold: f32 = SIGNIFICANCE_FACTOR / @as(f32, @floatFromInt(analysis.FINE_BINS));
    var sig_bins: [analysis.FINE_BINS]bool = undefined;
    for (0..analysis.FINE_BINS) |bi| {
        sig_bins[bi] = profile.fine_hue_weights[bi] > sig_threshold;
    }

    return .{
        .overall_scale = sol.overall_scale,
        .c_ceiling = sol.c_ceiling,
        .peaks = sol.peaks,
        .n_peaks = sol.n_peaks,
        .sig_threshold = sig_threshold,
        .sig_bins = sig_bins,
        .assignments = sol.assignments,
        .accent_h = sol.accent_h,
        .accent_C = sol.accent_C,
        .ideal_L = sol.ideal_L,
        .affinity = sol.affinity,
        .img_data = sol.img_data,
        .accent_L_base = sol.accent_L_base,
        .L_bound = sol.L_bound,
        .final_L = sol.final_L,
        .n_matchings_tried = sol.n_matchings_tried,
        .best_score = sol.best_score,
        .result = sol.result,
        .L_lo = sol.L_lo,
        .L_hi = sol.L_hi,
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

/// Build the 8 accent slots [base08..0F]. Delegates to solveAccents.
fn buildAccents(profile: analysis.ImageProfile, mode: Mode, tones: [10]color.Srgb, config: Config) [8]color.Srgb {
    const r = solveAccents(profile, mode, tones, config);
    return r.result;
}

/// Internal solver result, used by both buildAccents and traceAccents.
const SolverResult = struct {
    result: [8]color.Srgb,
    accent_h: [8]f32,
    accent_C: [8]f32,
    affinity: [8]f32,
    img_data: [8]HueData,
    ideal_L: [8]f32,
    L_bound: [8]f32, // feasible boundary per accent (L_min dark, L_max light)
    final_L: [8]f32,
    assignments: [8]?usize,
    peaks: [MAX_PEAKS]Peak,
    n_peaks: usize,
    n_matchings_tried: usize,
    best_score: f32,
    overall_scale: f32,
    c_ceiling: f32,
    accent_L_base: f32,
    L_lo: f32,
    L_hi: f32,
};

/// Solve the full accent optimisation problem.
///
/// FORMULATION:
///
///   maximise  Σᵢ aᵢ · (1 − |Lᵢ − L*ᵢ| / L_range)    (weighted fidelity)
///
///   subject to:
///     CR(accᵢ, base0x) ≥ τ_bg                (bg contrast, per accent)
///     CR(accᵢ, accⱼ)   ≥ τ_diff              (diff-pair legibility)
///     |angDist(hᵢ, targetᵢ)| ≤ 45°           (semantic hue identity)
///
/// SOLUTION:
///   1. Enumerate all valid peak-to-slot matchings (typically < 100).
///   2. For each matching, run iterative penalty-method optimisation:
///      coordinate descent over (L, C) per accent, alternating with
///      joint grid search over coupled accents (red, green, blue).
///   3. Score each matching by fidelity; re-evaluate winner with full
///      3-round optimisation.
fn solveAccents(profile: analysis.ImageProfile, mode: Mode, tones: [10]color.Srgb, config: Config) SolverResult {
    const accent_L_base: f32 = if (mode == .dark) config.accent_l_dark else config.accent_l_light;
    const L_lo: f32 = if (mode == .dark) 0.45 else 0.35;
    const L_hi: f32 = if (mode == .dark) 0.85 else 0.70;
    const overall_scale = color.saturate(profile.p85_chroma / CHROMA_SCALE_REF);
    const C_ceiling = color.lerp(MIN_ACCENT_C, MAX_ACCENT_C, overall_scale);

    // In light mode, relax the diff-pair constraint. Blue (265°) is inherently
    // dark in sRGB, and a 2.5:1 diff-pair CR forces red/green to extreme
    // darkness (below L=0.30). 1.5:1 gives clear visual distinction without
    // making accents illegibly dark.
    var effective_config = config;
    if (mode == .light) {
        effective_config.min_diff_pair_cr = @min(config.min_diff_pair_cr, 1.5);
    }

    // Extract peaks
    var peaks: [MAX_PEAKS]Peak = undefined;
    const n_peaks = extractPeaks(profile, &peaks);

    // Enumerate all valid matchings and evaluate each
    var ctx = EnumCtx{
        .peaks = peaks[0..n_peaks],
        .profile = profile,
        .mode = mode,
        .config = effective_config,
        .tones = tones,
        .c_ceiling = C_ceiling,
        .accent_L_base = accent_L_base,
        .L_lo = L_lo,
        .L_hi = L_hi,
        .best_score = -std.math.inf(f32),
        .best_matching = .{null} ** 8,
        .n_tried = 0,
    };
    var current: [8]?usize = .{null} ** 8;
    var peak_used: [MAX_PEAKS]bool = .{false} ** MAX_PEAKS;
    enumerateRec(&ctx, 0, &current, &peak_used);

    // Re-evaluate the winning matching with full multi-round optimization
    const eval = evaluateMatching(ctx.best_matching, ctx.peaks, profile, mode, effective_config, tones, C_ceiling, accent_L_base, L_lo, L_hi, true);

    return .{
        .result = eval.result,
        .accent_h = eval.accent_h,
        .accent_C = eval.accent_C,
        .affinity = eval.affinity,
        .img_data = eval.img_data,
        .ideal_L = eval.ideal_L,
        .L_bound = eval.L_bound,
        .final_L = eval.final_L,
        .assignments = ctx.best_matching,
        .peaks = peaks,
        .n_peaks = n_peaks,
        .n_matchings_tried = ctx.n_tried,
        .best_score = ctx.best_score,
        .overall_scale = overall_scale,
        .c_ceiling = C_ceiling,
        .accent_L_base = accent_L_base,
        .L_lo = L_lo,
        .L_hi = L_hi,
    };
}

// ─── Assignment enumeration ──────────────────────────────────────────────────

const EnumCtx = struct {
    peaks: []const Peak,
    profile: analysis.ImageProfile,
    mode: Mode,
    config: Config,
    tones: [10]color.Srgb,
    c_ceiling: f32,
    accent_L_base: f32,
    L_lo: f32,
    L_hi: f32,
    best_score: f32,
    best_matching: [8]?usize,
    n_tried: usize,
};

fn enumerateRec(ctx: *EnumCtx, slot: usize, current: *[8]?usize, peak_used: *[MAX_PEAKS]bool) void {
    if (slot == 8) {
        const eval = evaluateMatching(current.*, ctx.peaks, ctx.profile, ctx.mode, ctx.config, ctx.tones, ctx.c_ceiling, ctx.accent_L_base, ctx.L_lo, ctx.L_hi, false);
        ctx.n_tried += 1;
        if (eval.score > ctx.best_score) {
            ctx.best_score = eval.score;
            ctx.best_matching = current.*;
        }
        return;
    }

    // Option 1: leave slot unassigned
    enumerateRec(ctx, slot + 1, current, peak_used);

    // Option 2: try each valid peak.
    // A peak is only valid for this slot if:
    //   (a) it's within MAX_ASSIGNMENT_DISTANCE of this slot's target, AND
    //   (b) no other slot's target is closer to this peak's hue.
    // This prevents a red peak (27°) from being assigned to orange (58°)
    // when it's obviously a better fit for the red slot (27°).
    for (ctx.peaks, 0..) |p, pi| {
        if (peak_used[pi]) continue;
        const dist = @abs(color.angularDiff(p.hue, ACCENT_TARGETS[slot].h));
        if (dist > MAX_ASSIGNMENT_DISTANCE) continue;
        if (!isClosestSlot(slot, p.hue)) continue;
        current[slot] = pi;
        peak_used[pi] = true;
        enumerateRec(ctx, slot + 1, current, peak_used);
        current[slot] = null;
        peak_used[pi] = false;
    }
}

// ─── Matching evaluation ─────────────────────────────────────────────────────

const EvalResult = struct {
    result: [8]color.Srgb,
    accent_h: [8]f32,
    accent_C: [8]f32,
    affinity: [8]f32,
    img_data: [8]HueData,
    ideal_L: [8]f32,
    L_bound: [8]f32,
    final_L: [8]f32,
    score: f32,
};

fn evaluateMatching(
    matching: [8]?usize,
    peaks: []const Peak,
    profile: analysis.ImageProfile,
    mode: Mode,
    config: Config,
    tones: [10]color.Srgb,
    c_ceiling: f32,
    accent_L_base: f32,
    L_lo: f32,
    L_hi: f32,
    comptime full: bool,
) EvalResult {
    const base00 = tones[0];
    const base01 = tones[1];
    const base02 = tones[2];

    // Step 1: per-accent hue (with inter-accent separation enforcement)
    var accent_h: [8]f32 = undefined;
    var img_data: [8]HueData = undefined;

    for (ACCENT_TARGETS, 0..) |target, i| {
        if (matching[i]) |peak_idx| {
            accent_h[i] = peaks[peak_idx].hue;
        } else {
            const sample = sampleHueData(profile, target.h);
            if (sample.weight > 1e-6) {
                // Limit pull to preserve hue identity: at most 40% of the
                // distance to the nearest distinct neighbor accent target.
                // This prevents red/orange/yellow from collapsing in warm images.
                const max_pull = @min(MAX_HUE_PULL, nearestNeighborDist(i) * 0.4);
                // Scale pull by evidence strength: if there's little image
                // data near this hue, barely pull. avg_weight = 1/FINE_BINS.
                const avg_weight: f32 = 1.0 / @as(f32, @floatFromInt(analysis.FINE_BINS));
                const evidence = color.saturate(sample.weight / (avg_weight * 3.0));
                const raw_pull = std.math.clamp(
                    color.angularDiff(sample.centroid_h, target.h),
                    -max_pull,
                    max_pull,
                );
                const pull = raw_pull * evidence;
                accent_h[i] = @mod(target.h + pull + 360.0, 360.0);
            } else {
                accent_h[i] = target.h;
            }
        }
    }

    for (0..8) |i| {
        img_data[i] = sampleHueData(profile, accent_h[i]);
    }

    // Step 2: continuous affinity (normalised Gaussian-sampled weight)
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
        accent_C[i] = @max(0.0, color.lerp(C_floor, c_ceiling, @sqrt(affinity[i])) + target.dC);
        ideal_L[i] = std.math.clamp(
            color.lerp(accent_L_base, img_data[i].L, affinity[i] * config.image_l_influence) + target.dL,
            L_lo,
            L_hi,
        );
    }

    // Cap chroma for hue-neighbor pairs to prevent gamut clipping from
    // collapsing them to the same sRGB color. When two accents have similar
    // hues, high chroma pushes both to the gamut boundary where they merge.
    // Reducing chroma on the lower-affinity accent preserves hue distinction.
    for (HUE_NEIGHBOR_PAIRS) |pair| {
        const a = pair[0];
        const b = pair[1];
        // Test at the representative L for the mode
        const test_L = accent_L_base;
        const srgb_a = color.lchToSrgb(color.clipToGamut(color.Lch.init(test_L, accent_C[a], accent_h[a])));
        const srgb_b = color.lchToSrgb(color.clipToGamut(color.Lch.init(test_L, accent_C[b], accent_h[b])));
        const lch_a = color.srgbToLch(srgb_a);
        const lch_b = color.srgbToLch(srgb_b);
        const hue_sep = @abs(color.angularDiff(lch_a.h, lch_b.h));
        // If post-clip hues are closer than 10°, the accents are indistinct
        if (hue_sep < 10.0) {
            // Reduce chroma on the lower-affinity accent
            const reduce_idx: usize = if (affinity[a] < affinity[b]) a else b;
            // Find the chroma where post-clip hue separation reaches 15°
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
                if (sep >= 15.0) {
                    lo_c = mid_c; // Can use more chroma
                } else {
                    hi_c = mid_c; // Need less chroma
                }
            }
            accent_C[reduce_idx] = lo_c;
        }
    }

    // Step 3: joint (L, C) optimisation via coordinate descent with penalty method.
    //
    // PARAMETERS: 16 continuous — (L_i, C_i) for each accent i ∈ [0,8).
    //   Hue is fixed by the matching (discrete outer loop).
    //
    // OBJECTIVE (maximise):
    //   fidelity(L, C) − λ · violation(L, C)
    //
    //   fidelity  = Σ_i  a_i · [1 − |L_i − L*_i|/L_range]  +  Σ_i  a_i · [1 − |C_i − C*_i|/C_range]
    //   violation = Σ penalties for:
    //     • bg contrast: max(0, min_cr − CR(accent_i, base00))²  (per accent, per bg)
    //     • diff-pair:   max(0, min_cr − CR(red, blue))²         (per pair)
    //
    // METHOD: coordinate descent — optimise each (L_i, C_i) independently while holding
    // others fixed. Repeat for multiple sweeps. For coupled constraints (diff pairs),
    // the penalty gradient naturally propagates through multiple sweeps.
    //
    // This evaluates the actual post-gamut-clip sRGB colors at every step,
    // so gamut clipping is handled implicitly.

    var param_L = ideal_L;
    var param_C = accent_C;

    // Initial feasibility: clamp L to bg-contrast bounds (good starting point)
    for (0..8) |i| {
        const bound = computeLBound(param_C[i], accent_h[i], base00, base01, base02, mode, L_lo, L_hi, config);
        if (mode == .dark) {
            param_L[i] = @max(param_L[i], bound);
        } else {
            param_L[i] = @min(param_L[i], bound);
        }
    }

    // Iterative optimisation: alternate between per-accent coordinate descent
    // and joint search over coupled accents (r, g, b). Each round propagates
    // information: the joint search moves coupled accents to satisfy diff-pair
    // constraints, then the next coordinate descent round re-optimises all
    // accents in light of those new positions.
    const penalty_weight: f32 = 500.0;

    // C search range: floor to slightly above ideal.
    // Keeping c_hi near accent_C prevents the optimizer from inflating chroma
    // on low-affinity accents, which would cause gamut-clip hue distortion.
    var c_lo: [8]f32 = undefined;
    var c_hi: [8]f32 = undefined;
    for (0..8) |i| {
        const C_floor: f32 = if (matching[i] != null) MIN_ACCENT_C else UNASSIGNED_ACCENT_C;
        c_lo[i] = C_floor;
        c_hi[i] = @min(c_ceiling, accent_C[i] + 0.03);
    }

    const n_rounds: usize = if (full) 3 else 1;
    for (0..n_rounds) |round| {
        // ── Per-accent coordinate descent ──
        // Full grid search over [L_lo, L_hi] × [c_lo, c_hi] for each accent
        // while holding others fixed. 4 sweeps per round.
        for (0..4) |_| {
            for (0..8) |i| {
                var best_obj: f32 = -std.math.inf(f32);
                var best_L: f32 = param_L[i];
                var best_C: f32 = param_C[i];

                const l_steps: usize = 32;
                const c_steps: usize = 8;
                var li: usize = 0;
                while (li <= l_steps) : (li += 1) {
                    const trial_L = L_lo + (L_hi - L_lo) * @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(l_steps));
                    var ci: usize = 0;
                    while (ci <= c_steps) : (ci += 1) {
                        const trial_C = color.lerp(c_lo[i], c_hi[i], @as(f32, @floatFromInt(ci)) / @as(f32, @floatFromInt(c_steps)));

                        const saved_L = param_L[i];
                        const saved_C = param_C[i];
                        param_L[i] = trial_L;
                        param_C[i] = trial_C;

                        const obj = evalObjective(&param_L, &param_C, &accent_h, &affinity, &ideal_L, &accent_C, base00, base01, base02, L_lo, L_hi, c_ceiling, penalty_weight, config);

                        param_L[i] = saved_L;
                        param_C[i] = saved_C;

                        if (obj > best_obj) {
                            best_obj = obj;
                            best_L = trial_L;
                            best_C = trial_C;
                        }
                    }
                }

                param_L[i] = best_L;
                param_C[i] = best_C;
            }
        }

        // ── Joint search over coupled (r, g, b) L values ──
        // Per-accent coordinate descent can't resolve coupled diff-pair
        // constraints. This 3D grid finds configurations that miss.
        // Coarser on early rounds (coord descent will refine), fine on final.
        {
            const ri: usize = 0; // red
            const gi: usize = 3; // green
            const bi: usize = 5; // blue
            const joint_steps: usize = if (round < n_rounds - 1) 12 else 24;
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
                        var obj: f32 = 0;
                        obj += (affinity[ri] + 0.01) * @max(0.0, 1.0 - @abs(lch_r.L - ideal_L[ri]) / L_range);
                        obj += (affinity[gi] + 0.01) * @max(0.0, 1.0 - @abs(lch_g.L - ideal_L[gi]) / L_range);
                        obj += (affinity[bi] + 0.01) * @max(0.0, 1.0 - @abs(lch_b.L - ideal_L[bi]) / L_range);

                        for ([3]color.Srgb{ srgb_r, srgb_g, srgb_b }) |s| {
                            const cr0 = color.contrastRatio(s, base00);
                            const cr2 = color.contrastRatio(s, base02);
                            if (cr0 < config.min_accent_contrast)
                                obj -= penalty_weight * sq(config.min_accent_contrast - cr0);
                            if (cr2 < config.min_accent_contrast_bg2)
                                obj -= penalty_weight * sq(config.min_accent_contrast_bg2 - cr2);
                        }

                        const cr_rb = color.contrastRatio(srgb_r, srgb_b);
                        const cr_gb = color.contrastRatio(srgb_g, srgb_b);
                        if (cr_rb < config.min_diff_pair_cr)
                            obj -= penalty_weight * sq(config.min_diff_pair_cr - cr_rb);
                        if (cr_gb < config.min_diff_pair_cr)
                            obj -= penalty_weight * sq(config.min_diff_pair_cr - cr_gb);

                        if (obj > best_obj) {
                            best_obj = obj;
                            best_Lr = trial_Lr;
                            best_Lg = trial_Lg;
                            best_Lb = trial_Lb;
                        }
                    }
                }
            }
            param_L[ri] = best_Lr;
            param_L[gi] = best_Lg;
            param_L[bi] = best_Lb;
        }

        // On the last round, do fine-grained refinement
        if (round == n_rounds - 1) {
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
                    // Also refine C: ±0.02 around current
                    const c_search_lo = @max(c_lo[i], param_C[i] - 0.02);
                    const c_search_hi = @min(c_hi[i], param_C[i] + 0.02);
                    var ci: usize = 0;
                    while (ci <= 8) : (ci += 1) {
                        const trial_C = color.lerp(c_search_lo, c_search_hi, @as(f32, @floatFromInt(ci)) / 8.0);
                        const saved_L = param_L[i];
                        const saved_C = param_C[i];
                        param_L[i] = trial_L;
                        param_C[i] = trial_C;
                        const obj = evalObjective(&param_L, &param_C, &accent_h, &affinity, &ideal_L, &accent_C, base00, base01, base02, L_lo, L_hi, c_ceiling, penalty_weight, config);
                        param_L[i] = saved_L;
                        param_C[i] = saved_C;
                        if (obj > best_obj) {
                            best_obj = obj;
                            best_L = trial_L;
                            best_C = trial_C;
                        }
                    }
                }
                param_L[i] = best_L;
                param_C[i] = best_C;
            }
        }
    }

    // Final hard enforcement of bg contrast (penalty method is soft — ensure hard satisfaction).
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

    // Produce final sRGB and score
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

    // L_bound for trace display
    var L_bound: [8]f32 = undefined;
    for (0..8) |i| {
        L_bound[i] = computeLBound(param_C[i], accent_h[i], base00, base01, base02, mode, L_lo, L_hi, config);
    }

    return .{
        .result = result,
        .accent_h = accent_h,
        .accent_C = accent_C,
        .affinity = affinity,
        .img_data = img_data,
        .ideal_L = ideal_L,
        .L_bound = L_bound,
        .final_L = final_L,
        .score = score,
    };
}

fn sq(x: f32) f32 {
    return x * x;
}

/// Evaluate the full objective for a candidate (L, C) configuration.
///
/// Returns fidelity reward minus constraint violation penalty.
/// All evaluation happens on actual post-gamut-clip sRGB, so gamut limits
/// are handled implicitly — no separate gamut projection step needed.
fn evalObjective(
    L: *const [8]f32,
    C: *const [8]f32,
    h: *const [8]f32,
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

    // Materialise sRGB for all accents
    var srgb: [8]color.Srgb = undefined;
    for (0..8) |i| {
        srgb[i] = color.lchToSrgb(color.clipToGamut(color.Lch.init(L[i], C[i], h[i])));
    }

    // Fidelity: weighted closeness to ideal L and C
    var fidelity: f32 = 0;
    for (0..8) |i| {
        const actual_lch = color.srgbToLch(srgb[i]);
        const a = affinity[i] + 0.01;
        const l_score = @max(0.0, 1.0 - @abs(actual_lch.L - ideal_L[i]) / L_range);
        const c_score = if (C_range > 0) @max(0.0, 1.0 - @abs(actual_lch.C - ideal_C[i]) / C_range) else 1.0;
        fidelity += a * (l_score + 0.3 * c_score);
    }

    // Penalty: bg contrast violations
    var penalty: f32 = 0;
    for (0..8) |i| {
        const cr0 = color.contrastRatio(srgb[i], bg0);
        const cr1 = color.contrastRatio(srgb[i], bg1);
        const cr2 = color.contrastRatio(srgb[i], bg2);
        if (cr0 < config.min_accent_contrast)
            penalty += sq(config.min_accent_contrast - cr0);
        if (cr1 < config.min_accent_contrast)
            penalty += sq(config.min_accent_contrast - cr1);
        if (cr2 < config.min_accent_contrast_bg2)
            penalty += sq(config.min_accent_contrast_bg2 - cr2);
    }

    // Penalty: diff-pair contrast violations
    for (SEPARATION_PAIRS) |pair| {
        const cr = color.contrastRatio(srgb[pair[0]], srgb[pair[1]]);
        if (cr < config.min_diff_pair_cr)
            penalty += sq(config.min_diff_pair_cr - cr);
    }

    return fidelity - penalty_weight * penalty;
}

/// Find the boundary of the bg-contrast feasible interval for one accent.
///
/// Dark mode: returns L_min (minimum L that satisfies contrast).
///   Feasible interval: [L_min, L_hi].
///   CR is monotonically increasing with L against dark bg.
///
/// Light mode: returns L_max (maximum L that satisfies contrast).
///   Feasible interval: [L_lo, L_max].
///   CR is monotonically increasing as L decreases against light bg.
fn computeLBound(C: f32, h: f32, bg0: color.Srgb, bg1: color.Srgb, bg2: color.Srgb, mode: Mode, L_lo: f32, L_hi: f32, config: Config) f32 {
    if (mode == .dark) {
        // Search for minimum feasible L (scanning upward)
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
        // Search for maximum feasible L (scanning downward)
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

/// Minimum WCAG contrast ratio between accent pairs that apps commonly overlay.
/// 2.5:1 is close to WCAG AA for large text and gives clear visual distinction.
const MIN_DIFF_PAIR_CR: f32 = 2.5;

/// Accent pairs that need minimum lightness separation.
/// Indices are ACCENT_TARGETS positions (0=red .. 6=purple, 7=brown).
/// These pairs arise in diff viewers (green/red on blue selection bg).
const SEPARATION_PAIRS = [_][2]usize{
    .{ 0, 5 }, // red   vs blue  (diff deletions on selection bg)
    .{ 3, 5 }, // green vs blue  (diff additions on selection bg)
};

fn accentContrastOk(L: f32, C: f32, h: f32, bg0: color.Srgb, bg1: color.Srgb, bg2: color.Srgb, config: Config) bool {
    const srgb = color.lchToSrgb(color.clipToGamut(color.Lch.init(L, C, h)));
    return color.contrastRatio(srgb, bg0) >= config.min_accent_contrast and
        color.contrastRatio(srgb, bg1) >= config.min_accent_contrast and
        color.contrastRatio(srgb, bg2) >= config.min_accent_contrast_bg2;
}

/// Bright variant of an accent colour: lighter + slightly more chromatic.
/// Contrast-checked against base00, base01, and base02 (same backgrounds
/// as normal accents) to ensure readability on all relevant surfaces.
fn brightVariant(base: color.Srgb, backgrounds: [3]color.Srgb, config: Config) color.Srgb {
    var lch = color.srgbToLch(base);
    lch.L = @min(1.0, lch.L + config.bright_dl);
    lch.C += config.bright_dc;

    const candidate = color.clipToGamut(lch);
    const srgb = color.lchToSrgb(candidate);
    if (brightContrastOk(srgb, backgrounds, config))
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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
    };

    const palette = generate(black_profile, .dark, .{});

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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
    };

    const palette = generate(white_profile, null, .{}); // auto-detect → light

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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
    };

    const palette = generate(profile, .dark, .{});
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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
    };

    const p = generate(profile, .dark, .{});

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
            .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
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
        // Bright variants: same contrast requirements as normal accents
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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
    };

    const palette = generate(profile, .dark, .{});

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
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.0} ** analysis.FINE_BINS,
    };

    const palette = generate(profile, .dark, .{});

    // Zero mean_chroma → tint_C_max = 0 → all tones should be achromatic
    // (tolerance accounts for f32 round-trip error through sRGB ↔ OKLCh)
    const lch00 = color.srgbToLch(palette.base00);
    const lch05 = color.srgbToLch(palette.base05);
    try testing.expectApproxEqAbs(0.0, lch00.C, 0.005);
    try testing.expectApproxEqAbs(0.0, lch05.C, 0.005);
}

test "diff-pair contrast: red and green are distinct from blue" {
    const testing = std.testing;
    // Vivid warm-dominated image that stresses diff-pair constraints
    var fine_w = [_]f32{0} ** analysis.FINE_BINS;
    fine_w[2] = 0.4; // red region (~25°)
    fine_w[5] = 0.3; // orange region (~55°)
    fine_w[14] = 0.2; // green region (~145°)
    fine_w[26] = 0.1; // blue region (~265°)

    const profile = analysis.ImageProfile{
        .median_lightness = 0.3,
        .p10_lightness = 0.1,
        .p90_lightness = 0.6,
        .hue_weights = blk: {
            var w = [_]f32{0} ** 8;
            w[0] = 0.5; // red/orange
            w[3] = 0.3; // green
            w[5] = 0.2; // blue
            break :blk w;
        },
        .bucket_hues = blk: {
            var h: [8]f32 = undefined;
            for (0..8) |i| h[i] = @as(f32, @floatFromInt(i)) * 45.0 + 22.5;
            break :blk h;
        },
        .mean_chroma = 0.15,
        .p85_chroma = 0.22,
        .fine_hue_weights = fine_w,
        .fine_hue_centroids = uniform_fine_centroids,
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.15} ** analysis.FINE_BINS,
    };

    for ([_]Mode{ .dark, .light }) |mode| {
        const p = generate(profile, mode, .{});
        // red vs blue
        const cr_rb = color.contrastRatio(p.base08, p.base0D);
        // green vs blue
        const cr_gb = color.contrastRatio(p.base0B, p.base0D);
        const min_cr: f32 = if (mode == .light) 1.5 else MIN_DIFF_PAIR_CR;
        try testing.expect(cr_rb >= min_cr - 0.05); // small tolerance for rounding
        try testing.expect(cr_gb >= min_cr - 0.05);
    }
}

test "hue identity: each accent stays within its semantic range" {
    const testing = std.testing;
    // Strongly warm image: all weight in the 0-120° range
    var fine_w = [_]f32{0} ** analysis.FINE_BINS;
    fine_w[2] = 0.25; // ~25° red
    fine_w[3] = 0.10; // ~35°
    fine_w[5] = 0.25; // ~55° orange
    fine_w[6] = 0.15; // ~65°
    fine_w[10] = 0.15; // ~105° yellow-ish
    fine_w[11] = 0.10; // ~115°

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
        .mean_chroma = 0.18,
        .p85_chroma = 0.25,
        .fine_hue_weights = fine_w,
        .fine_hue_centroids = uniform_fine_centroids,
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.15} ** analysis.FINE_BINS,
    };

    const p = generate(profile, .dark, .{});

    // Each accent's post-clip hue should be within MAX_ASSIGNMENT_DISTANCE
    // of its canonical target, even in a warm-dominated image
    const accents = [8]color.Srgb{
        p.base08, p.base09, p.base0A, p.base0B,
        p.base0C, p.base0D, p.base0E, p.base0F,
    };
    for (accents, 0..) |accent, i| {
        const lch = color.srgbToLch(accent);
        const dist = @abs(color.angularDiff(lch.h, ACCENT_TARGETS[i].h));
        try testing.expect(dist <= MAX_ASSIGNMENT_DISTANCE + 10.0); // allow gamut-clip drift
    }
}

test "isClosestSlot: red peak assigned to red, not orange" {
    // A peak at 35° is closer to red (27°) than orange (58°)
    try std.testing.expect(isClosestSlot(0, 35.0)); // red
    try std.testing.expect(!isClosestSlot(1, 35.0)); // not orange

    // A peak at 85° is closer to yellow (110°) or orange (58°)
    try std.testing.expect(!isClosestSlot(0, 85.0)); // not red
}

test "nearestNeighborDist: expected distances" {
    const testing = std.testing;
    // Red (27°) — nearest non-brown neighbor is orange (58°), distance 31°
    try testing.expectApproxEqAbs(31.0, nearestNeighborDist(0), 0.1);
    // Blue (265°) — nearest is cyan (195°) at 70° or purple (328°) at 63°
    try testing.expectApproxEqAbs(63.0, nearestNeighborDist(5), 0.1);
}

test "light mode accents are not too dark" {
    const testing = std.testing;
    // Light mode with vivid image — accents should be visible, not muddy
    var fine_w = [_]f32{0} ** analysis.FINE_BINS;
    fine_w[2] = 0.3;
    fine_w[14] = 0.3;
    fine_w[26] = 0.2;
    fine_w[19] = 0.2;

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
        .mean_chroma = 0.15,
        .p85_chroma = 0.22,
        .fine_hue_weights = fine_w,
        .fine_hue_centroids = uniform_fine_centroids,
        .fine_hue_lightness = .{0.5} ** analysis.FINE_BINS,
        .fine_hue_chroma = .{0.15} ** analysis.FINE_BINS,
    };

    const p = generate(profile, .light, .{});
    // In light mode, accents should not be darker than L=0.25
    // (the old bug pushed them below 0.30)
    const accents = [_]color.Srgb{
        p.base08, p.base09, p.base0A, p.base0B,
        p.base0C, p.base0D, p.base0E, p.base0F,
    };
    for (accents) |accent| {
        const lch = color.srgbToLch(accent);
        try testing.expect(lch.L >= 0.25);
    }
}
