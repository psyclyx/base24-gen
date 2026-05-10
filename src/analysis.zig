//! Image analysis: extract the colour character of an image.
//!
//! We sub-sample large images for speed, convert to OKLCh, and compute:
//!   • lightness percentiles (for tone-ramp anchoring and mode detection)
//!   • coarse (8×45°) and fine (36×10°) hue histograms, chroma-weighted
//!   • two chroma signals via 1D k-means (k=2): the "quiet" cluster mean
//!     drives base tint, the "vivid" cluster mean drives accent ceiling
//!   • dominant colour clusters via 3D k-means in OKLab space — the actual
//!     colours present in the image as full (L, C, h) triples
//!
//! Every accumulator is weighted by a centred Gaussian over pixel position,
//! so the analysis biases toward whatever the image's focal subject is —
//! whether it's lighter or darker than the background. Polarity-agnostic.
//!
//! The result, ImageProfile, drives all palette-generation decisions.

const std = @import("std");
const color = @import("color.zig");
const image = @import("image.zig");

/// Maximum pixels to analyse; larger images are sub-sampled.
/// 65k is the cheapest size at which a small (~0.1%-area) chromatic region
/// still contributes enough samples to register in the k-means upper cluster
/// — at 16k, fixed-stride spatial sampling can miss a tightly-localised
/// vivid region entirely. Cost at this size is well under 100ms.
const SAMPLE_LIMIT: usize = 65_536;

/// Maximum dominant-colour clusters extracted by 3D OKLab k-means.
pub const MAX_CLUSTERS: usize = 8;

/// Spatial Gaussian σ as a fraction of min(width, height): the subject is
/// usually centred, so central pixels carry more analysis weight. Adjusting
/// this trades subject-focus (small) against full-image consideration (large).
const SPATIAL_SIGMA_FRAC: f32 = 1.0 / 3.0;

/// A dominant colour cluster found by 3D k-means in OKLab.
/// (a, b) are the OKLab chromaticity components — convert via
/// `chroma()` and `hue()` for OKLCh equivalents.
pub const ColorCluster = struct {
    L: f32,
    a: f32,
    b: f32,
    /// Sum of spatial-weighted membership, normalised so all clusters in
    /// a profile sum to 1.
    weight: f32,

    pub fn hue(self: ColorCluster) f32 {
        const angle: f64 = std.math.atan2(@as(f64, self.b), @as(f64, self.a)) * (180.0 / std.math.pi);
        return @floatCast(@mod(angle + 360.0, 360.0));
    }

    pub fn chroma(self: ColorCluster) f32 {
        return @sqrt(self.a * self.a + self.b * self.b);
    }
};

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
    /// Chroma-weighted mean OKLab L per bucket (0.5 for empty buckets).
    bucket_mean_L: [8]f32,
    /// k-means (k=2) lower-cluster mean over all-pixel chromas.
    /// The natural chroma of the image's quiet regions; drives base tint.
    chroma_lower: f32,
    /// k-means (k=2) upper-cluster mean over all-pixel chromas.
    /// The chroma of the image's vivid regions; drives accent ceiling.
    /// Collapses to chroma_lower when the distribution is unimodal.
    chroma_upper: f32,
    /// Circular weighted-mean hue (degrees) of all chromatic pixels — the
    /// image's overall "temperature." Used to bias unassigned accents
    /// toward the image's mood when the distribution is concentrated.
    mean_hue: f32,
    /// Mean resultant length (0..1) of the hue distribution. 1 = all hues
    /// agree (concentrated), 0 = uniform (mean_hue is meaningless). Used as
    /// a confidence weight on the temperature pull.
    mean_hue_strength: f32,
    /// Dominant colour clusters from 3D OKLab k-means on chromatic pixels,
    /// sorted by weight descending. Each cluster yields a peak with full
    /// (L, C, h) info — the primary input to accent generation.
    clusters: [MAX_CLUSTERS]ColorCluster = .{ColorCluster{ .L = 0, .a = 0, .b = 0, .weight = 0 }} ** MAX_CLUSTERS,
    /// Number of populated clusters in `clusters`.
    n_clusters: usize = 0,
};

