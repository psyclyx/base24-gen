//! base24-gen devtool: step-by-step accent solver trace.
//!
//! Shows each stage of the optimisation pipeline so you can see exactly
//! how the final palette was derived from the image.
//!
//! Stages:
//!   1. Hue histogram — significant bins and extracted peaks
//!   2. Hue selection — peak assignment + centroid pull for unassigned
//!   3. Continuous affinity + ideal (h, C, L) per accent
//!   4. Constrained L solver (contrast bounds + r/g/b separation, closed-form QP)
//!   5. Final palette + metrics
//!
//! Navigation:  j/k or up/dn = scroll stages   q = quit
//!
//! Usage:  zig build devtui -- <image>

const std = @import("std");
const color = @import("color.zig");
const image_mod = @import("image.zig");
const analysis = @import("analysis.zig");
const pal_mod = @import("palette.zig");
const Config = pal_mod.Config;
const posix = std.posix;

const NUM_STAGES = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll("Usage: devtui <image>\n");
        std.process.exit(1);
    }

    const img_path_z = try allocator.dupeZ(u8, args[1]);
    defer allocator.free(img_path_z);

    const img = image_mod.load(img_path_z.ptr) catch {
        try std.fs.File.stderr().writeAll("Failed to load image\n");
        std.process.exit(1);
    };
    defer img.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const profile = try analysis.analyze(img, arena.allocator());

    const mode: pal_mod.Mode =
        if (profile.median_lightness < 0.5) .dark else .light;

    const trace = pal_mod.traceAccents(profile, null, .{});
    const pal = pal_mod.generate(profile, null, .{});
    const m = pal_mod.metrics(profile, null, .{});

    // Enter raw terminal mode
    const tty_fd: posix.fd_t = 0;
    const orig = posix.tcgetattr(tty_fd) catch {
        try std.fs.File.stderr().writeAll("devtui: must be run in an interactive terminal\n");
        std.process.exit(1);
    };
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.os.linux.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.os.linux.V.TIME)] = 2;
    try posix.tcsetattr(tty_fd, .NOW, raw);
    defer posix.tcsetattr(tty_fd, .NOW, orig) catch {};

    try std.fs.File.stdout().writeAll("\x1b[?25l");
    defer std.fs.File.stdout().writeAll("\x1b[?25h") catch {};

    var stage: usize = 0;
    var needs_redraw = true;
    while (true) {
        if (needs_redraw) {
            try render(allocator, args[1], mode, profile, trace, pal, m, stage);
            needs_redraw = false;
        }
        switch (readKey(tty_fd)) {
            .quit => break,
            .up => {
                if (stage > 0) stage -= 1;
                needs_redraw = true;
            },
            .down => {
                if (stage < NUM_STAGES - 1) stage += 1;
                needs_redraw = true;
            },
            .none => {},
        }
    }
    try std.fs.File.stdout().writeAll("\x1b[2J\x1b[H\x1b[?25h");
}

const Key = enum { quit, up, down, none };

fn readKey(fd: posix.fd_t) Key {
    var buf: [8]u8 = undefined;
    const n = posix.read(fd, &buf) catch return .none;
    if (n == 0) return .none;
    if (buf[0] == 'q' or buf[0] == 3) return .quit;
    if (buf[0] == 'k') return .up;
    if (buf[0] == 'j') return .down;
    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .up,
            'B' => .down,
            else => .none,
        };
    }
    return .none;
}

// ─── Rendering ───────────────────────────────────────────────────────────────

