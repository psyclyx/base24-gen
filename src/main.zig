//! base24-gen: deterministic Base24 colour scheme generator.
//!
//! Usage:
//!   base24-gen [options] <image>
//!
//! Options:
//!   --mode dark|light    Force dark or light mode (default: auto-detect)
//!   --name NAME          Scheme name (default: image filename stem)
//!   --author AUTHOR      Author string (default: "base24-gen")
//!   --output FILE        Output path (default: stdout)
//!   --preview            Print ANSI colour swatches to stderr
//!   --terminal           Output OSC 4 escape sequences to set terminal palette

const std = @import("std");
const color = @import("color.zig");
const image = @import("image.zig");
const analysis = @import("analysis.zig");
const palette = @import("palette.zig");

const log = std.log.scoped(.base24_gen);

const usage =
    \\Usage: base24-gen [options] <image>
    \\
    \\Options:
    \\  --mode dark|light    Force dark or light mode (default: auto-detect)
    \\  --name NAME          Scheme name (default: image filename stem)
    \\  --author AUTHOR      Author string (default: "base24-gen")
    \\  --output FILE        Output YAML path (default: stdout)
    \\  --preview            Print ANSI colour swatches to stderr
    \\  --terminal           Write OSC 4/10/11 sequences to set terminal palette
    \\                       pipe to /dev/tty: base24-gen --terminal img.png >/dev/tty
    \\  --help               Show this help
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var image_path: ?[]const u8 = null;
    var forced_mode: ?palette.Mode = null;
    var scheme_name: ?[]const u8 = null;
    var author: []const u8 = "base24-gen";
    var output_path: ?[]const u8 = null;
    var preview = false;
    var terminal = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) fatal("--mode requires an argument");
            forced_mode = parseMode(args[i]) orelse
                fatal("--mode must be 'dark' or 'light'");
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) fatal("--name requires an argument");
            scheme_name = args[i];
        } else if (std.mem.eql(u8, arg, "--author")) {
            i += 1;
            if (i >= args.len) fatal("--author requires an argument");
            author = args[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) fatal("--output requires an argument");
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--preview")) {
            preview = true;
        } else if (std.mem.eql(u8, arg, "--terminal")) {
            terminal = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            log.err("Unknown option: {s}", .{arg});
            fatal("Run with --help for usage");
        } else {
            if (image_path != null) fatal("Multiple image paths given");
            image_path = arg;
        }
    }

    const img_path = image_path orelse {
        try std.fs.File.stdout().writeAll(usage);
        std.process.exit(1);
    };

    // Derive default scheme name from filename stem
    const name = scheme_name orelse stemOf(img_path);

    // Load image
    const img_path_z = try allocator.dupeZ(u8, img_path);
    defer allocator.free(img_path_z);

    const img = image.load(img_path_z.ptr) catch |err| {
        log.err("Failed to load '{s}': {}", .{ img_path, err });
        std.process.exit(1);
    };
    defer img.deinit();

    log.info("Loaded {s} ({}×{})", .{ img_path, img.width, img.height });

    // Analyse
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const profile = try analysis.analyze(img, arena.allocator());

    log.info(
        "Profile: median_L={d:.3} mean_C={d:.3} p85_C={d:.3}",
        .{ profile.median_lightness, profile.mean_chroma, profile.p85_chroma },
    );

    // Generate palette
    const pal = palette.generate(profile, forced_mode);

    const detected_mode: palette.Mode = if (forced_mode) |m| m else
        if (profile.median_lightness < 0.5) .dark else .light;

    log.info("Mode: {s}", .{@tagName(detected_mode)});

    // Output YAML — to --output file if given, else stdout.
    // When --terminal is active and no --output is given, skip stdout YAML
    // so the caller can pipe terminal sequences cleanly: cmd > /dev/tty
    if (output_path) |path| {
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            log.err("Cannot open output '{s}': {}", .{ path, err });
            std.process.exit(1);
        };
        defer file.close();
        try writeYaml(file, allocator, name, author, &pal);
    } else if (!terminal) {
        try writeYaml(std.fs.File.stdout(), allocator, name, author, &pal);
    }

    // Optional ANSI preview to stderr
    if (preview) {
        try writePreview(std.fs.File.stderr(), allocator, &pal);
    }

    // Optional: write OSC 4/10/11 sequences to stdout.
    // Typical use: base24-gen --terminal img.png > /dev/tty
    if (terminal) {
        try writeTerminalPalette(std.fs.File.stdout(), allocator, &pal);
    }
}

// ─── YAML output ─────────────────────────────────────────────────────────────