/// Pixels with chroma below this are considered grey/achromatic.
const CHROMA_THRESHOLD: f32 = 0.04;

pub fn analyze(img: image.Image, allocator: std.mem.Allocator) !ImageProfile {
    const total = img.pixels.len;
    const step = if (total > SAMPLE_LIMIT) total / SAMPLE_LIMIT else 1;
    const n_samples = (total + step - 1) / step;

    var lightness = try allocator.alloc(f32, n_samples);
    defer allocator.free(lightness);
    var chromas = try allocator.alloc(f32, n_samples);
    defer allocator.free(chromas);
    var spatial_w = try allocator.alloc(f32, n_samples);
    defer allocator.free(spatial_w);

    var chromatic = try std.ArrayList(LabSample).initCapacity(allocator, n_samples / 2);
    defer chromatic.deinit(allocator);

    const w = img.width;
    const h = img.height;
    const cx: f32 = @as(f32, @floatFromInt(w)) * 0.5;
    const cy: f32 = @as(f32, @floatFromInt(h)) * 0.5;
    const min_dim: f32 = @floatFromInt(@min(w, h));
    const sigma: f32 = @max(1.0, min_dim * SPATIAL_SIGMA_FRAC);
    const inv_2sig2: f32 = 1.0 / (2.0 * sigma * sigma);

    var hue_weight_acc = [_]f64{0} ** 8;
    var hue_sin_acc = [_]f64{0} ** 8;
    var hue_cos_acc = [_]f64{0} ** 8;
    var hue_L_acc = [_]f64{0} ** 8;
    // Running totals for circular mean hue / resultant length.
    var sin_total: f64 = 0;
    var cos_total: f64 = 0;
    var hue_total: f64 = 0;

    var n: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += step) {
        const x: f32 = @floatFromInt(i % w);
        const y: f32 = @floatFromInt(i / w);
        const dx = x - cx;
        const dy = y - cy;
        const sw: f32 = @floatCast(std.math.exp(@as(f64, -(dx * dx + dy * dy) * inv_2sig2)));

        const px = img.pixels[i];
        const srgb = color.Srgb.fromBytes(px[0], px[1], px[2]);
        const lch = color.srgbToLch(srgb);

        lightness[n] = lch.L;
        chromas[n] = lch.C;
        spatial_w[n] = sw;
        n += 1;

        if (lch.C > CHROMA_THRESHOLD) {
            const h_rad = lch.h * (std.math.pi / 180.0);
            const sin_h: f64 = @sin(h_rad);
            const cos_h: f64 = @cos(h_rad);
            const c64: f64 = lch.C;
            const cw: f64 = c64 * @as(f64, sw);

            const bucket: usize = @intFromFloat(@floor(lch.h / 45.0));
            const safe_bucket = bucket % 8;
            hue_weight_acc[safe_bucket] += cw;
            hue_sin_acc[safe_bucket] += cw * sin_h;
            hue_cos_acc[safe_bucket] += cw * cos_h;
            hue_L_acc[safe_bucket] += cw * @as(f64, lch.L);

            sin_total += cw * sin_h;
            cos_total += cw * cos_h;
            hue_total += cw;

            try chromatic.append(allocator, .{
                .L = lch.L,
                .a = @floatCast(c64 * cos_h),
                .b = @floatCast(c64 * sin_h),
                .w = sw,
            });
        }
    }

    const ls = lightness[0..n];
    const sws = spatial_w[0..n];
    const median_lightness = try weightedPercentile(allocator, ls, sws, 0.5);
    const p10_lightness = try weightedPercentile(allocator, ls, sws, 0.10);
    const p90_lightness = try weightedPercentile(allocator, ls, sws, 0.90);

    var hue_weights = [_]f32{0} ** 8;
    var bucket_hues = [_]f32{0} ** 8;
    var bucket_mean_L = [_]f32{0.5} ** 8;

    if (hue_total > 0) {
        for (0..8) |bi| {
            hue_weights[bi] = @floatCast(hue_weight_acc[bi] / hue_total);
            if (hue_weight_acc[bi] > 0) {
                const angle = std.math.atan2(
                    @as(f64, hue_sin_acc[bi]),
                    @as(f64, hue_cos_acc[bi]),
                ) * (180.0 / std.math.pi);
                bucket_hues[bi] = @floatCast(@mod(angle + 360.0, 360.0));
                bucket_mean_L[bi] = @floatCast(hue_L_acc[bi] / hue_weight_acc[bi]);
            } else {
                bucket_hues[bi] = @as(f32, @floatFromInt(bi)) * 45.0 + 22.5;
            }
        }
    } else {
        for (0..8) |bi| {
            hue_weights[bi] = 1.0 / 8.0;
            bucket_hues[bi] = @as(f32, @floatFromInt(bi)) * 45.0 + 22.5;
        }
    }

    const mean_hue: f32 = if (hue_total > 1e-9) @floatCast(@mod(
        std.math.atan2(sin_total, cos_total) * (180.0 / std.math.pi) + 360.0,
        360.0,
    )) else 0.0;
    const mean_hue_strength: f32 = if (hue_total > 1e-9) @floatCast(
        @sqrt(sin_total * sin_total + cos_total * cos_total) / hue_total,
    ) else 0.0;

    const km = chromaSignals(chromas[0..n], spatial_w[0..n]);

    var clusters: [MAX_CLUSTERS]ColorCluster = .{ColorCluster{ .L = 0, .a = 0, .b = 0, .weight = 0 }} ** MAX_CLUSTERS;
    const n_clusters = try kmeans3OKLab(allocator, chromatic.items, MAX_CLUSTERS, &clusters);

    return .{
        .median_lightness = median_lightness,
        .p10_lightness = p10_lightness,
        .p90_lightness = p90_lightness,
        .hue_weights = hue_weights,
        .bucket_hues = bucket_hues,
        .bucket_mean_L = bucket_mean_L,
        .chroma_lower = km.lower,
        .chroma_upper = km.upper,
        .mean_hue = mean_hue,
        .mean_hue_strength = mean_hue_strength,
        .clusters = clusters,
        .n_clusters = n_clusters,
    };
}