fn render(
    a: std.mem.Allocator,
    img_name: []const u8,
    mode: pal_mod.Mode,
    profile: analysis.ImageProfile,
    trace: pal_mod.AccentTrace,
    pal: pal_mod.Palette,
    m: pal_mod.Metrics,
    stage: usize,
) !void {
    const out = std.fs.File.stdout();
    try out.writeAll("\x1b[H\x1b[2J");

    // Header + palette swatches (always visible)
    {
        const hdr = try std.fmt.allocPrint(a,
            "\x1b[1mbase24-gen trace\x1b[0m  {s}  {s} mode\n\n",
            .{ std.fs.path.basename(img_name), @tagName(mode) },
        );
        defer a.free(hdr);
        try out.writeAll(hdr);
    }
    const slots = pal.slots();
    try renderRow(a, out, slots[0..8]);
    try renderRow(a, out, slots[8..16]);
    try renderRow(a, out, slots[16..24]);
    try out.writeAll("\n");

    // Stage list
    const stage_names = [NUM_STAGES][]const u8{
        "1. Hue histogram + peaks",
        "2. Hue selection (peak assign + centroid pull)",
        "3. Continuous affinity + ideal (h, C, L)",
        "4. Constrained L solver (contrast + separation)",
        "5. Final palette + metrics",
    };
    for (stage_names, 0..) |name, i| {
        if (i == stage) {
            const line = try std.fmt.allocPrint(a, "  \x1b[1;33m> {s}\x1b[0m\n", .{name});
            defer a.free(line);
            try out.writeAll(line);
        } else {
            const line = try std.fmt.allocPrint(a, "  \x1b[2m  {s}\x1b[0m\n", .{name});
            defer a.free(line);
            try out.writeAll(line);
        }
    }
    try out.writeAll("\n");

    // Stage detail
    switch (stage) {
        0 => try renderStage1(a, out, profile, trace),
        1 => try renderStage2(a, out, trace),
        2 => try renderStage3(a, out, trace),
        3 => try renderStage4(a, out, trace, mode),
        4 => try renderStage5(a, out, trace, pal, m),
        else => {},
    }

    try out.writeAll("\n  \x1b[2mj/k or up/dn: navigate stages   q: quit\x1b[0m\n");
}

