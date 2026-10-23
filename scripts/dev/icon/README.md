# App icon and menu bar icon sources

These files are the source of the app icon and the menu bar icon (PLAN.md D28). The generated
files live in `Resources/` at the repository root and are committed; `scripts/build-app.sh`
copies them into the bundle. Nothing here runs during a normal build or in `swift test`.

| File | What it is |
|---|---|
| `BRIEF.md` | The design brief: the mark's construction, the palette (`bg-start`, `bg-end`, `glyph-fill`, read by `compose.swift`), the mood and the 16 px legibility rule. |
| `glyph.swift` | Draws the split-window mark in one colour on transparency at any size. Every measure is a fraction of the size, snapped to whole pixels. Written with Codex from `BRIEF.md`. |
| `compose.swift` | Stacks the background and the mark into the macOS icon shape (a rounded tile of 824/1024 with a soft shadow) and a full-bleed square. |
| `plate.png` | The background, painted by ChatGPT from the prompt below: 1024 × 1024, opaque, no shape or symbol. |
| `build-icon.sh` | Compiles both renderers and writes `Resources/AppIcon.icns` and `Resources/MenuBarIcon.png`, `@2x`, `@3x`. |

## Regenerate

```
scripts/dev/icon/build-icon.sh    # writes Resources/
scripts/build-app.sh              # copies them into build/muxFinder.app
```

## Rules the outputs follow

- The mark is drawn natively at every size and never scaled, so it stays crisp at 16 px.
- The painted background is used above 32 px. At 32 px and below a painting is only noise,
  so the background there is `BRIEF.md`'s two-stop gradient from `bg-start` to `bg-end`. The
  gradient is also used at every size when `plate.png` is missing (the script warns).
- On macOS the mark is drawn at the tile's own size (824/1024 of the canvas), so it stays
  about 60% of the visible icon.
- The menu bar icon is a template image: black on transparency, no colour (macOS tints it for
  light and dark menu bars). It is drawn on a canvas 24/18 the size of the 18 pt slot and
  centre-cropped, so the mark fills about 15 of the 18 pt like the system's symbols.

## Changing the art

- Colours: edit the palette in `BRIEF.md` and re-run. A new background colour also needs a new
  `plate.png`.
- The mark: change `glyph.swift`, then check it at 16, 18 and 32 px as well as 1024 before
  re-running.
- The background: paint a new plate with the prompt below, check that it is square, at least
  1024 px, opaque, and has no rounded corners, frame or symbol of its own (macOS applies the
  rounded shape; a painted one would be rounded twice), scale it to 1024 × 1024 and save it as
  `plate.png`.

## ChatGPT prompt for `plate.png`

```
Generate a square 1:1 image, 1024×1024 pixels: an app icon background plate only, which will
be used later as the bottom layer of an app icon. Full-bleed square: the colour runs flat-on
right to all four edges and corners of the canvas. No rounded corners, no squircle, no drop
shadow, no border, no frame, no vignette edge, no device or icon mockup. No glyph, symbol,
logo, letter, number, text, object or subject of any kind — background only.

Look: calm, precise, nocturnal, native. A gradient from #1E2F57 (top left) to #0A1024 (bottom
right): deep midnight blue, soft diagonal light falling from the top left, a very faint
brushed-glass texture, quiet depth. Keep the middle uncluttered, because a flat white mark
will be laid over it later (do not draw that mark).
```