// ─── Chroma signal: 1D weighted k-means with unimodal collapse ───────────────

const ChromaPair = struct { lower: f32, upper: f32 };

/// Distinguishes the image's quiet-region chroma from its vivid-region chroma
/// using 1D weighted k-means (k=2) on per-pixel chromas. When the two
/// clusters are less than COLLAPSE_THRESHOLD apart, the distribution is
/// treated as unimodal and both values collapse to the joint mean — this is
/// what monochrome and B&W images look like, and it correctly yields a
/// single vibrance level for both bases and accents.
fn chromaSignals(samples: []const f32, weights: []const f32) ChromaPair {
    const COLLAPSE_THRESHOLD: f32 = 0.03;
    const km = kmeans2WeightedChroma(samples, weights);
    if (km.upper - km.lower < COLLAPSE_THRESHOLD) {
        const joint = (km.lower + km.upper) * 0.5;
        return .{ .lower = joint, .upper = joint };
    }
    return km;
}

/// 1D weighted k-means with k=2: cluster means weighted by the spatial
/// (Gaussian-centre) sample weights. Initialised at min/max, iterated to
/// convergence (typically <10 rounds).
fn kmeans2WeightedChroma(samples: []const f32, weights: []const f32) ChromaPair {
    if (samples.len == 0) return .{ .lower = 0, .upper = 0 };

    var lo: f32 = samples[0];
    var hi: f32 = samples[0];
    for (samples) |s| {
        if (s < lo) lo = s;
        if (s > hi) hi = s;
    }
    if (hi - lo < 1e-6) return .{ .lower = lo, .upper = hi };

    var c_lo = lo;
    var c_hi = hi;
    var iter: u32 = 0;
    while (iter < 32) : (iter += 1) {
        const mid = (c_lo + c_hi) * 0.5;
        var sum_lo: f64 = 0;
        var w_lo: f64 = 0;
        var sum_hi: f64 = 0;
        var w_hi: f64 = 0;
        for (samples, weights) |s, w| {
            if (s < mid) {
                sum_lo += @as(f64, s) * @as(f64, w);
                w_lo += w;
            } else {
                sum_hi += @as(f64, s) * @as(f64, w);
                w_hi += w;
            }
        }
        const new_lo: f32 = if (w_lo > 1e-9) @floatCast(sum_lo / w_lo) else c_lo;
        const new_hi: f32 = if (w_hi > 1e-9) @floatCast(sum_hi / w_hi) else c_hi;
        const converged = @abs(new_lo - c_lo) < 1e-5 and @abs(new_hi - c_hi) < 1e-5;
        c_lo = new_lo;
        c_hi = new_hi;
        if (converged) break;
    }
    return .{ .lower = c_lo, .upper = c_hi };
}

