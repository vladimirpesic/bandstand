# Laying out a chart

Written per §1 / §15, implementing §8.1. Implemented by `app/lib/render/`.

One `CustomPainter`. No engraving library, no webview, no SVG. What is drawn is
a bar grid, chord symbols, section letters, repeat structures, endings,
coda/segno marks, bar numbers, a cursor, and optional annotations.

**The constraint that decides everything: legible at two metres.** Not legible
on a desk — on a stand, across a room, in bad light. Every trade below resolves
in favour of bigger type.

## 1. What is laid out

The **written page**, not the flattened form. The chart shows what the player
reads: `|: A B :|` is four bars of ink, not six of music. Playback maps onto it
through `SongChordSequence.sourceBars` (§4.5), which is why that map exists.

Layout is a pure function of

- the `ChordLeadSheet`,
- the width available,
- a `ChartStyle` — type sizes, paddings, and the bars-per-line preference,

and it returns geometry. Nothing about playback, selection or theme enters it,
so the same layout serves the reading mode, the editor and the PDF export
(§5.3).

## 2. Bars per line

The unit of layout is the **line**: a row of equal-width bars.

1. Start from the style's preferred bars per line — 4 for an ordinary chart, 2
   for a dense one, 8 for a simple one.
2. Measure. A bar must be at least `minimumBarWidth` wide, which is derived from
   the chord type size rather than fixed, so it scales with the type.
3. If the preferred count would make bars narrower than that, **reduce the
   count** — never shrink the type. Four bars of unreadable chart is worse than
   two bars of readable chart, and on a phone in portrait two is the right
   answer anyway.
4. If a bar's chords still do not fit at the resulting width, the *chords* shrink
   — down to a floor. A bar with five chords in it is rare and is the one place
   where something has to give.

## 3. Sections never start mid-line

A section boundary forces a line break. `A` starting halfway along a line is the
single fastest way to lose your place on a repeat, and a musician's eye uses the
left edge as an anchor.

The consequence is short lines: a 6-bar section at 4 bars per line lays out as
4 + 2, and the second line's bars are the *same width* as the first's rather
than stretched to fill. Stretched bars make the grid lie about how much music is
in them.

## 4. What each bar carries

Within a bar, positions are proportional to beats: a chord on beat 3 of 4/4 sits
halfway across. Chords are laid out left to right at their beat positions, and
never overlap — a later chord is pushed right if it must be, and if the pushing
runs out of bar the bar's chords are scaled down (§2.4).

A bar also carries, drawn around rather than inside the chord row:

| Mark | Where |
| --- | --- |
| Bar number | above the bar line, small, every bar at the start of a line and every fourth otherwise |
| Section letter | above the first bar of the section, large |
| Repeat barlines | on the bar's left or right edge, thick line plus dots |
| Ending bracket | above the bar, spanning its bracket's bars, with the pass numbers at the left |
| Segno, Coda, To Coda, Fine, D.C., D.S. | above the bar, right-aligned for tail marks and left-aligned for head marks |
| Annotation | below the chord row |

## 5. Pickup bars

A pickup is a short first bar (§4.5 §5). It is drawn **narrower**, in proportion
to its length, and its bar number is 0 — which is what a chart does, and it
stops the first full bar being called bar 2.

## 6. Repainting

Two layers:

- **The chart layer** repaints when the song, the width or the style changes.
  Each line is cached as a `Picture`, so a chord edit repaints one line.
- **The cursor layer** repaints every frame while playing, and draws nothing but
  the cursor. §3 budgets 4 ms for a cursor frame, and the way to hit that is to
  not re-draw the chart to move a rectangle.

The cursor is positioned from the **written** bar, which comes from the playback
bar through `SongChordSequence.sourceBars`. A tune with repeats has one written
bar highlighted for several playback bars, which is exactly right — the player's
eye is on the ink.

## 6a. Cost

Laying out the chart is **linear in bars**, and it has to stay that way.