fn writeYaml(
    file: std.fs.File,
    allocator: std.mem.Allocator,
    name: []const u8,
    author: []const u8,
    pal: *const palette.Palette,
) !void {
    const header = try std.fmt.allocPrint(
        allocator,
        "scheme: \"{s}\"\nauthor: \"{s}\"\n",
        .{ name, author },
    );
    defer allocator.free(header);
    try file.writeAll(header);

    for (pal.slots()) |slot| {
        var hex: [6]u8 = undefined;
        slot.srgb.toHexStr(&hex);
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}: \"{s}\"\n",
            .{ slot.name, &hex },
        );
        defer allocator.free(line);
        try file.writeAll(line);
    }
}

// ─── ANSI preview ────────────────────────────────────────────────────────────
//
// Prints a two-row colour swatch per group: background on top, label below.
// Works on any true-colour terminal.

fn writePreview(
    file: std.fs.File,
    allocator: std.mem.Allocator,
    pal: *const palette.Palette,
) !void {
    try file.writeAll("\n── base24-gen preview ─────────────────────────────────\n\n");

    const slots = pal.slots();

    // Two rows of 12
    for (0..2) |row| {
        const start = row * 12;
        const end = @min(start + 12, slots.len);
        const row_slots = slots[start..end];

        // Top: colour block
        for (row_slots) |slot| {
            const h = slot.srgb.toHex();
            const r = (h >> 16) & 0xFF;
            const g = (h >> 8) & 0xFF;
            const b = h & 0xFF;
            const cell = try std.fmt.allocPrint(allocator, "\x1b[48;2;{};{};{}m  ", .{ r, g, b });
            defer allocator.free(cell);
            try file.writeAll(cell);
        }
        try file.writeAll("\x1b[0m\n");

        // Bottom: name on coloured background
        for (row_slots) |slot| {
            const h = slot.srgb.toHex();
            const r = (h >> 16) & 0xFF;
            const g = (h >> 8) & 0xFF;
            const b = h & 0xFF;
            const cell = try std.fmt.allocPrint(allocator, "\x1b[48;2;{};{};{}m{s}\x1b[0m", .{ r, g, b, slot.name });
            defer allocator.free(cell);
            try file.writeAll(cell);
        }
        try file.writeAll("\n\n");
    }
}

// ─── Terminal palette injection ───────────────────────────────────────────────
//
// Writes OSC 4 sequences to set the 16 ANSI palette colours and OSC 10/11
// for default foreground/background. Pipe to /dev/tty to apply:
//
//   base24-gen --terminal img.png > /dev/tty
//
// Base24 → ANSI 16 colour mapping follows the conventional terminal assignment:
//   0 black        base00  (default background)
//   1 red          base08
//   2 green        base0B
//   3 yellow       base0A
//   4 blue         base0D
//   5 magenta      base0E
//   6 cyan         base0C
//   7 white        base05  (default foreground)
//   8 bright black base03  (comments)
//   9 bright red   base12
//  10 bright green base14
//  11 bright yellow base13
//  12 bright blue  base16
//  13 bright magenta base17
//  14 bright cyan  base15
//  15 bright white base07

fn writeTerminalPalette(
    file: std.fs.File,
    allocator: std.mem.Allocator,
    pal: *const palette.Palette,
) !void {
    const ansi = [16]color.Srgb{
        pal.base00, pal.base08, pal.base0B, pal.base0A,
        pal.base0D, pal.base0E, pal.base0C, pal.base05,
        pal.base03, pal.base12, pal.base14, pal.base13,
        pal.base16, pal.base17, pal.base15, pal.base07,
    };

    for (ansi, 0..) |c, i| {
        const h = c.toHex();
        const seq = try std.fmt.allocPrint(
            allocator,
            "\x1b]4;{};#{x:0>6}\x1b\\",
            .{ i, h },
        );
        defer allocator.free(seq);
        try file.writeAll(seq);
    }

    // Default foreground (base05) and background (base00)
    const fg_seq = try std.fmt.allocPrint(
        allocator,
        "\x1b]10;#{x:0>6}\x1b\\",
        .{pal.base05.toHex()},
    );
    defer allocator.free(fg_seq);
    try file.writeAll(fg_seq);

    const bg_seq = try std.fmt.allocPrint(
        allocator,
        "\x1b]11;#{x:0>6}\x1b\\",
        .{pal.base00.toHex()},
    );
    defer allocator.free(bg_seq);
    try file.writeAll(bg_seq);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn parseMode(s: []const u8) ?palette.Mode {
    if (std.mem.eql(u8, s, "dark")) return .dark;
    if (std.mem.eql(u8, s, "light")) return .light;
    return null;
}

fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        return base[0..dot];
    }
    return base;
}

fn fatal(msg: []const u8) noreturn {
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}