// ─── Weighted lightness percentiles ──────────────────────────────────────────

fn weightedPercentile(
    allocator: std.mem.Allocator,
    values: []const f32,
    weights: []const f32,
    p: f32,
) !f32 {
    if (values.len == 0) return 0.5;
    var indices = try allocator.alloc(usize, values.len);
    defer allocator.free(indices);
    for (0..values.len) |k| indices[k] = k;
    std.mem.sort(usize, indices, values, struct {
        fn lt(vals: []const f32, a: usize, b: usize) bool {
            return vals[a] < vals[b];
        }
    }.lt);
    var total: f64 = 0;
    for (weights) |w| total += w;
    if (total < 1e-9) return values[indices[values.len / 2]];
    const target = p * total;
    var cum: f64 = 0;
    for (indices) |idx| {
        cum += weights[idx];
        if (cum >= target) return values[idx];
    }
    return values[indices[indices.len - 1]];
}

// ─── 3D OKLab k-means: dominant colour clusters ──────────────────────────────

const LabSample = struct { L: f32, a: f32, b: f32, w: f32 };

fn sqDist3(s: LabSample, c: ColorCluster) f32 {
    const dL = s.L - c.L;
    const da = s.a - c.a;
    const db = s.b - c.b;
    return dL * dL + da * da + db * db;
}

