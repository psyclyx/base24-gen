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

Sub-sample to ≤ 65 536 pixels for speed. Every per-pixel measurement is
weighted by a centred Gaussian over pixel position (σ = min(w, h) / 3),
biasing the analysis toward whatever the image's focal subject is —
polarity-agnostic, so a dark subject on a light background and a light
subject on a dark background are treated symmetrically.

For each sampled pixel:
- Convert to OKLCh
- Accumulate (L, weight) for weighted percentile computation
- Accumulate (C, weight) for the 1D chroma-cluster k-means
- If C > 0.04 (chromatic pixel): accumulate spatial × chroma-weighted hue
  into a coarse 8-bucket histogram (45° each, used for tone tinting), and
  push the OKLab (L, a, b, weight) onto the cluster sample list
- Accumulate sin/cos for the global circular-mean hue and resultant length

After the pass, run **3D weighted k-means in OKLab** on the chromatic
samples (k-means++ initialisation with a fixed RNG seed for determinism,
Lloyd's iterations to convergence). The resulting clusters carry full
(L, a, b, weight) — the actual colours present in the image, not just
the hues that happen to appear.

Output (`ImageProfile`):
- `median_lightness`, `p10_lightness`, `p90_lightness`: weighted percentiles
  driving dark/light mode detection (median < 0.5 → dark)
- `hue_weights[8]`, `bucket_hues[8]`, `bucket_mean_L[8]`: coarse histogram
  used for tone-ramp split-toning
- `chroma_lower`, `chroma_upper`: 1D weighted k-means (k=2) cluster means
  over per-pixel chromas. Lower = natural chroma of quiet regions (drives
  base tint); upper = chroma of vivid regions (drives accent ceiling).
  Unimodal distributions collapse to the joint mean — monochrome, B&W, and
  noise images correctly yield a single vibrance level for everything
- `mean_hue`, `mean_hue_strength`: circular weighted-mean hue and resultant
  length (0..1). Used to bias unassigned accents toward the image's
  temperature when the hue distribution is concentrated
- `clusters[..n_clusters]`: dominant colour clusters with full
  (L, a, b, weight). The primary input to accent generation

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

Light mode has a dedicated ramp (not simply 1 − dark) with a brighter base00
(0.93 vs 0.88), softer body text base05 (0.32 vs 0.25), and near-white
extended backgrounds (base10=0.96, base11=0.98).

A **contrast-optimized split-tone tint** is applied. The two most-weighted
hue buckets are identified and assigned to shadows (lower mean-L bucket)
and highlights (higher mean-L). Hue is interpolated across the ramp from
shadow_h to highlight_h, giving a natural warm-shadow / cool-highlight feel.
Falls back to single-hue tinting when the two hues are < 30° apart or the
secondary bucket has < 15% of the primary's weight.

A **bell-shaped chroma envelope** scales tint chroma per tone: peak at
mid-tones (L≈0.4) where the sRGB gamut is widest, with σ=0.45 so a hint
of tint stays visible at the L extremes (base11/base07) instead of being
crushed to ~0. The envelope peak is `min(chroma_lower, 0.04)` — the
natural chroma of the image's quiet regions, capped so it never
overwhelms the bases — then binary-searched (20 iterations) to find the
highest value that still satisfies all required contrast pairs.

**Enforced contrast pairs:**
- base05 on base00 ≥ 7.0:1 (primary text, WCAG AAA)
- base07 on base00 ≥ 7.0:1 (bright foreground, AAA)
- base05 on base02 ≥ 4.5:1 (text on selection, AA)
- base04 on base01 ≥ 3.0:1 (status bar text, AA-large)

Note: base03/base00 (comments) is intentionally low-contrast (~1.8:1 at the
standard L values) and is not constrained — comments should be de-emphasized.

### 3. Accent colour generation (`palette.zig`)

Eight semantic hue targets in OKLCh:

| Slot  | Target h° | dL   | Role |
|-------|-----------|------|------|
| base08 | 27°      | 0    | Red |
| base09 | 58°      | 0    | Orange |
| base0A | 103°     | +0.10 | Yellow (inherently light in OKLCh) |
| base0B | 145°     | 0    | Green |
| base0C | 195°     | 0    | Cyan |
| base0D | 265°     | −0.08 | Blue (inherently dark in sRGB gamut) |
| base0E | 328°     | 0    | Purple/Magenta |
| base0F | 55°      | −0.15 | Brown (same hue as orange, lower L and C) |

Per-hue L offsets (dL) give each accent a natural lightness that matches its
gamut limits, freeing the optimizer to focus on constraint satisfaction rather
than fighting the gamut.

Accents are generated through a four-stage pipeline:

**Stage 1 — peak extraction** from the 3D OKLab clusters:
- Each cluster yields one peak with full (L, C, h, weight) info
- Peaks are sorted by cluster weight, capped at 8
- Distinct colours at similar hues (e.g. bright cyan + dark teal) stay
  distinct because they form separate clusters in 3D

**Stage 2 — exhaustive assignment** of peaks to accent slots:
- All valid peak-to-slot matchings are enumerated recursively (typically
  < 100 candidates). A peak is valid for a slot if:
  - It is within 45° of the slot's canonical hue target
  - The slot is the closest accent target to the peak's hue (`isClosestSlot`)
- Each matching is evaluated with a quick 1-round optimisation pass
- The best-scoring matching proceeds to full evaluation

**Stage 3 — hue + chroma selection:**
- **Assigned slots**: hue = peak hue; image data anchors (L, C) come
  directly from the matched cluster
- **Unassigned slots**: hue pulled toward image data via Gaussian-weighted
  aggregate over clusters (σ=30°), limited to preserve hue identity:
  - Pull capped at ±25° and 40% of nearest-neighbor distance
  - Pull scaled by evidence strength (sum of cluster weight near the slot)
- **Continuous affinity** (not binary): every accent gets a Gaussian-sampled
  weight normalised to [0, 1], driving chroma and lightness interpolation
- **Chroma**: `lerp(floor, c_ceiling[i], sqrt(affinity))` where floor = 0.07
  (assigned) or 0.05 (unassigned). The per-accent ceiling is harmonized:
  `c_ceiling[i] = max(MIN_ACCENT_C, gamut_max[i] × sat_fraction)` where
  `sat_fraction = clamp(C_target_abs / max_gamut, 0.35, 0.92)` and
  `C_target_abs = clamp(chroma_upper × 1.2, MIN_ACCENT_C, MAX_ACCENT_C)`.
  All accents sit at the same fraction of their gamut max — yellow doesn't
  dominate by having more gamut headroom than green, and the most-saturable
  hue caps at the image's absolute vibrance target so the palette never
  exceeds what the image suggests
- **Hue temperature pull** (unassigned slots only): after the local
  centroid pull, a small additional shift toward the image's circular-mean
  hue, scaled by the hue distribution's resultant length. Echoes the
  bases' temperature mood in the accents
- **Chroma capping** for hue-neighbor pairs (red/orange, orange/brown, etc.):
  if gamut clipping collapses two accents to < 10° post-clip hue separation,
  binary-search for the chroma on the lower-affinity accent that gives 15°

**Stage 4 — feasibility-first optimisation:**

Parameters: 16 continuous — (L, C) per accent. Hue fixed by matching.

Objective (maximise, feasibility-first):
```
if any hard constraint violated:
  score = −1000 − λ · violation     (infeasible: always loses to feasible)
else:
  score = fidelity − 150 · soft_penalty  (feasible: pure quality)

fidelity    = Σ_i (a_i + ε) · [1 − |L_i − L*_i| / L_range + 0.3 · (1 − |C_i − C*_i| / C_range)]
soft_penalty = Σ pairwise_ΔE_penalties + Σ CVD_ΔE_penalties
```

Hard constraints:
- Background contrast: CR(accent, base00/01) ≥ 3.0:1, CR(accent, base02) ≥ 2.5:1
- Diff-pair contrast: CR(red, blue) ≥ 2.5:1, CR(green, blue) ≥ 2.5:1,
  CR(red, green) ≥ 1.8:1 (CVD accessibility),
  CR(orange, brown) ≥ 1.5:1 (prevent same-family collapse)
  (relaxed to 1.5:1 in light mode — blue at 265° is inherently dark in sRGB)

Soft quality constraints (penalised, not hard):
- Pairwise OKLab ΔE ≥ 0.12 for all 28 accent pairs (perceptual distinctiveness)
- CVD-simulated OKLab ΔE ≥ 0.08 for critical pairs under protanopia/deuteranopia
  (red/green, blue/purple, cyan/purple, orange/green)
- L-spread across the 8 accents ≤ 0.35 (palette-wide harmony — keeps
  vivid images from scattering accents across the full L range; the
  threshold equals the natural baseline from yellow's +0.10 dL and brown's
  −0.15 dL plus a 0.10 tolerance for image-driven variance)

**Two-phase optimisation:**

**Phase A — Independent accents** (orange, yellow, cyan, purple, brown):
These have no diff-pair coupling. Solved optimally in a single coordinate
descent pass with bg-contrast + ΔE penalties. No iteration needed.

**Phase B — Coupled accents** {red, green, blue}:
Iteratively optimised with convergence detection (stop when no accent moves
more than 0.002 in L or C). Maximum 6 rounds (full) or 3 (screening),
minimum 2/1.

Per round:
1. **Coordinate descent** — 4 sweeps over the coupled triple using incremental
   evaluator. Grid: 33×9 (screening) or 49×13 (full).
2. **Joint grid search** — 3D search over red/green/blue L values (12 steps
   early rounds, 32 on final) with feasibility-first scoring, ΔE penalties,
   and CVD penalties.

**Refinement** — After convergence, ±0.10 L / ±0.02 C fine grid over all 8
accents.

**Parallel matching evaluation:** All valid matchings are collected, then
evaluated concurrently using `std.Thread.Pool`. Each matching gets a
screening evaluation. Results are reduced deterministically by index order
(lowest index wins score ties). The winning matching gets a full evaluation.

L search range: [0.45, 0.85] dark, [0.35, 0.70] light.

After optimisation, hard enforcement clamps any remaining bg-contrast and
diff-pair violations via binary search. All evaluation uses post-gamut-clip
sRGB, so gamut limits are handled implicitly.

**Determinism:** The thread pool evaluates matchings in parallel but the
reduction (pick best score) iterates the results array in fixed index order.
All floating-point operations are deterministic (no cross-thread accumulation).
Same image always produces the same palette.

### 4. Bright variants (base12–17)

Bright variants are the 6 ANSI bright colours, derived from base08–0D using
**adaptive L targeting** and **gamut-aware C boost**:

- **L targeting:** Instead of a flat +0.10 offset, bright variants target a
  landing zone (capped at L=0.92). Dark accents (blue at L=0.57) get more
  boost than light ones (yellow at L=0.75).
- **C boost:** Uses 30% of available gamut headroom at the bright L, clamped
  to [0.01, 0.05]. This avoids wasting chroma budget on narrow-gamut hues.

base0F (brown) has no bright variant. Each bright variant is
**contrast-validated** against all three backgrounds. If the initial L
shift fails contrast, L is binary-searched in the direction that restores it.

### 5. Gamut clipping

`clipToGamut` does binary search on chroma (20 iterations) while holding L
and h fixed, testing **linear RGB** channels (not post-delinearize sRGB) to
avoid false negatives from the sRGB transfer function's clamping. This
guarantees every output colour is in sRGB without distorting its semantic
identity. `maxGamutChroma(L, h)` uses the same approach to pre-compute the
maximum achievable chroma for a given lightness and hue.

## Key constants and their rationale

| Constant | Value | Why |
|----------|-------|-----|
| `MAX_CLUSTERS` | 8 | One cluster per accent slot maximum |
| `MAX_ASSIGNMENT_DISTANCE` | 45° | Peaks further than this from a target don't claim it |
| `MAX_PEAKS` | 8 | Cap on extracted peaks |
| `MIN_ACCENT_C` | 0.07 | Floor for assigned accent chroma (also the floor of the image-derived ceiling) |
| `UNASSIGNED_ACCENT_C` | 0.05 | Chroma for accents with no image peak — muted but identifiable |
| `MAX_ACCENT_C` | 0.32 | Hard ceiling on accent chroma regardless of how vivid the image is |
| `ACCENT_BOOST` | 1.2× | Headroom above `chroma_upper` so accents read as focal points |
| `TINT_C_CEILING` | 0.04 | Hard cap on neutral chroma — past this, bases stop reading as neutrals |
| `TEMPERATURE_PULL` | 5° | Max global hue pull for unassigned accents (scaled by hue concentration) |
| `ALLOWED_L_SPREAD` | 0.35 | Threshold above which the palette-wide L-spread harmony penalty triggers |
| `sat_fraction` range | 0.35–0.92 | Floor keeps accents visibly chromatic for muted images; ceiling avoids gamut-boundary instability |
| `MIN_PAIRWISE_DE` | 0.12 | Minimum OKLab ΔE between any two accents |
| `MIN_CVD_DE` | 0.08 | Minimum OKLab ΔE between accent pairs under CVD simulation |
| `SAMPLE_LIMIT` | 65 536 | Fast analysis of large images; covers small chromatic regions |
| `SPATIAL_SIGMA_FRAC` | 1/3 | Gaussian σ for spatial weighting, as fraction of min(w, h) |
| `CHROMA_THRESHOLD` | 0.04 | Excludes near-grey pixels from *hue* statistics and 3D clustering |
| Chroma collapse | < 0.03 | k-means cluster gap below this collapses to joint mean (unimodal distribution) |
| Tone tint C | ≤ 0.04 | Adaptive ceiling with bell-shaped envelope (σ=0.45): binary-searched for max contrast-safe value |
| `MIN_ACCENT_CONTRAST` | 3.0 | Accent contrast against base00/base01 (WCAG AA-large) |
| `MIN_ACCENT_CONTRAST_BG2` | 2.5 | Accent contrast against base02 (selection highlight) |
| `MIN_DIFF_PAIR_CR` | 2.5 (1.5 light) | WCAG contrast between diff-paired accents (red/blue, green/blue); red/green at 1.8 for CVD |
| Accent L range (dark) | [0.45, 0.85] | Feasible L search range for dark-mode accents |
| Accent L range (light) | [0.35, 0.70] | Feasible L search range for light-mode accents |
| Accent L target | 0.65 dark / 0.52 light | Ideal L before constraint enforcement |
| `HUE_SAMPLE_SIGMA` | 30° | Gaussian kernel width for sampling clusters at a target hue |
| `MAX_HUE_PULL` | 25° | Maximum angular shift for unassigned accents toward image centroid |

## Why not just extract colours?

Pure extraction (e.g. k-means on image pixels alone) gives you colours that
exist in the image but makes no semantic guarantees. If the image has no
blue, you get no blue — making code, keywords, and functions invisible in
some editors.

We do extract colours (via 3D OKLab k-means), but we *assign* the extracted
clusters to semantically-correct slots rather than letting them define the
palette directly. Slots whose hues match a cluster get image-derived
(L, C, h); slots without a matching cluster keep their canonical hue at
muted chroma. The result is always usable, always semantically complete,
and image-derived where the image has the colour.

## Degenerate case analysis

| Input | Result |
|-------|--------|
| All-black | Dark mode, tones correct, no clusters → all accents at canonical hues with floor chroma |
| All-white | Light mode, tones correct, no clusters → all accents at canonical hues with floor chroma |
| Monochrome | Mode from median L; one cluster region covers the chromatic pixels; chroma_lower ≈ chroma_upper → uniform vibrance |
| Random noise | Wide unimodal chroma distribution → collapses to joint mean → uniform-moderate theme |
| Single saturated hue | One dominant cluster, one accent assigned with vivid chroma; 7 others muted |

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
  analysis.zig  Image profiling: spatial-weighted percentiles, k-means on
                chroma, 3D OKLab clustering for dominant colours
  peaks.zig     Cluster-to-peak extraction, hue sampling, accent target defs
  palette.zig   Palette generation (tone ramp, accent solver, bright variants)
  main.zig      CLI, YAML output, ANSI preview, terminal palette
vendor/
  stb_image.h   Vendored stb_image v2.29 (single-header C library)
  stb_image.c   Implementation unit (defines STB_IMAGE_IMPLEMENTATION)
```