fn renderStage1(a: std.mem.Allocator, out: std.fs.File, profile: analysis.ImageProfile, trace: pal_mod.AccentTrace) !void {
    {
        const line = try std.fmt.allocPrint(a,
            "  sig threshold: {d:.4}  (bins > this are significant)\n\n",
            .{trace.sig_threshold},
        );
        defer a.free(line);
        try out.writeAll(line);
    }

    // Mini hue histogram
    try out.writeAll("  \x1b[2mhue histogram (36 bins x 10deg, * = significant):\x1b[0m\n  ");
    for (0..analysis.FINE_BINS) |bi| {
        const w = profile.fine_hue_weights[bi];
        const bar: u8 = @intFromFloat(@min(8.0, w * 200.0));
        const chars = " .:-=+*#@";
        const ch = try std.fmt.allocPrint(a, "{c}", .{chars[bar]});
        defer a.free(ch);
        if (trace.sig_bins[bi]) {
            try out.writeAll("\x1b[33m");
            try out.writeAll(ch);
            try out.writeAll("\x1b[0m");
        } else {
            try out.writeAll(ch);
        }
    }
    try out.writeAll("\n  ");
    {
        var bi: usize = 0;
        while (bi < analysis.FINE_BINS) {
            if (bi % 9 == 0) {
                const deg = try std.fmt.allocPrint(a, "{}", .{bi * 10});
                defer a.free(deg);
                try out.writeAll(deg);
                // Label consumed deg.len columns; advance past them
                bi += deg.len;
            } else {
                try out.writeAll(" ");
                bi += 1;
            }
        }
    }
    try out.writeAll("\n\n");

    {
        const line = try std.fmt.allocPrint(a,
            "  {d} peaks extracted:\n",
            .{trace.n_peaks},
        );
        defer a.free(line);
        try out.writeAll(line);
    }
    for (0..trace.n_peaks) |i| {
        const p = trace.peaks[i];
        const line = try std.fmt.allocPrint(a,
            "    peak {}: hue={d:.1} weight={d:.4}\n",
            .{ i, p.hue, p.weight },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
    {
        const line = try std.fmt.allocPrint(a,
            "\n  overall_scale: {d:.3}  C_ceiling: {d:.3}\n",
            .{ trace.overall_scale, trace.c_ceiling },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
}

fn renderStage2(a: std.mem.Allocator, out: std.fs.File, trace: pal_mod.AccentTrace) !void {
    try out.writeAll("  \x1b[2mPeak-assigned accents use peak hue; unassigned get centroid pull.\x1b[0m\n\n");
    try out.writeAll("  \x1b[2mslot      target  chosen  shift  source\x1b[0m\n");
    const target_hues = [8]f32{ 27.0, 58.0, 110.0, 145.0, 195.0, 265.0, 328.0, 55.0 };
    for (0..8) |i| {
        const name = pal_mod.ACCENT_NAMES[i];
        const th = target_hues[i];
        const ch = trace.accent_h[i];
        const shift = color.angularDiff(ch, th);
        const src: []const u8 = if (trace.assignments[i] != null) "\x1b[32mpeak\x1b[0m" else if (@abs(shift) > 0.5) "\x1b[36mcentroid pull\x1b[0m" else "\x1b[2mcanonical\x1b[0m";
        const line = try std.fmt.allocPrint(a,
            "  {s: <8} {d:>6.1}  {d:>6.1}  {d:>6.1}  {s}\n",
            .{ name, th, ch, shift, src },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
}

fn renderStage3(a: std.mem.Allocator, out: std.fs.File, trace: pal_mod.AccentTrace) !void {
    {
        const line = try std.fmt.allocPrint(a,
            "  accent_L_base: {d:.2}   L range: [{d:.2}, {d:.2}]\n" ++
                "  \x1b[2mAffinity = Gaussian-sampled image weight (continuous, not binary)\x1b[0m\n\n",
            .{ trace.accent_L_base, trace.L_lo, trace.L_hi },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
    try out.writeAll("  \x1b[2mslot      hue     C      aff    img_L  img_C  img_w  ideal_L\x1b[0m\n");
    for (0..8) |i| {
        const name = pal_mod.ACCENT_NAMES[i];
        const img = trace.img_data[i];
        // Color-code affinity: green if significant, dim if near-zero
        const aff_color: []const u8 = if (trace.affinity[i] > 0.3) "\x1b[32m" else if (trace.affinity[i] > 0.05) "\x1b[33m" else "\x1b[2m";
        const line = try std.fmt.allocPrint(a,
            "  {s: <8} {d:>6.1}  {d:.3}  {s}{d:.3}\x1b[0m  {d:.3}  {d:.3}  {d:.3}  {d:.3}\n",
            .{ name, trace.accent_h[i], trace.accent_C[i], aff_color, trace.affinity[i], img.L, img.C, img.weight, trace.ideal_L[i] },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
}

fn renderStage4(a: std.mem.Allocator, out: std.fs.File, trace: pal_mod.AccentTrace, mode: pal_mod.Mode) !void {
    _ = mode;
    {
        const line = try std.fmt.allocPrint(a,
            "  \x1b[2mIterative penalty-method optimisation (coord descent + joint search).\x1b[0m\n" ++
                "  \x1b[2m{} matchings tried, best score: {d:.4}\x1b[0m\n\n",
            .{ trace.n_matchings_tried, trace.best_score },
        );
        defer a.free(line);
        try out.writeAll(line);
    }

    // Diff-pair contrast ratios
    const srgb_r = trace.result[0];
    const srgb_g = trace.result[3];
    const srgb_b = trace.result[5];
    const cr_rb = color.contrastRatio(srgb_r, srgb_b);
    const cr_gb = color.contrastRatio(srgb_g, srgb_b);
    {
        const line = try std.fmt.allocPrint(a,
            "  red/blue CR:    {d:.2}:1    green/blue CR: {d:.2}:1\n\n",
            .{ cr_rb, cr_gb },
        );
        defer a.free(line);
        try out.writeAll(line);
    }

    try out.writeAll("  \x1b[2mslot      ideal_L  L_bound  final_L  delta    status\x1b[0m\n");
    for (0..8) |i| {
        const name = pal_mod.ACCENT_NAMES[i];
        const delta = trace.final_L[i] - trace.ideal_L[i];
        const moved: []const u8 = if (@abs(delta) > 0.001) "\x1b[33mpushed\x1b[0m" else "\x1b[32mok\x1b[0m";
        const line = try std.fmt.allocPrint(a,
            "  {s: <8} {d:.3}    {d:.3}    {d:.3}   {d:>.3}   {s}\n",
            .{ name, trace.ideal_L[i], trace.L_bound[i], trace.final_L[i], delta, moved },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
}

fn renderStage5(a: std.mem.Allocator, out: std.fs.File, trace: pal_mod.AccentTrace, pal: pal_mod.Palette, m: pal_mod.Metrics) !void {
    {
        const dp = m.min_diff_pair_contrast;
        const dp_tag: []const u8 = if (dp >= 3.0) "\x1b[32mok\x1b[0m" else if (dp >= 2.0) "\x1b[33mwarn\x1b[0m" else "\x1b[31mfail\x1b[0m";
        const line = try std.fmt.allocPrint(a,
            "  diff pair contrast:   {d:.2}:1  {s}\n" ++
                "  min accent-on-bg:     {d:.2}:1\n" ++
                "  fidelity cost:        {d:.4}\n" ++
                "  slots from image:     {}/8\n\n",
            .{ dp, dp_tag, m.min_accent_bg_contrast, m.fidelity_cost, m.slots_from_image },
        );
        defer a.free(line);
        try out.writeAll(line);
    }

    try out.writeAll("  \x1b[2mslot      swatch  hex     hue     L      C      aff    source\x1b[0m\n");
    for (0..8) |i| {
        const name = pal_mod.ACCENT_NAMES[i];
        const c = trace.result[i];
        const h = c.toHex();
        var hex: [6]u8 = undefined;
        c.toHexStr(&hex);
        const lch = color.srgbToLch(c);
        const aff = trace.affinity[i];
        const src: []const u8 = if (trace.assignments[i] != null) "\x1b[32mpeak\x1b[0m" else if (aff > 0.05) "\x1b[36mimg data\x1b[0m" else "\x1b[2minvented\x1b[0m";
        const line = try std.fmt.allocPrint(a,
            "  {s: <8} \x1b[48;2;{};{};{}m    \x1b[0m  {s}  {d:>6.1}  {d:.3}  {d:.3}  {d:.2}  {s}\n",
            .{
                name,
                (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
                &hex, lch.h, lch.L, lch.C, aff, src,
            },
        );
        defer a.free(line);
        try out.writeAll(line);
    }

    // Key contrast pairs with live samples
    try out.writeAll("\n  \x1b[2mkey pairs:\x1b[0m\n");
    const pairs = [_]struct { ac: color.Srgb, bg: color.Srgb, name: []const u8 }{
        .{ .ac = pal.base0B, .bg = pal.base0D, .name = "green/blue " },
        .{ .ac = pal.base08, .bg = pal.base0D, .name = "red/blue   " },
        .{ .ac = pal.base14, .bg = pal.base0D, .name = "br.grn/blue" },
        .{ .ac = pal.base05, .bg = pal.base00, .name = "text/bg    " },
    };
    for (pairs) |p| {
        const cr = color.contrastRatio(p.ac, p.bg);
        const ah = p.ac.toHex();
        const bh = p.bg.toHex();
        const line = try std.fmt.allocPrint(a,
            "  \x1b[38;2;{};{};{};48;2;{};{};{}m sample \x1b[0m {s} {d:.2}:1\n",
            .{
                (ah >> 16) & 0xFF, (ah >> 8) & 0xFF, ah & 0xFF,
                (bh >> 16) & 0xFF, (bh >> 8) & 0xFF, bh & 0xFF,
                p.name, cr,
            },
        );
        defer a.free(line);
        try out.writeAll(line);
    }
}

fn renderRow(alloc: std.mem.Allocator, out: std.fs.File, slots_slice: []const pal_mod.Slot) !void {
    try out.writeAll("  ");
    for (slots_slice) |slot| {
        const h = slot.srgb.toHex();
        const fg_lum = color.relativeLuminance(slot.srgb);
        const fg: []const u8 = if (fg_lum > 0.18) "\x1b[38;2;0;0;0m" else "\x1b[38;2;200;200;200m";
        const cell = try std.fmt.allocPrint(alloc,
            "\x1b[48;2;{};{};{}m{s}{s} \x1b[0m",
            .{ (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF, fg, slot.name },
        );
        defer alloc.free(cell);
        try out.writeAll(cell);
    }
    try out.writeAll("\n");
}
