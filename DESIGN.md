# base24-gen design notes

## What this is

A deterministic, fast Base24 colour scheme generator. Given an image, it
produces a `stylix`-compatible YAML palette that is:

- **Semantically correct** — red stays reddish, green stays greenish, etc.
- **Image-inspired** — the palette is biased toward the image's dominant hues
  and luminance distribution, not merely extracted from it
- **Usable in degenerate cases** — monochrome, noise, and all-black/all-white
  images all produce valid, readable themes
- **Deterministic** — same image → same palette, always

## Colour space

All colour math is done in **OKLCh** (cylindrical OKLab), for three reasons:

1. **Perceptual uniformity** — equal steps in L look equally different to humans
2. **Correct hue linearity** — ΔH is perceptually even; hue "families" map
   cleanly to angular ranges
3. **Simple gamut clipping** — chroma reduction (binary search on C while
   holding L and h fixed) reliably brings out-of-gamut colours into sRGB
   without distorting their identity

The conversion pipeline is:

    sRGB → linear RGB → OKLab → OKLCh
    OKLCh → OKLab → linear RGB → sRGB

Arithmetic is in `f32`. The round-trip error for saturated primaries is ~0.7%
(< 2/255), which is below display resolution. All output values are 8-bit hex.

## Algorithm overview

### 1. Image analysis (`analysis.zig`)

Sub-sample to ≤ 16 384 pixels for speed. For each pixel:

- Convert to OKLCh
- Accumulate L into a sorted list for percentile computation
- If C > 0.04 (chromatic pixel): accumulate chroma-weighted hue into one of
  8 buckets (each 45° wide)

Output (`ImageProfile`):
- `median_lightness`: drives dark/light mode detection (< 0.5 → dark)
- `p10_lightness`, `p90_lightness`: shadow and highlight levels
- `hue_weights[8]`: normalised bucket weights (how much of each hue family
  is present in the image)
- `bucket_hues[8]`: circular mean hue within each bucket (actual centroid,
  not just midpoint)
- `mean_chroma`, `p85_chroma`: overall and peak saturation of the image

### 2. Tone ramp generation (`palette.zig`)

The 10 tone slots (base00–07, base10–11) form a monotone lightness ramp.
In dark mode:

| Slot   | OKLCh L | Role |
|--------|---------|------|
| base11 | 0.05    | Darkest background |
| base10 | 0.08    | Darker background |
| base00 | 0.12    | Default background |
| base01 | 0.17    | Status bars, line-number background |
| base02 | 0.23    | Selection background |
| base03 | 0.35    | Comments, invisibles |
| base04 | 0.55    | Dark foreground (status bars) |
| base05 | 0.75    | Default foreground |
| base06 | 0.87    | Light foreground |
| base07 | 0.95    | Light background (rarely used) |

Light mode mirrors this: L_light = 1 − L_dark.

A **subtle tint** (C ≤ 0.012 at the image's primary hue) is applied to all
tones so they feel connected to the image. At these chroma levels the tint
is imperceptible on most displays but satisfies the constraint numerically.

### 3. Accent colour generation (`palette.zig`)

Eight semantic hue targets in OKLCh:

| Slot  | Target h° | Role |
|-------|-----------|------|
| base08 | 27°      | Red |
| base09 | 58°      | Orange |
| base0A | 110°     | Yellow |
| base0B | 145°     | Green |
| base0C | 195°     | Cyan |
| base0D | 265°     | Blue |
| base0E | 328°     | Purple/Magenta |
| base0F | 55°      | Brown (same hue as orange, lower L and C) |

For each target, a **hue pull** is computed from the image profile:

1. For each of the 8 image hue buckets, compute a Gaussian affinity weight
   based on how far the bucket centroid is from the target (σ = 25°)
2. Multiply by the bucket's normalised hue weight (image presence)
3. Compute the weighted circular mean of angular offsets from target
4. Scale by image saturation (`min(mean_chroma / 0.08, 1.0)`)
5. Clamp the final offset to ±15° to stay within the colour family

The accent **lightness** is fixed (0.65 dark / 0.52 light) and **chroma**
is scaled between 0.10 and 0.20 by the image's p85 chroma, ensuring
reasonable saturation even for washed-out images.

### 4. Bright variants (base12–17)

Bright variants are the 6 ANSI bright colours. They are derived from
base08–0D (red through blue) by adding +0.10 L and +0.03 C, then
re-clipping to gamut. base0F (brown) has no bright variant.

### 5. Gamut clipping

`clipToGamut` does binary search on chroma (40 iterations, error < 2⁻⁴⁰C)
while holding L and h fixed. This guarantees every output colour is in sRGB
without distorting its semantic identity.

## Key constants and their rationale

| Constant | Value | Why |
|----------|-------|-----|
| `MAX_HUE_PULL` | 15° | Keeps accents in their colour family even in strongly biased images |
| `HUE_SIGMA` | 25° | Only nearby image hues affect each accent; prevents cross-family bleed |
| `SAMPLE_LIMIT` | 16 384 | Fast analysis of 33MP images; <1% error vs full scan |
| `CHROMA_THRESHOLD` | 0.04 | Excludes near-grey pixels from hue statistics |
| Tone tint C | ≤ 0.012 | Perceptible to the algorithm but below display threshold |
| Accent L (dark) | 0.65 | WCAG AA contrast (~4.5:1) on base00 (L=0.12) |
| Accent C range | 0.10–0.20 | Minimum always saturated; maximum avoids over-saturation |

## Why not just extract colours?

Pure extraction (e.g. k-means on image pixels) gives you colours that exist
in the image but makes no semantic guarantees. If the image has no blue, you
get no blue — making code, keywords, and functions invisible in some editors.

Our approach inverts this: we *start* from semantically correct targets and
*bias* them toward image colours. The result is always usable; it is also
clearly image-derived, and in most cases "obviously inspired" by the image.

## Degenerate case analysis

| Input | Result |
|-------|--------|
| All-black | Dark mode, tones correct, accents at target hues with min chroma |
| All-white | Light mode, tones correct, accents at target hues with min chroma |
| Monochrome (grey gradient) | Dark/light from median L; no hue pull (zero influence); tones tinted at primary_hue bucket midpoint |
| Random noise | Uniform hue distribution; each bucket pulls equally → near-zero circular mean → no net pull; accents at target hues |
| Single saturated hue | Full influence, all accents biased up to ±15° toward that hue |

All degenerate cases produce valid, readable themes.

## Terminal preview

`--preview` writes a two-row ANSI 24-bit colour swatch to stderr (independent
of the YAML stdout stream) so the palette can be eyeballed without loading
it into a compositor. Works on any true-colour terminal.

For deeper validation, feeding the YAML to `stylix` and launching a temporary
terminal with the applied theme remains the gold standard.

## File map

```
src/
  color.zig     Color math: sRGB ↔ linear ↔ OKLab ↔ OKLCh, gamut clip
  image.zig     stb_image wrapper (PNG/JPEG/BMP/…)
  analysis.zig  Image profiling (lightness percentiles, hue histogram)
  palette.zig   Palette generation algorithm
  main.zig      CLI, YAML output, ANSI preview
vendor/
  stb_image.h   Vendored stb_image v2.29 (single-header C library)
  stb_image.c   Implementation unit (defines STB_IMAGE_IMPLEMENTATION)
```
