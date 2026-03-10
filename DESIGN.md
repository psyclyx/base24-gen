# base24-gen design notes

## What this is

A deterministic, fast Base24 colour scheme generator. Given an image, it
produces a 24-color YAML palette that is:

- **Semantically correct** — red stays reddish, green stays greenish, etc.
- **Image-inspired** — accent hues and chroma are derived from the image's
  dominant colours, not merely pulled toward them
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
- If C > 0.04 (chromatic pixel): accumulate chroma-weighted hue into both
  a coarse 8-bucket histogram (45° each) and a fine 36-bin histogram (10°
  each)

Output (`ImageProfile`):
- `median_lightness`: drives dark/light mode detection (< 0.5 → dark)
- `p10_lightness`, `p90_lightness`: shadow and highlight levels
- `hue_weights[8]`, `bucket_hues[8]`: coarse histogram (used for tone tinting)
- `fine_hue_weights[36]`, `fine_hue_centroids[36]`: fine histogram (used for
  accent peak extraction)
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

A **contrast-optimized tint** is applied to all tones at the image's primary
hue. The tint chroma ceiling is `min(max(mean_chroma × 0.5, p85_chroma ×
0.35), 0.06)`, then binary-searched (20 iterations) to find the highest
value that satisfies all required contrast pairs. Using p85_chroma ensures
images with localised vivid colour (but low mean chroma) still produce
visibly tinted backgrounds.

**Enforced contrast pairs:**
- base05 on base00 ≥ 7.0:1 (primary text, WCAG AAA)
- base07 on base00 ≥ 7.0:1 (bright foreground, AAA)
- base05 on base02 ≥ 4.5:1 (text on selection, AA)
- base04 on base01 ≥ 3.0:1 (status bar text, AA-large)

Note: base03/base00 (comments) is intentionally low-contrast (~1.8:1 at the
standard L values) and is not constrained — comments should be de-emphasized.

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

Accents are generated through a four-stage pipeline:

**Stage 1 — peak extraction** from the 36-bin fine hue histogram:
- Bins with weight > 1.5/36 (~0.042) are marked significant
- Adjacent significant bins are merged circularly into clusters
- Each cluster yields a peak: circular weighted-mean centroid and summed weight
- Peaks are sorted by weight (max 8)

**Stage 2 — exhaustive assignment** of peaks to accent slots:
- All valid peak-to-slot matchings are enumerated recursively (typically
  < 100 candidates). A peak is valid for a slot if:
  - It is within 45° of the slot's canonical hue target
  - The slot is the closest accent target to the peak's hue (`isClosestSlot`)
- Each matching is evaluated with a quick 1-round optimisation pass
- The best-scoring matching proceeds to full evaluation

**Stage 3 — hue + chroma selection:**
- **Assigned slots**: hue = peak centroid hue
- **Unassigned slots**: hue pulled toward image data via Gaussian-weighted
  sampling (σ=30°), limited to preserve hue identity:
  - Pull capped at ±25° and 40% of nearest-neighbor distance
  - Pull scaled by evidence strength (image weight / average)
- **Continuous affinity** (not binary): every accent gets a Gaussian-sampled
  weight normalised to [0, 1], driving chroma and lightness interpolation
- **Chroma**: `lerp(floor, C_ceiling, sqrt(affinity))` where floor = 0.10
  (assigned) or 0.05 (unassigned), C_ceiling from image saturation
- **Chroma capping** for hue-neighbor pairs (red/orange, orange/brown, etc.):
  if gamut clipping collapses two accents to < 10° post-clip hue separation,
  binary-search for the chroma on the lower-affinity accent that gives 15°

**Stage 4 — iterative penalty-method optimisation:**

Parameters: 16 continuous — (L, C) per accent. Hue fixed by matching.

Objective (maximise):
```
fidelity(L, C) − λ · violation(L, C)

fidelity  = Σ_i (a_i + ε) · [1 − |L_i − L*_i| / L_range + 0.3 · (1 − |C_i − C*_i| / C_range)]
violation = Σ bg_contrast_penalties + Σ diff_pair_penalties
```

Constraints (enforced via quadratic penalty, λ = 500):
- Background contrast: CR(accent, base00/01) ≥ 3.0:1, CR(accent, base02) ≥ 2.5:1
- Diff-pair contrast: CR(red, blue) ≥ 2.5:1, CR(green, blue) ≥ 2.5:1
  (relaxed to 1.5:1 in light mode — blue at 265° is inherently dark in sRGB)

Method: 3 rounds (1 for quick enumeration) of:
1. **Coordinate descent** — 4 sweeps, each accent gets a 33×9 grid search
   over [L_lo, L_hi] × [C_floor, C_ideal + 0.03]
2. **Joint grid search** — 3D search over red/green/blue L values (12 steps
   early rounds, 24 on final) to resolve coupled diff-pair constraints
3. **Refinement** (final round only) — ±0.10 L, ±0.02 C fine grid per accent

L search range: [0.45, 0.85] dark, [0.35, 0.70] light.

After optimisation, hard enforcement clamps any remaining bg-contrast violations.
All evaluation uses post-gamut-clip sRGB, so gamut limits are handled implicitly.

