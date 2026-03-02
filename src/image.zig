//! Image loading via stb_image.
//! Decodes common formats (PNG, JPEG, BMP, GIF, TGA, …) into an RGB buffer.
//! The caller is responsible for calling deinit() when done.

const std = @import("std");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const Image = struct {
    /// Row-major RGB triples; len == width * height.
    pixels: []const [3]u8,
    width: u32,
    height: u32,

    pub fn deinit(self: Image) void {
        c.stbi_image_free(@constCast(@ptrCast(self.pixels.ptr)));
    }
};

pub const LoadError = error{ImageLoadFailed};

/// Load an image from a null-terminated file path.
/// Returns an Image whose pixels are owned by stb_image; call deinit() when done.
pub fn load(path: [*:0]const u8) LoadError!Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    // Force 3 channels (RGB); alpha is discarded.
    const data = c.stbi_load(path, &width, &height, &channels, 3) orelse
        return LoadError.ImageLoadFailed;

    const n: usize = @intCast(width * height);
    const pixels: [*]const [3]u8 = @ptrCast(data);

    return .{
        .pixels = pixels[0..n],
        .width = @intCast(width),
        .height = @intCast(height),
    };
}
