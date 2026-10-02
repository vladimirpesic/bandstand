# `bass_corpus.json`

The walking-bass source corpus of §6.4. Lives at `app/assets/bass_corpus.json`
(ADR 0006), read by `BassCorpusAssets.load`, modelled by `WbpSource` and
consumed by the tiler described in `docs/rules/corpus-tiling.md`.

Written by hand or by `tools/corpus_import/` (§6.4 of the plan), which slices a
MIDI performance against a chord annotation and emits this shape.

## Top level

```json
{
  "schemaVersion": 1,
  "name": "bandstand-walking-1",
  "instrument": { "lowestPitch": 28, "highestPitch": 55 },
  "phrases": [ ... ]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | int | 1. The loader refuses anything it does not understand. |
| `name` | string | Identifies the corpus in reports and in the tiling log. |
| `instrument` | object | The range every phrase must fit after transposition. Optional; defaults to E1–G3, the double bass of `corpus-tiling.md` §4.3. |
| `phrases` | array | The source phrases. At least one. |

## `phrases`

```json
{
  "name": "ii-V chromatic into the five",
  "chords": ["Dm7", "G7"],
  "beatsPerBar": 4,
  "notes": [38, 40, 41, 42, 43, 45, 47, 50],
  "tags": ["walking", "chromatic"],
  "tempoRange": [90, 240]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | Unique within the corpus. It is the identity the reuse window tracks, so two phrases sharing a name would be treated as one. |
| `chords` | string[] | The harmony the phrase was played over, one chord per bar, parsed by `ExtChordSymbol.parse`. Length is the phrase's length in bars, 1 to 4. |
| `notes` | int[] \| object[] | The notes. See below. |
| `beatsPerBar` | int | Optional, default 4. |
| `tags` | string[] | Optional style tags, free-form. `walking`, `two-feel`, `chromatic`, `pedal`, `ascending`, `descending`, `wide`, `low`. |
| `tempoRange` | [int, int] | Optional. The tempo band the phrase belongs in, per `corpus-tiling.md` §9. Absent means "usable at any tempo", which is the right default — the corpus should not have to answer a question nobody asked. |

### Notes, the short form

A plain array of MIDI pitches is read as consecutive quarter notes, one per
beat, which is what a walking line is. `beatsPerBar × chords.length` pitches are
required, and the count mismatching is an error rather than a truncation.

Velocity follows the beat: the downbeat of each bar is 94, everything else 82.
Duration is 0.92 beats — just short of legato, the way a walking line sits.

### Notes, the long form

When a phrase is not four-to-the-bar — a two-feel, a pedal, anything with a
rest — each note is an object:

```json
{ "beat": 0, "pitch": 38, "duration": 1.92, "velocity": 94 }
```

| Field | Type | Meaning |
| --- | --- | --- |
| `beat` | number | Onset in beats from the phrase's start. Non-negative, inside the phrase. |
| `pitch` | int | MIDI pitch, 0–127. |
| `duration` | number | Optional, default 0.92. Positive. |
| `velocity` | int | Optional, default 82 (94 on a bar's downbeat). 1–127. |

The two forms may be mixed across phrases in one file, but not within a phrase.

## Invariants the loader enforces

1. `schemaVersion` is understood.
2. Every phrase has a name, unique in the file.
3. Every chord symbol parses, and there are between 1 and 4 of them.
4. Every phrase has at least one note, and every note lies inside the phrase.
5. The short form's pitch count matches `beatsPerBar × chords.length`.
6. `tempoRange` is two positive integers, low first.

## Invariants the *tests* enforce

These are properties of the data, not of the loader, and a failing test is a
better place to find them than a mystery in the audio:

1. Every phrase **starts on the root** of its first chord, and **ends on a chord
   tone** of its last — constraints 1 and 2 of `corpus-tiling.md` §5. A phrase
   failing these can never be placed, so it is dead weight that looks like
   coverage.
2. Every phrase fits the instrument range in **at least one octave** at **every**
   destination root it claims — otherwise its transposibility map (§8) is empty
   somewhere and the phrase silently does not exist for a third of the keys.
3. The corpus **covers the segmentations the tiler asks for**, not just the
   common progressions: for each root profile the standard test forms produce,
   at least two phrases match. M0.5 finding 3 is that coverage is a corpus
   property that shows up immediately, and this is where it is checked.