### 4. Bright variants (base12–17)

Bright variants are the 6 ANSI bright colours, derived from base08–0D by
adding +0.10 L and +0.03 C, then re-clipping to gamut. base0F (brown) has
no bright variant.

Each bright variant is **contrast-validated** against the same three
backgrounds as normal accents (base00 at 3:1, base01 at 3:1, base02 at
2.5:1). If the initial L shift fails contrast, L is binary-searched in the
direction that restores it.

### 5. Gamut clipping

`clipToGamut` does binary search on chroma (40 iterations, error < 2⁻⁴⁰C)
while holding L and h fixed. This guarantees every output colour is in sRGB
without distorting its semantic identity.

## Key constants and their rationale

| Constant | Value | Why |
|----------|-------|-----|
| `FINE_BINS` | 36 | 10° per bin: fine enough to separate adjacent hue families |
| `SIGNIFICANCE_FACTOR` | 1.5 | Bins must exceed 1.5× uniform weight to count as significant |
| `MAX_ASSIGNMENT_DISTANCE` | 45° | Peaks further than this from a target don't claim it |
| `MAX_PEAKS` | 8 | One peak per accent slot maximum |
| `MIN_ACCENT_C` | 0.10 | Floor for assigned accent chroma (lerp base) |
| `UNASSIGNED_ACCENT_C` | 0.05 | Chroma for accents with no image peak — muted but identifiable |
| `MAX_ACCENT_C` | 0.32 | Ceiling for the most dominant image hues |
| `CHROMA_SCALE_REF` | 0.12 | p85 chroma reference: images at or above this get full C_ceiling |
| `SAMPLE_LIMIT` | 16 384 | Fast analysis of large images; <1% error vs full scan |
| `CHROMA_THRESHOLD` | 0.04 | Excludes near-grey pixels from hue statistics |
| Tone tint C | ≤ 0.06 | Adaptive ceiling: binary-searched for max contrast-safe value |
| `MIN_ACCENT_CONTRAST` | 3.0 | Accent contrast against base00/base01 (WCAG AA-large) |
| `MIN_ACCENT_CONTRAST_BG2` | 2.5 | Accent contrast against base02 (selection highlight) |
| `MIN_DIFF_PAIR_CR` | 2.5 (1.5 light) | WCAG contrast between diff-paired accents (red/blue, green/blue) |
| Accent L range (dark) | [0.45, 0.85] | Feasible L search range for dark-mode accents |
| Accent L range (light) | [0.35, 0.70] | Feasible L search range for light-mode accents |
| Accent L target | 0.65 dark / 0.52 light | Ideal L before constraint enforcement |
| `HUE_SAMPLE_SIGMA` | 30° | Gaussian kernel width for sampling image hue data |
| `MAX_HUE_PULL` | 25° | Maximum angular shift for unassigned accents toward image centroid |

## Why not just extract colours?

Pure extraction (e.g. k-means on image pixels) gives you colours that exist
in the image but makes no semantic guarantees. If the image has no blue, you
get no blue — making code, keywords, and functions invisible in some editors.

Our approach inverts this: we *start* from semantically correct targets and
*assign* image-derived hues where available. The result is always usable; it
is also clearly image-derived for hues present in the image, and gracefully
muted for absent hues.

## Degenerate case analysis

| Input | Result |
|-------|--------|
| All-black | Dark mode, tones correct, all accents unassigned at canonical hues with muted chroma |
| All-white | Light mode, tones correct, all accents unassigned at canonical hues with muted chroma |
| Monochrome gradient | Mode from median L; no significant peaks → all accents unassigned |
| Random noise | Uniform fine histogram → no bins exceed significance threshold → all accents unassigned |
| Single saturated hue | One peak, one accent assigned with vivid chroma; 7 others muted |

All degenerate cases produce valid, readable themes.

## Terminal preview

`--preview` writes a two-row ANSI 24-bit colour swatch to stderr (independent
of the YAML stdout stream). Each swatch label picks whichever of base05 or
base00 has higher contrast against the swatch colour, ensuring readability
in both dark and light themes.

`--terminal` writes OSC 4/10/11 sequences to stdout to retheme the running
terminal in-place. Pipe to `/dev/tty`:

    base24-gen --terminal wallpaper.png > /dev/tty

## File map

```
src/
  color.zig     Color math: sRGB ↔ linear ↔ OKLab ↔ OKLCh, gamut clip, contrast
  image.zig     stb_image wrapper (PNG/JPEG/BMP/…)
  analysis.zig  Image profiling (lightness percentiles, hue histograms)
  peaks.zig     Hue peak extraction, image hue sampling, accent target definitions
  palette.zig   Palette generation algorithm (tone ramp, accent solver, bright variants)
  main.zig      CLI, YAML output, ANSI preview, terminal palette
  devtui.zig    Interactive TUI for step-by-step accent solver visualization
vendor/
  stb_image.h   Vendored stb_image v2.29 (single-header C library)
  stb_image.c   Implementation unit (defines STB_IMAGE_IMPLEMENTATION)
```