`ChordLeadSheet` buckets its items by bar once, in the same pass that sorts
them, and `itemsInBar`, `itemsInBarOfType` and `sectionAt` read that index. This
is not an optimisation looking for a problem: laying a bar out asks the sheet
six separate questions about that bar, so answering each by scanning every item
made the whole layout O(bars × items). It was invisible at 32 bars — under two
milliseconds — and 24 ms at 400, which is a dropped frame and a half on a chart
somebody could plausibly write. Measuring it is what found it; the benchmark
suite that did it went with the generative band (ADR 0012).

The rule that falls out: **anything that walks the bars must not ask a question
whose cost is the size of the sheet.** The MusicXML exporter walks the bars the
same way the renderer does, and it got the same fix for free.

Measured on the reference machine, at a 1200 px width:

| | Layout | Cursor frame | Full chart repaint |
| --- | --- | --- | --- |
| 100 bars | 1.0 ms | 0.012 ms | 7.1 ms |
| 400 bars | 4.7 ms | — | — |

The cursor frame is the one §3 budgets at 4 ms, and it has three hundred times
the headroom it needs — because it draws a line and a triangle, not a chart.

## 6b. Numbers instead of letters

The chart can be read in **Nashville numbers** — `2m7 | 57 | 1maj7` where the
ink says `Dm7 | G7 | Cmaj7` — by handing the layout the key to count from.

§9 puts this at M8 and says it *"falls out of the degree model almost free"*,
which was true of the numbers themselves: `Nashville.format` has existed since
then, and the chord reference screen has shown it. What it did not do is reach
the chart, which is the only place the feature is actually for. §9's own
rationale is *"playing a tune in a key nobody wrote it in, which is most of
them: a singer's key is not the Real Book's"* — and you do that while reading
the chart, not while reading a lookup table.

The rules:

- **The key counted from is the song's own written key**, not the transposed
  one. A number is an interval above the tonic, and transposing moves the tonic
  and every chord together, so the numbers do not change. This is the whole
  point of the system: one sheet of numbers works in twelve keys.
- **Transposition and numbers are therefore mutually redundant, not exclusive.**
  Turning numbers on while transposed up a tone is not an error and does not
  need to be blocked; the display simply stops depending on the transposition.
  The reading-mode banner still says what the transposition is, because it
  affects what the band plays.
- **The quality survives unchanged.** The number says which chord, the symbol
  after it says what kind. `2m7` in any key is the minor seventh on the second
  degree.
- **A slash chord keeps its bass, also as a number.** `1/3` is a first
  inversion; writing `1/E` would defeat the point.
- **Degrees above the fourth are written flat, not sharp** — `b6`, not `#5`.
  That is the convention and it matches how the degree is heard.
- **Every chord has a number**, diatonic or not. `Nashville.isDiatonic` exists
  to *mark* the ones that are not, which is a display decision, not a formatting
  one.
- **Nothing about the stored song changes**, exactly as with transposition (§9).
  It is a way of drawing the chart, and it is not exported: MusicXML and PDF
  write the letters, because that is what the page says.

Bar widths are laid out from the measured text as always, so a chart in numbers
reflows — `1maj7` is narrower than `Cmaj7`, and the layout does not pretend
otherwise.

## 7. Reading mode

No chrome, the largest type that fits, high contrast, dark. Tap zones only at
the far left and right edges, so a hand resting on the middle of the screen does
nothing. Wake lock on, orientation locked, and — enforced in the library rather
than the UI — no writes at all (§5.4).

The page-turn unit is the **line**, not the bar: scrolling by bars makes the eye
chase, and a musician reads a line at a time.

## 8. What this deliberately does not do

- **Engraving.** No beaming, no note spacing, no part layout. Charts, not scores
  (§2 non-goals).
- **Multi-bar rests** as a layout primitive. A rest is a bar with no chord in it.
- **Proportional bar widths** by content. Equal-width bars are what a chart
  looks like, and unequal ones make the grid unreadable at two metres.
