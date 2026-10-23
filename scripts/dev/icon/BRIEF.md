# Variant 1 — Split window (literal)

App: muxFinder, a native macOS menu bar app that finds tmux sessions on the user's Macs and
opens them in iTerm2. The same glyph is used on the app icon and, black on transparency, as
the macOS menu bar template image.

## Mark

A tmux-style split terminal window: a rounded-rectangle window frame whose interior is split
into three panes the way tmux splits them, with a solid status bar along the bottom.

Construction (all values are fractions of the canvas side):

- Frame: outer box 0.64 wide × 0.52 tall, optically centred on the canvas, outer corner
  radius 0.07. Drawn as a stroke of weight 0.065, fully inside the outer box. Closed form.
- Status bar: a solid filled band 0.11 tall along the inside bottom of the frame, merging
  with the bottom frame stroke into one solid bar spanning the full inner width.
- Vertical divider: weight 0.065, splitting the pane area (inside the frame, above the
  status bar) into a left pane of 55% of the inner width and a right column of 45%.
- Horizontal divider: weight 0.065, splitting only the right column into two equal panes.
- Dividers join the frame and the status bar without gaps. No title bar, no traffic lights,
  no prompt or text inside the panes.
- Symmetry: none; the asymmetric split is the point.

## Palette

- bg-start: #1D3A6D
- bg-end: #071533
- glyph-fill: #FFFFFF
- accent: #3DDC84

`bg-start` and `bg-end` are the average colours of the top and bottom tenths of `plate.png`
(measured when it was added), so the gradient used at 32 px and below matches the painting
used above. The plate was painted from the earlier `#1E2F57` → `#0A1024`, the colours in the
ChatGPT prompt.

## Background (for the painted plate)

Deep midnight blue, soft diagonal light falling from the top left, a very faint brushed-glass
texture, quiet depth. Nothing else.

## Mood

Calm, precise, nocturnal, native.

## Legibility rule

The mark must still read as a window split into panes with a bar along the bottom at
16×16 px. No feature thinner than 1/16 of the canvas.
