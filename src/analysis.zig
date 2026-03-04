//! Image analysis: extract the colour character of an image.
//!
//! We sub-sample large images for speed, convert to OKLCh, and compute:
//!   • lightness percentiles (for tone-ramp anchoring and mode detection)
//!   • coarse (8×45°) and fine (36×10°) hue histograms, chroma-weighted
//!   • summary chroma statistics (to scale accent saturation)
//!
//! The result, ImageProfile, drives all palette-generation decisions.

const std = @import("std");
const color = @import("color.zig");
const image = @import("image.zig");

/// Maximum pixels to analyse; larger images are sub-sampled.
const SAMPLE_LIMIT: usize = 16_384;

/// Number of fine hue bins (10° each).
pub const FINE_BINS: usize = 36;

/// Colour character summary of an image.
pub const ImageProfile = struct {
    /// Median OKLab L value; < 0.5 → dark image, ≥ 0.5 → light image.
    median_lightness: f32,
    /// 10th-percentile lightness — the "shadow" level of the image.
    p10_lightness: f32,
    /// 90th-percentile lightness — the "highlight" level.
    p90_lightness: f32,
    /// Per-bucket hue weights, normalised to sum 1 (8 buckets × 45°).
    /// hue_weights[i] covers hues [i×45°, (i+1)×45°).
    hue_weights: [8]f32,
    /// Weighted centroid hue (degrees) within each bucket.
    /// Meaningful only when hue_weights[i] > 0.
    bucket_hues: [8]f32,
    /// Mean chroma of chromatic pixels (C > CHROMA_THRESHOLD).
    mean_chroma: f32,
    /// 85th-percentile chroma — representative of the most vivid pixels.
    p85_chroma: f32,
    /// Fine hue histogram: 36 bins × 10°, chroma-weighted, normalised to sum 1.
    fine_hue_weights: [FINE_BINS]f32,
    /// Circular mean hue (degrees) within each fine bin.
    fine_hue_centroids: [FINE_BINS]f32,
};

/// Pixels with chroma below this are considered grey/achromatic.
const CHROMA_THRESHOLD: f32 = 0.04;

