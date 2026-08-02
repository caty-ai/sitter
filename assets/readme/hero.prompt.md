# Sitter Hero — reproducible ImageGen brief

This brief derives Sitter's Hero from a shared parent visual system (a warm
monochrome retro-TV "planetary ecosystem" composition used across sibling
projects). The rules below are self-contained: everything needed to
regenerate or re-derive the hero is stated here.

## Output

- `assets/readme/hero.png`: opaque `1600 × 900 px` PNG
- `assets/readme/social-preview.jpg`: `1280 × 640 px`, solid background,
  under 1 MB
- Social export recipe: scale the `1600 × 900` master to `1280 × 720`,
  then remove `40 px` from both the top and bottom with a vertical centre crop.

## ImageGen mode

- Built-in ImageGen edit
- The parent visual system's canonical hero is the edit target and
  composition reference.
- Preserve the source asset's visual family; do not imitate the
  persona-styled sibling asset.

## Prompt

> Create a derived Sitter Hero by editing the parent visual system's
> canonical hero.
> Preserve the warm monochrome 1950s–60s overseas educational-TV / CRT
> planetary-ecosystem composition, rounded black CRT frame,
> sepia-cream-charcoal halftone texture, editorial optimism, and 16:9 layout.
>
> Keep the left approximately 38% as the copy block and the right as the same
> planetary ecosystem. Keep all four copy lines and the central globe safe for
> a later 1280×640 centre-crop social preview. Keep the design recognizable at
> 320 px wide.
>
> Render exactly and only these four strings:
>
> 1. `SITTER`
> 2. `A WATCH POST FOR DELEGATED AI WORK`
> 3. `caty-ai/sitter`
> 4. `FREE & OPEN SOURCE · MIT LICENSE`
>
> Preserve the highly legible condensed period educational-TV title
> treatment. `SITTER` is the large dominant title. Render every string exactly
> once with correct spelling and no extra text or pseudo-text.
>
> Color only one tiny outer planetary observation point and its existing halo
> in a restrained muted coral-orange, with a subtle rose edge. Preserve its
> spherical shading and analog texture; every other planet remains monochrome.
> It suggests a quiet watch post looking inward from the edge, never a
> controller, command centre, scheduler, runtime owner, required dependency,
> data-flow source, or central hub. Keep the colored point and halo restrained
> and subordinate to the central ecosystem globe.
>
> Preserve the source Hero's overall geometry, crop safety, planetary
> metaphor, solid background, high tonal separation, and retro CRT/halftone
> visual language. The image does not encode architecture or dependency truth.

## Exclusions

- No humanoid figure, luminous woman, horns, purple cosmic character, or
  imitation of the persona-styled sibling asset.
- No lighthouse beam, control room, dashboard, terminal/code UI, or robots.
- No arrows, pipes, cables, data-flow lines, module labels, status badges,
  extra words, or watermark.
- No visual claim that Sitter controls the observed runtime or aggregates all
  jobs into one authority.

## Acceptance checklist

- [ ] Master is exactly `1600 × 900 px`, opaque, with a solid background.
- [ ] The raster contains the four exact strings and no other text.
- [ ] Only one tiny outer planet and its halo use the coral-orange accent.
- [ ] The colored watch post reads as orientation, not dependency or authority.
- [ ] The Hero remains coherent at `1600`, `800`, and `320 px` widths.
- [ ] Grayscale retains the title, globe, planets, and observation point.
- [ ] The `1280 × 640 px` social crop retains all four strings and the globe.
- [ ] English and Japanese alt text explain that the image is a metaphor and
      does not encode dependencies.
- [ ] Exact runtime and connection truth remains in README body text.
