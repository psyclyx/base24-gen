//! Hue peak extraction and image hue sampling.
//!
//! Extracts dominant hue peaks from the fine histogram and provides
//! Gaussian-weighted sampling of image data at arbitrary hues.

const std = @import("std");
const color = @import("color.zig");
const analysis = @import("analysis.zig");

// ─── Constants ───────────────────────────────────────────────────────────────

/// Fine bins with weight > SIGNIFICANCE_FACTOR / FINE_BINS are "significant".
pub const SIGNIFICANCE_FACTOR: f32 = 1.5;
/// Maximum angular distance (degrees) for a peak to claim an accent slot.
pub const MAX_ASSIGNMENT_DISTANCE: f32 = 45.0;
/// Maximum number of peaks to extract from the fine histogram.
pub const MAX_PEAKS: usize = 8;

/// Gaussian kernel σ (degrees) for sampling hue data.
pub const HUE_SAMPLE_SIGMA: f32 = 30.0;
/// Maximum hue shift (degrees) for unassigned accents toward image centroid.
pub const MAX_HUE_PULL: f32 = 25.0;

/// Pairs of accents whose target hues are close enough that image pull can
/// collapse them. Checked after hue assignment to enforce minimum separation.
/// Indices are ACCENT_TARGETS positions.
pub const HUE_NEIGHBOR_PAIRS = [_][2]usize{
    .{ 0, 1 }, // red (27°)   vs orange (58°)    — 31° apart
    .{ 0, 7 }, // red (27°)   vs brown  (55°)    — 28° apart
    .{ 1, 7 }, // orange (58°) vs brown  (55°)   —  3° apart
    .{ 1, 2 }, // orange (58°) vs yellow (110°)  — 52° apart
    .{ 3, 4 }, // green (145°) vs cyan (195°)    — 50° apart
};

// ─── Accent hue targets ─────────────────────────────────────────────────────

/// Accent hue target — canonical hue plus optional L/C adjustments.
pub const AccentTarget = struct {
    h: f32,
    /// Lightness adjustment relative to accent_L (negative = darker).
    dL: f32 = 0,
    /// Chroma adjustment relative to accent_C (negative = less saturated).
    dC: f32 = 0,
};

pub const ACCENT_TARGETS = [8]AccentTarget{
    .{ .h = 27.0 }, // base08 red
    .{ .h = 58.0 }, // base09 orange
    .{ .h = 103.0, .dL = 0.10 }, // base0A yellow (inherently light in OKLCh)
    .{ .h = 145.0 }, // base0B green
    .{ .h = 195.0 }, // base0C cyan
    .{ .h = 265.0, .dL = -0.08 }, // base0D blue (inherently dark in sRGB gamut)
    .{ .h = 328.0 }, // base0E purple
    .{ .h = 55.0, .dL = -0.15, .dC = -0.07 }, // base0F brown (orange hue, dimmer)
};

// ─── Types ───────────────────────────────────────────────────────────────────

/// A hue peak extracted from the fine histogram.
pub const Peak = struct {
    hue: f32, // circular weighted mean centroid
    weight: f32, // summed weight of merged bins
};

/// Sampled image data at a hue: lightness, chroma, weight, and centroid hue.
pub const HueData = struct { L: f32, C: f32, weight: f32, centroid_h: f32 };

// ─── Peak extraction ─────────────────────────────────────────────────────────

/// Extract dominant hue peaks from the 36-bin fine histogram.
/// Merges adjacent significant bins into clusters. Returns count of peaks written.
pub fn extractPeaks(profile: analysis.ImageProfile, out: *[MAX_PEAKS]Peak) usize {
    const FINE_BINS = analysis.FINE_BINS;
    const threshold: f32 = SIGNIFICANCE_FACTOR / @as(f32, @floatFromInt(FINE_BINS));

    var significant: [FINE_BINS]bool = undefined;
    for (0..FINE_BINS) |bi| {
        significant[bi] = profile.fine_hue_weights[bi] > threshold;
    }

    var n_peaks: usize = 0;

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

    std.mem.sort(Peak, out[0..n_peaks], {}, struct {
        fn cmp(_: void, a: Peak, b: Peak) bool {
            return a.weight > b.weight;
        }
    }.cmp);

    return n_peaks;
}

// ─── Hue sampling ────────────────────────────────────────────────────────────

/// Sample the image's (L, C, weight, centroid_h) at a given hue using a
/// Gaussian-weighted average over nearby fine histogram bins.
///
/// centroid_h is the circular mean hue of the nearby image data — the hue
/// the image "wants" at this location. Used to pull unassigned accents
/// toward whatever image data exists near their canonical target.
pub fn sampleHueData(profile: analysis.ImageProfile, hue: f32) HueData {
    var wL: f64 = 0;
    var wC: f64 = 0;
    var ws: f64 = 0;
    var sin_acc: f64 = 0;
    var cos_acc: f64 = 0;
    const sigma2 = @as(f64, HUE_SAMPLE_SIGMA * HUE_SAMPLE_SIGMA);

    for (0..analysis.FINE_BINS) |fbi| {
        const w = profile.fine_hue_weights[fbi];
        if (w < 1e-6) continue;
        const dh: f64 = color.angularDiff(hue, profile.fine_hue_centroids[fbi]);
        const gauss = @exp(-(dh * dh) / (2.0 * sigma2));
        const combined: f64 = @as(f64, w) * gauss;
        wL += combined * @as(f64, profile.fine_hue_lightness[fbi]);
        wC += combined * @as(f64, profile.fine_hue_chroma[fbi]);
        const h_rad: f64 = @as(f64, profile.fine_hue_centroids[fbi]) * (std.math.pi / 180.0);
        sin_acc += combined * @sin(h_rad);
        cos_acc += combined * @cos(h_rad);
        ws += combined;
    }

    if (ws < 1e-9) return .{ .L = 0.5, .C = 0.0, .weight = 0.0, .centroid_h = hue };
    const angle = std.math.atan2(sin_acc, cos_acc) * (180.0 / std.math.pi);
    return .{
        .L = @floatCast(wL / ws),
        .C = @floatCast(wC / ws),
        .weight = @floatCast(ws),
        .centroid_h = @floatCast(@mod(angle + 360.0, 360.0)),
    };
}

// ─── Slot assignment helpers ─────────────────────────────────────────────────

/// Returns true if `slot` is the closest accent target to the given `hue`.
/// Ties go to the first slot (lower index).
pub fn isClosestSlot(slot: usize, hue: f32) bool {
    const dist = @abs(color.angularDiff(hue, ACCENT_TARGETS[slot].h));
    for (ACCENT_TARGETS, 0..) |target, j| {
        if (j == slot) continue;
        const d = @abs(color.angularDiff(hue, target.h));
        if (d < dist) return false;
    }
    return true;
}

/// Minimum angular distance (degrees) from accent `idx` to any other
/// accent target. Brown (idx 7, h=55°) is excluded since it intentionally
/// shares hue with orange and is differentiated by L/C.
pub fn nearestNeighborDist(idx: usize) f32 {
    var min_dist: f32 = 360.0;
    for (ACCENT_TARGETS, 0..) |other, j| {
        if (j == idx) continue;
        if (j == 7 or idx == 7) continue;
        const d = @abs(color.angularDiff(ACCENT_TARGETS[idx].h, other.h));
        if (d < min_dist) min_dist = d;
    }
    return min_dist;
}