/// 3D weighted k-means in OKLab. K-means++ initialisation with a fixed
/// RNG seed for determinism, Lloyd's iterations to convergence. Returns
/// the number of clusters actually populated (≤ k); `out` is filled
/// sorted by cluster weight descending.
fn kmeans3OKLab(
    allocator: std.mem.Allocator,
    samples: []const LabSample,
    k: usize,
    out: *[MAX_CLUSTERS]ColorCluster,
) !usize {
    const n = samples.len;
    if (n == 0) return 0;
    const k_actual = @min(k, n);

    var min_dists = try allocator.alloc(f32, n);
    defer allocator.free(min_dists);
    var assignments = try allocator.alloc(u8, n);
    defer allocator.free(assignments);

    var rng_state = std.Random.DefaultPrng.init(0xDEADBEEFCAFEF00D);
    const rng = rng_state.random();

    var centroids: [MAX_CLUSTERS]ColorCluster = undefined;

    var total_w: f64 = 0;
    for (samples) |s| total_w += s.w;
    if (total_w < 1e-12) total_w = 1;

    // First centroid: weighted-random sample.
    {
        var r = rng.float(f64) * total_w;
        var pick: usize = n - 1;
        for (samples, 0..) |s, si| {
            r -= s.w;
            if (r <= 0) {
                pick = si;
                break;
            }
        }
        centroids[0] = .{ .L = samples[pick].L, .a = samples[pick].a, .b = samples[pick].b, .weight = 0 };
    }
    for (samples, 0..) |s, si| min_dists[si] = sqDist3(s, centroids[0]);

    // K-means++: each subsequent centroid is sampled with probability
    // proportional to its squared distance from the nearest existing centroid
    // (× its spatial weight).
    var ki: usize = 1;
    while (ki < k_actual) : (ki += 1) {
        var total_d: f64 = 0;
        for (samples, min_dists) |s, d| total_d += @as(f64, d) * @as(f64, s.w);
        if (total_d < 1e-12) break;
        var r = rng.float(f64) * total_d;
        var pick: usize = n - 1;
        for (samples, min_dists, 0..) |s, d, si| {
            r -= @as(f64, d) * @as(f64, s.w);
            if (r <= 0) {
                pick = si;
                break;
            }
        }
        centroids[ki] = .{ .L = samples[pick].L, .a = samples[pick].a, .b = samples[pick].b, .weight = 0 };
        for (samples, 0..) |s, si| {
            const d = sqDist3(s, centroids[ki]);
            if (d < min_dists[si]) min_dists[si] = d;
        }
    }
    const n_clusters = ki;
    if (n_clusters == 0) return 0;

    // Lloyd's iterations.
    @memset(assignments, 255);
    var iter: u32 = 0;
    while (iter < 30) : (iter += 1) {
        var any_changed = false;
        for (samples, 0..) |s, si| {
            var best_d: f32 = std.math.floatMax(f32);
            var best_k: u8 = 0;
            for (centroids[0..n_clusters], 0..) |c, ci| {
                const d = sqDist3(s, c);
                if (d < best_d) {
                    best_d = d;
                    best_k = @intCast(ci);
                }
            }
            if (assignments[si] != best_k) {
                assignments[si] = best_k;
                any_changed = true;
            }
        }
        if (!any_changed) break;

        var sum_L = [_]f64{0} ** MAX_CLUSTERS;
        var sum_a = [_]f64{0} ** MAX_CLUSTERS;
        var sum_b = [_]f64{0} ** MAX_CLUSTERS;
        var sum_w = [_]f64{0} ** MAX_CLUSTERS;
        for (samples, assignments) |s, kk| {
            sum_L[kk] += @as(f64, s.L) * @as(f64, s.w);
            sum_a[kk] += @as(f64, s.a) * @as(f64, s.w);
            sum_b[kk] += @as(f64, s.b) * @as(f64, s.w);
            sum_w[kk] += s.w;
        }
        for (0..n_clusters) |kk| {
            if (sum_w[kk] > 1e-9) {
                centroids[kk].L = @floatCast(sum_L[kk] / sum_w[kk]);
                centroids[kk].a = @floatCast(sum_a[kk] / sum_w[kk]);
                centroids[kk].b = @floatCast(sum_b[kk] / sum_w[kk]);
            }
        }
    }

    // Final cluster weights, normalised to sum 1.
    var weights_per = [_]f64{0} ** MAX_CLUSTERS;
    for (samples, assignments) |s, kk| {
        if (kk < n_clusters) weights_per[kk] += s.w;
    }
    var temp: [MAX_CLUSTERS]ColorCluster = undefined;
    for (0..n_clusters) |kk| {
        temp[kk] = .{
            .L = centroids[kk].L,
            .a = centroids[kk].a,
            .b = centroids[kk].b,
            .weight = @floatCast(weights_per[kk] / total_w),
        };
    }
    std.mem.sort(ColorCluster, temp[0..n_clusters], {}, struct {
        fn cmp(_: void, a: ColorCluster, b: ColorCluster) bool {
            return a.weight > b.weight;
        }
    }.cmp);
    for (0..n_clusters) |kk| out[kk] = temp[kk];
    return n_clusters;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "pure red image profile" {
    const testing = std.testing;
    const pixels = [_][3]u8{.{ 255, 0, 0 }} ** 100;
    const img = image.Image{ .pixels = &pixels, .width = 10, .height = 10 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const profile = try analyze(img, arena.allocator());

    try testing.expect(profile.median_lightness > 0.5 and profile.median_lightness < 0.8);
    try testing.expect(profile.hue_weights[0] > 0.8);
    // Monochrome image → unimodal → both signals collapse to the same vivid value.
    try testing.expectApproxEqAbs(profile.chroma_lower, profile.chroma_upper, 1e-5);
    try testing.expect(profile.chroma_upper > 0.1);
    // 3D clustering finds at least one red-region cluster.
    try testing.expect(profile.n_clusters >= 1);
    const dominant = profile.clusters[0];
    try testing.expect(dominant.hue() < 50.0 or dominant.hue() > 320.0);
}

test "pure white image profile" {
    const testing = std.testing;
    const pixels = [_][3]u8{.{ 255, 255, 255 }} ** 100;
    const img = image.Image{ .pixels = &pixels, .width = 10, .height = 10 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const profile = try analyze(img, arena.allocator());

    try testing.expect(profile.median_lightness > 0.9);
    try testing.expectApproxEqAbs(0.0, profile.chroma_lower, 1e-4);
    try testing.expectApproxEqAbs(0.0, profile.chroma_upper, 1e-4);
    for (profile.hue_weights) |w| {
        try testing.expectApproxEqAbs(1.0 / 8.0, w, 1e-4);
    }
    // No chromatic pixels → no clusters extracted.
    try testing.expectEqual(@as(usize, 0), profile.n_clusters);
}

test "pure black image profile" {
    const testing = std.testing;
    const pixels = [_][3]u8{.{ 0, 0, 0 }} ** 100;
    const img = image.Image{ .pixels = &pixels, .width = 10, .height = 10 };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const profile = try analyze(img, arena.allocator());

    try testing.expectApproxEqAbs(0.0, profile.median_lightness, 1e-3);
    try testing.expectApproxEqAbs(0.0, profile.chroma_lower, 1e-4);
    try testing.expectApproxEqAbs(0.0, profile.chroma_upper, 1e-4);
}

test "k-means: bimodal chroma distribution separates clusters" {
    const testing = std.testing;
    var samples: [200]f32 = undefined;
    var weights: [200]f32 = undefined;
    for (0..100) |k| {
        samples[k] = 0.02 + 0.005 * @as(f32, @floatFromInt(k % 3));
        weights[k] = 1.0;
    }
    for (100..200) |k| {
        samples[k] = 0.20 + 0.005 * @as(f32, @floatFromInt(k % 3));
        weights[k] = 1.0;
    }

    const r = chromaSignals(&samples, &weights);
    try testing.expect(r.upper - r.lower > 0.10);
    try testing.expect(r.lower < 0.05);
    try testing.expect(r.upper > 0.15);
}

test "k-means: unimodal distribution collapses to single value" {
    const testing = std.testing;
    var samples: [100]f32 = undefined;
    var weights: [100]f32 = undefined;
    for (0..100) |k| {
        samples[k] = 0.10 + 0.005 * @as(f32, @floatFromInt(k % 3));
        weights[k] = 1.0;
    }

    const r = chromaSignals(&samples, &weights);
    try testing.expectApproxEqAbs(r.lower, r.upper, 1e-5);
    try testing.expect(r.lower > 0.09 and r.lower < 0.13);
}

test "k-means: small high-chroma minority still drives the upper cluster" {
    const testing = std.testing;
    var samples: [100]f32 = undefined;
    var weights: [100]f32 = undefined;
    for (0..99) |k| {
        samples[k] = 0.01;
        weights[k] = 1.0;
    }
    samples[99] = 0.25;
    weights[99] = 1.0;

    const r = chromaSignals(&samples, &weights);
    try testing.expect(r.upper > 0.20);
    try testing.expect(r.lower < 0.05);
}

test "kmeans3OKLab: separates well-defined color clusters" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Two synthetic clusters: warm reddish (a positive, b near 0) and cool
    // bluish (a near 0, b negative).
    var samples: [200]LabSample = undefined;
    for (0..100) |k| samples[k] = .{
        .L = 0.5 + 0.01 * @as(f32, @floatFromInt(k % 5)),
        .a = 0.15,
        .b = 0.02,
        .w = 1.0,
    };
    for (100..200) |k| samples[k] = .{
        .L = 0.4 + 0.01 * @as(f32, @floatFromInt(k % 5)),
        .a = 0.0,
        .b = -0.18,
        .w = 1.0,
    };

    var clusters: [MAX_CLUSTERS]ColorCluster = undefined;
    const nc = try kmeans3OKLab(arena.allocator(), &samples, 2, &clusters);
    try testing.expectEqual(@as(usize, 2), nc);

    // Each input cluster's weight is 50% of the total.
    try testing.expectApproxEqAbs(@as(f32, 0.5), clusters[0].weight, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 0.5), clusters[1].weight, 0.05);

    // The two cluster centroids should be far apart in OKLab.
    const dL = clusters[0].L - clusters[1].L;
    const da = clusters[0].a - clusters[1].a;
    const db = clusters[0].b - clusters[1].b;
    try testing.expect(@sqrt(dL * dL + da * da + db * db) > 0.15);
}
