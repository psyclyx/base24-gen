# base24-gen

Deterministic [Base24](https://github.com/tinted-theming/base24) color scheme generator. Given a wallpaper image, produces a [stylix](https://github.com/danth/stylix)-compatible YAML palette.

Designed as a drop-in replacement for stylix's built-in palette generator with better color semantics.

## How it works

1. **Analyze** — sub-sample the image, profile lightness distribution and hue content via coarse (8×45°) and fine (36×10°) histograms in OKLCh
2. **Tone ramp** — build 10 background/foreground shades with image-derived tinting, contrast-optimized via binary search
3. **Accents** — extract dominant hue peaks from the fine histogram, assign them to the 8 semantic accent slots (red, orange, yellow, green, cyan, blue, purple, brown) by proximity; assigned slots get image-derived hue at boosted chroma, unassigned slots keep canonical hue at muted chroma
4. **Bright variants** — derive 6 brighter accents for terminal bold colors, contrast-checked against all background tones
5. **Gamut clip** — binary search on chroma to bring every color into sRGB

Auto-detects dark/light mode from the image's median lightness. See [DESIGN.md](DESIGN.md) for the full algorithm and rationale.

## Building

Requires [Zig](https://ziglang.org/) 0.15+.

```sh
zig build
```

### Nix

```sh
nix build
```

## Usage

```sh
base24-gen [options] <image>
```

| Flag | Description |
|------|-------------|
| `--mode dark\|light` | Force dark or light mode (default: auto-detect) |
| `--name NAME` | Scheme name (default: image filename) |
| `--author AUTHOR` | Author field (default: `base24-gen`) |
| `--output FILE` | Write YAML to file (default: stdout) |
| `--preview` | Print ANSI color swatches to stderr |
| `--terminal` | Emit OSC 4/10/11 escape sequences to retheme the terminal in-place |

### Example

```sh
base24-gen --preview wallpaper.png > scheme.yaml
base24-gen --terminal wallpaper.png  # live-preview in current terminal
```

## Project structure

```
src/
  main.zig        CLI entry point, argument parsing, YAML/terminal output
  color.zig       sRGB/OKLab/OKLCh conversions, gamut clipping, contrast
  image.zig       stb_image wrapper for image loading
  analysis.zig    image profiling (lightness, hue weights, chroma stats)
  palette.zig     tone ramp, accent synthesis, bright variants
vendor/
  stb_image.h     vendored stb_image v2.29
```

## License

MIT.
