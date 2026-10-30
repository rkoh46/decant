# Decant design

Read this before touching any screen. The rules come from the `unslop-native` skill (unslop by Damir
Sokolovsky, CC BY 4.0, and Appllama's app-design skill, MIT); this file records the decisions made for Decant.

## Direction

- **Product.** Moves photos, backups and firmware between an iPhone and drives you own, for one person who wants
  everything off the phone and under their control.
- **Character.** Exact, careful, unhurried.
- **World.** A workbench: a phone lying next to a drive. Black glass, aluminium, a hairline of light on an edge.
- **Moments.** The phone render (model-accurate body, the real camera roll on its screen) and the storage bar
  drawn as an instrument. Everything else is quiet.
- **Signature.** The verify tick: a green check that appears only after a byte-exact copy, and nowhere else.

## Tokens

- Spacing on a 4 pt grid: page 24, cards 20, gaps 16, rows 32, top bar 60, bottom bar 52, grid toolbar 40.
- Surfaces are the system neutrals: `windowBackgroundColor` page, `controlBackgroundColor` cards, `.quaternary`
  for selected tabs and tracks, `.quinary` for chips, `.separator` hairlines. No hue gradients anywhere; the
  phone body is one neutral with a tone shift and a 16 % white rim.
- One accent, the system accent, spent on the primary button (Copy to Mac), the grid selection and the "Photos
  & videos" segment of the storage bar. Nothing else is tinted.
- Semantic colours only for meaning, toned: `Tone.ready` green dot and verify tick, `Tone.warning` amber for
  locked/connecting and failures.
- Type is the system font: 22/500 title, 16/500 wordmark, 15/500 card titles, 13 table text, 12 legends,
  captions secondary. Weights 400 and 500 only. Sentence case labels. Numbers `monospacedDigit()`, serial
  `monospaced()`.
- Radii: cards 12, buttons and chips 8, tracks and tiles 4, phone body 22 to 30 by model.
- Icons are SF Symbols in the text colour they sit with; never their own colour.

## Structure

Top bar (wordmark, Device/Photos tabs, device chip) → Device tab: phone card 272 wide, info table in two
columns of 32 pt rows with hairlines, storage card, a Tools row and a Photos-destination row of standard
buttons → Photos tab: 220 sidebar list, grid toolbar, thumbnail grid, Image Capture-style bottom bar.

## Copy

Plain, no exclamation marks, no trailing periods on labels. Destructive actions say what happens ("You will need
to press its side button to turn it on again") and confirm once; deletes confirm with the count. Status is a
word in tables ("Locked", "Ready") and a sentence in captions ("Locked: unlock and tap Trust").

## Checking

Build, launch, capture only the window (`tools/winid` pattern: `CGWindowListCopyWindowInfo` →
`screencapture -l`), look at it in both appearances. `DECANT_TAB=photos` opens the Photos tab for screenshots.
Stop at "cannot find a flaw", not "looks fine".
