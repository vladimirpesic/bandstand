# Exporters

Written per §1 / §15, for §5.3 and M9: *"MIDI (multi-track, with markers per
song part), WAV/FLAC via offline render, PDF chart (reusing the same
`CustomPainter` layout), MusicXML."*

## 1. What an export is for

Four formats, four different reasons, and they are not variations of one thing:

| Format | Who reads it | What must survive |
| --- | --- | --- |
| MIDI | a DAW, another band-in-a-box | the *performance* — every note the generators wrote |
| WAV | anything | the sound |
| PDF | a music stand, a printer, a bandmate | the *page* — exactly what the chart renderer draws |
| MusicXML | notation software | the *chart* — chords and structure, not the performance |

The distinction that matters is the last two rows against the first two. MIDI
and WAV export what Bandstand **played**; PDF and MusicXML export what the
player **wrote**. A tune whose generated bass line is rerolled has a different
MIDI export and an identical PDF one, and that is correct.

## 2. MIDI

Format 1, one track per voice, at the song's own PPQ.

- **A conductor track first**, carrying the tempo map, the time signature and a
  **marker per song part** — `A`, `A`, `B`, `A`. §5.3 asks for the markers by
  name, and they are what makes an exported file navigable in a DAW rather than
  four minutes of undifferentiated notes.
- **One track per generated voice**, named for the voice: `Drums`, `Bass`,
  `Piano`. The drum track is on channel 10 as General MIDI requires; the rest
  take the channels the generator assigned.
- **A program change at the top of each track**, so the file sounds like
  something when opened without Bandstand's soundbank.
- The export is of a **generated** song, so it takes a seed. Exporting the same
  song twice with the same seed gives byte-identical files — the determinism
  test of §11.2, applied at the boundary.

## 3. Audio

The offline renderer of M4 already does this, deterministically and to the byte.
Export is a file dialogue in front of it.

- **WAV, 16-bit stereo.** FLAC is in §5.3 and is not here: it needs an encoder,
  which is a dependency, and nothing in the workflow is short of disk.
- **The tail is rendered**, not cut: a reverb that stops at the last note is a
  worse artefact than three seconds of silence.
- It renders through the **same synth** as playback, so what is exported is what
  was heard.

## 4. PDF

Reuse the `CustomPainter`. That is the whole design, and it is why §8.1 insisted
the renderer be a painter rather than a webview: a painter draws to any canvas,
and a PDF page is a canvas.

- **Page size follows the paper**, not the window: A4 portrait by default, and
  the layout engine reflows to it exactly as it reflows to a phone. A chart
  exported to PDF is *not* a screenshot.
- **The cursor is not drawn.** It is a playback artefact and has no place on a
  printed page.
- **Bar numbers are on**, because a printed chart is one people talk about
  across a room — "from bar 17".
- One song per file. A set list of PDFs is a folder, not a document.

## 5. MusicXML

Chords via `<harmony>`, and the structure of §4.5 — repeats, endings, coda,
segno — as barline and direction elements.

- **Chords, not notes.** Bandstand's charts have no melody, so the export is a
  measure per bar carrying `<harmony>` and a whole-measure rest. Notation
  software renders that as a slash-notation chart, which is what it is.
- **The written page, not the flattened one.** A repeat exports as a repeat, not
  as the bars played twice. Flattening on export would lose the thing the format
  is best at.
- **Root and quality are spelled**, not reduced to pitch classes: `<root-step>B`
  with `<root-alter>-1</root-alter>` is B♭, and writing A♯ instead would be
  wrong in exactly the way `docs/rules/pitch-and-spelling.md` exists to prevent.
- A chord type Bandstand knows and MusicXML does not gets the nearest `<kind>`
  plus a `text` attribute carrying the symbol as written, so nothing is silently
  renamed.

## 6. Where the files go

A single choice, made once: exports land beside the library, in
`~/Music/Bandstand/exports/`, named from the song's title plus its id
(`<title>-<id>.<ext>`), so two songs with the same title never overwrite each
other. Not a file dialogue per
export — a player exporting a set does not want twelve dialogues — and not the
library folder itself, which is `song_library`'s and must stay tidy (§5.4).

The path is **returned to the caller**, so the UI can say where it went. An
export the user cannot find has not happened.

## 7. What this deliberately does not do

- **FLAC, MP3, stems.** An encoder is a dependency; stems are a DAW's job.
- **Round-tripping MusicXML.** Export is not import. §5.2 has the importer, and
  the two are tested separately.
- **Exporting a playlist as one file.** A set is an ordering, not a document.
- **Printing directly.** The platform's own print dialogue takes a PDF, and
  producing one is where Bandstand's job ends.
