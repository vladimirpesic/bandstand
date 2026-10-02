# The plain text lead sheet

Written per §1 / §15, for §5.2 item 3: *"Plain text lead sheet —
`| C6 | Am7 | Dm7 G7 |`. Trivial, and the fastest way for **you** to enter a
tune."*

The audience is one person with a keyboard and a tune in their head. Everything
below follows from that: it has to be faster than the editor, and it has to be
readable when you come back to it.

## 1. The shape

```bash
Title: Blue Bossa
Composer: Kenny Dorham
Key: Cm
Tempo: 150
Time: 4/4

A:
| Cm7  | Cm7 | Fm7    | Fm7 |
| Dm7b5| G7  | Cm7    | Cm7 |
B:
| Ebm7 | Ab7 | Dbmaj7 | Dbmaj7 |
| Dm7b5| G7  | Cm7    | G7    |
```

- **Headers first**, `Name: value`, one per line, in any order, all optional.
- **A blank line** ends the headers. Everything after is chart.
- **A line ending in `:`** with no bar lines is a section name.
- **Bars are between `|`.** Leading and trailing pipes are optional, so
  `C | Am` and `| C | Am |` are the same two bars.
- **Whitespace is free.** Columns line up or they do not; it changes nothing.
- **`#` starts a comment**, to end of line.

## 2. Chords in a bar

Whitespace separates them, and they **divide the bar evenly**: `| Dm7 G7 |` in
4/4 is two beats each, `| C Am Dm G |` is one beat each.

That is the convention every chart in this notation uses, and the alternative —
a syntax for durations — would make the common case worse to serve a rare one.
A bar needing anything else is a bar to open the editor for.

Two spellings for "keep playing the last chord":

- **`%`** repeats the *previous bar*, chords and divisions and all.
- **`/`** inside a bar is a beat of the chord before it, so `| C / / / |` is a
  bar of C and `| C / G / |` is two beats each. It is what a player writes when
  they want the beats visible.

An **empty bar** — `| |` — carries no chord and sounds as the one before it,
which is what the form navigator already does with a bar nobody wrote a chord
in.

## 3. Structure

Kept deliberately small, because the editor is better at it and this is for
speed:

- `A:`, `B:`, `Intro:` — a section, starting at the next bar.
- `|:` and `:|` — repeat open and close. `:|x3` plays it three times.
- `|1.` and `|2.` before a bar — first and second endings, closing at the next
  ending or repeat.

Everything else in §4.5 — D.C., D.S., coda, segno — is **not** in this format.
A tune with that structure is a tune worth opening the editor for, and putting
it here would double the syntax to serve the tunes it is worst at.

## 4. What a failure looks like

Every problem names its line, and **parsing continues**. A typo in bar 30 must
not lose bars 1 to 29: the import comes back with the chart it could read and
a list of what it could not, and the caller decides.

The one thing that stops it is a document with **no bars at all**, which is not
a lead sheet.

## 5. What this deliberately does not do

- **Melody, lyrics, or rhythmic notation.** `| C. . |` is a different format.
- **Round-tripping.** There is no text *exporter*: the chart is the song file,
  and a second serialisation is a second thing to keep in step.
- **Guessing the key.** A tune with no `Key:` header is in C, and the editor's
  key field is one click. Inferring it from the chords is wrong often enough to
  be worse than the default.