pub fn analyze(img: image.Image, allocator: std.mem.Allocator) !ImageProfile {
    const total = img.pixels.len;
    const step = if (total > SAMPLE_LIMIT) total / SAMPLE_LIMIT else 1;
    const n_samples = (total + step - 1) / step;

    var lightness = try allocator.alloc(f32, n_samples);
    defer allocator.free(lightness);

    var hue_weight_acc = [_]f64{0} ** 8;
    var hue_sin_acc = [_]f64{0} ** 8;
    var hue_cos_acc = [_]f64{0} ** 8;
    var fine_weight_acc = [_]f64{0} ** FINE_BINS;
    var fine_sin_acc = [_]f64{0} ** FINE_BINS;
    var fine_cos_acc = [_]f64{0} ** FINE_BINS;
    var chroma_list = try std.ArrayList(f32).initCapacity(allocator, n_samples / 2);
    defer chroma_list.deinit(allocator);

    var n: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += step) {
        const px = img.pixels[i];
        const srgb = color.Srgb.fromBytes(px[0], px[1], px[2]);
        const lch = color.srgbToLch(srgb);

        lightness[n] = lch.L;
        n += 1;

        if (lch.C > CHROMA_THRESHOLD) {
            const h_rad = lch.h * (std.math.pi / 180.0);
            const sin_h: f64 = @sin(h_rad);
            const cos_h: f64 = @cos(h_rad);
            const c64: f64 = lch.C;

            const bucket: usize = @intFromFloat(@floor(lch.h / 45.0));
            const safe_bucket = bucket % 8;
            hue_weight_acc[safe_bucket] += c64;
            hue_sin_acc[safe_bucket] += c64 * sin_h;
            hue_cos_acc[safe_bucket] += c64 * cos_h;

            const fine_bin: usize = @intFromFloat(@floor(lch.h / 10.0));
            const safe_fine = fine_bin % FINE_BINS;
            fine_weight_acc[safe_fine] += c64;
            fine_sin_acc[safe_fine] += c64 * sin_h;
            fine_cos_acc[safe_fine] += c64 * cos_h;

            try chroma_list.append(allocator, lch.C);
        }
    }

    // Lightness percentiles
    const ls = lightness[0..n];
    std.mem.sort(f32, ls, {}, std.sort.asc(f32));
    const median_lightness = ls[n / 2];
    const p10_lightness = ls[n / 10];
    const p90_lightness = ls[(n * 9) / 10];

    // Hue weights (normalised) and bucket centroids
    var hue_total: f64 = 0;
    for (hue_weight_acc) |w| hue_total += w;

    var hue_weights = [_]f32{0} ** 8;
    var bucket_hues = [_]f32{0} ** 8;

    if (hue_total > 0) {
        for (0..8) |bi| {
            hue_weights[bi] = @floatCast(hue_weight_acc[bi] / hue_total);
            if (hue_weight_acc[bi] > 0) {
                // Circular mean within the bucket
                const angle = std.math.atan2(
                    @as(f64, hue_sin_acc[bi]),
                    @as(f64, hue_cos_acc[bi]),
                ) * (180.0 / std.math.pi);
                bucket_hues[bi] = @floatCast(@mod(angle + 360.0, 360.0));
            } else {
                // Empty bucket: use the bucket midpoint
                bucket_hues[bi] = @as(f32, @floatFromInt(bi)) * 45.0 + 22.5;
            }
        }
    } else {
        // Monochrome image: uniform hue distribution, midpoints as centroids
        for (0..8) |bi| {
            hue_weights[bi] = 1.0 / 8.0;
            bucket_hues[bi] = @as(f32, @floatFromInt(bi)) * 45.0 + 22.5;
        }
    }

    // Fine hue histogram (36 bins × 10°)
    var fine_total: f64 = 0;
    for (fine_weight_acc) |w| fine_total += w;

    var fine_hue_weights = [_]f32{0} ** FINE_BINS;
    var fine_hue_centroids = [_]f32{0} ** FINE_BINS;

    if (fine_total > 0) {
        for (0..FINE_BINS) |bi| {
            fine_hue_weights[bi] = @floatCast(fine_weight_acc[bi] / fine_total);
            if (fine_weight_acc[bi] > 0) {
                const angle = std.math.atan2(
                    @as(f64, fine_sin_acc[bi]),
                    @as(f64, fine_cos_acc[bi]),
                ) * (180.0 / std.math.pi);
                fine_hue_centroids[bi] = @floatCast(@mod(angle + 360.0, 360.0));
            } else {
                fine_hue_centroids[bi] = @as(f32, @floatFromInt(bi)) * 10.0 + 5.0;
            }
        }
    } else {
        // Monochrome image: uniform distribution, midpoints as centroids
        for (0..FINE_BINS) |bi| {
            fine_hue_weights[bi] = 1.0 / @as(f32, @floatFromInt(FINE_BINS));
            fine_hue_centroids[bi] = @as(f32, @floatFromInt(bi)) * 10.0 + 5.0;
        }
    }

    // Chroma statistics
    const cl = chroma_list.items;
    var mean_chroma: f32 = 0;
    var p85_chroma: f32 = 0;

    if (cl.len > 0) {
        var sum: f32 = 0;
        for (cl) |c| sum += c;
        mean_chroma = sum / @as(f32, @floatFromInt(cl.len));

        std.mem.sort(f32, cl, {}, std.sort.asc(f32));
        p85_chroma = cl[(cl.len * 85) / 100];
    }

    return .{
        .median_lightness = median_lightness,
        .p10_lightness = p10_lightness,
        .p90_lightness = p90_lightness,
        .hue_weights = hue_weights,
        .bucket_hues = bucket_hues,
        .mean_chroma = mean_chroma,
        .p85_chroma = p85_chroma,
        .fine_hue_weights = fine_hue_weights,
        .fine_hue_centroids = fine_hue_centroids,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "pure red image profile" {
    const testing = std.testing;
    // Synthesise a 10×10 pure-red image
    const pixels = [_][3]u8{.{ 255, 0, 0 }} ** 100;
    const img = image.Image{ .pixels = &pixels, .width = 10, .height = 10 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const profile = try analyze(img, arena.allocator());

    // Red has L around 0.6–0.7 in OKLab
    try testing.expect(profile.median_lightness > 0.5 and profile.median_lightness < 0.8);
    // Red hue ≈ 27°, so it should land in bucket 0 [0°, 45°)
    try testing.expect(profile.hue_weights[0] > 0.8);
    // Should have non-trivial chroma
    try testing.expect(profile.mean_chroma > 0.1);
    // Fine bin 2 [20°, 30°) should capture most red weight
    try testing.expect(profile.fine_hue_weights[2] > 0.5);
}

test "pure white image profile" {
    const testing = std.testing;
    const pixels = [_][3]u8{.{ 255, 255, 255 }} ** 100;
    const img = image.Image{ .pixels = &pixels, .width = 10, .height = 10 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const profile = try analyze(img, arena.allocator());

    // White is very light
    try testing.expect(profile.median_lightness > 0.9);
    // No chromatic pixels → monochrome uniform distribution
    try testing.expectApproxEqAbs(0.0, profile.mean_chroma, 1e-4);
    // Uniform hue weights
    for (profile.hue_weights) |w| {
        try testing.expectApproxEqAbs(1.0 / 8.0, w, 1e-4);
    }
    // Uniform fine hue weights
    for (profile.fine_hue_weights) |w| {
        try testing.expectApproxEqAbs(1.0 / 36.0, w, 1e-4);
    }
}

test "pure black image profile" {
    const testing = std.testing;
    const pixels = [_][3]u8{.{ 0, 0, 0 }} ** 100;
    const img = image.Image{ .pixels = &pixels, .width = 10, .height = 10 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const profile = try analyze(img, arena.allocator());

    try testing.expectApproxEqAbs(0.0, profile.median_lightness, 1e-3);
    try testing.expectApproxEqAbs(0.0, profile.mean_chroma, 1e-4);
}
