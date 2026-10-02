# Pitch, spelling and degrees

Written per §1 / §15. Implemented by `app/lib/domain/harmony/`.

Spelling is the subject of this document. A chart reader that transposes is
judged almost entirely on whether it writes `E7` or `Fb7`, and §4.1 names this
as "the single most visible correctness bug in a transposing chart reader".

## 1. Two different things called a "note"

- A **pitch** is a number, MIDI 0–127, 60 = C4. It has no spelling. `Note` in
  `note.dart` is a pitch with a duration and a velocity; it is what the
  generators emit and what the synth plays.
- A **spelling** is a letter plus an accidental: `Eb`, `F#`, `Cb`, `B#`. It has
  no octave and no absolute pitch — only a pitch *class*. `PitchSpelling` is
  what chord roots, bass notes and key signatures are made of.

The two meet only at render time. Nothing in the generation path needs
spelling; nothing in the chart path needs octaves.

## 2. Naturals

`Natural` is the seven letters, each with a semitone offset from C and a
one-based index:

| Letter | C | D | E | F | G | A | B |
| --- | --- | --- | --- | --- | --- | --- | --- |
| index | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| semitones | 0 | 2 | 4 | 5 | 7 | 9 | 11 |

Letters wrap: `B` + 1 letter step = `C`. Letter arithmetic is *modular in 7*,
pitch arithmetic is modular in 12, and keeping them separate is what makes
spelling work.

## 3. Alterations

An alteration is an integer in `-2..+2`: `bb`, `b`, natural, `#`, `x` (written
`##`). Beyond double is rejected at construction — a triple flat is always a bug
upstream, and accepting it produces chord symbols nobody can read.

`PitchSpelling(natural, alteration)` has:

- `pitchClass` = `(natural.semitones + alteration) mod 12`
- `accidentalCount` = `|alteration|`, used to prefer simple spellings.

Two spellings are **enharmonic** when their pitch classes match, and **equal**
only when letter and alteration both match. `F#` and `Gb` are enharmonic, not
equal. Nothing in the codebase may compare spellings by pitch class using `==`.

## 4. Degrees

A `Degree` is an interval from a root, *spelled*. It is not a semitone count:
`#9` and `b3` are both three semitones and are different degrees, and a voicing
engine that cannot tell them apart will double the third of an altered dominant.

A degree is written as if the root were C, which makes the letter unambiguous:

- `b3` is `E` with alteration −1;
- `#9` is `D` with alteration +1.

so `Degree(natural, alteration, asExtension)` where `asExtension` records only
whether the degree is *written* as 9/11/13 rather than 2/4/6. That flag changes
the printed symbol and nothing else: `add9` and `add2` are the same degree.

- `semitones` = `(natural.semitones + alteration) mod 12`
- `number` = `natural.index + (asExtension ? 7 : 0)` — the digit in the symbol
- `symbol` = accidental text + `number`, e.g. `bb7`, `#11`, `5`

Degrees sort by `number`, so a degree list always reads `1 3 5 b7 9 #11 13`.

Parsing a degree from text (`"b9"`, `"#11"`, `"bb7"`) accepts numbers 1–13.
`number > 7` sets `asExtension` and folds to `((number − 1) mod 7) + 1`.

## 5. Key signatures

A `KeySignature` is a tonic spelling plus a mode (major or minor). What it is
*for* is deciding, for each of the twelve pitch classes, which spelling to use.

- The seven diatonic pitch classes get their diatonic spellings, by construction:
  start at the tonic letter and walk the mode's letter steps, choosing the
  alteration that lands on the right pitch class. In `E` major that produces
  `E F# G# A B C# D#`, so pitch class 6 spells `F#`, never `Gb`.
- The five chromatic pitch classes follow the key's **accidental direction**:
  a key with sharps in its signature spells them sharp, a key with flats spells
  them flat. `C` major and `A` minor have neither, and are treated as flat-side,
  which is the jazz convention (`Eb7`, not `D#7`).

`sharpCount` is the classic circle-of-fifths number, −7 to +7. Keys outside that
range (`G#` major, seven sharps and a bit) are rejected: they are always a
spelling error upstream, and no chart is written in them.

## 6. Choosing a spelling for a pitch class

This is the whole ball game. `SpellingPreference` has three modes:

1. **`key(KeySignature)`** — use the key's table from §5. This is what the app
   uses whenever it knows the destination key, which is whenever the user
   transposes a song.
2. **`sharps` / `flats`** — force a side. Used by importers that state a
   preference, and by tests.
3. **`automatic`** — no key known. Use the flat-side default table:

   | pc | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
   | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
   | | C | Db | D | Eb | E | F | Gb | G | Ab | A | Bb | B |

   Flat-side because the jazz repertoire is flat-side: `Bb`, `Eb`, `Ab` and `Db`
   are ordinary keys and `D#` is not.

In every mode the result has `|alteration| <= 1`. A spelling engine that can
return `Fb` or `B#` unbidden will eventually return `E##`, and no reader wants
that on a music stand.

## 7. Transposition

`ChordSymbol.transposed(semitones, {preference})`:

1. Target pitch class is `(source.pitchClass + semitones) mod 12`.
2. Spelling comes from the preference (§6). **Not** from letter arithmetic on
   the source.

Step 2 is the important one, and it is why `Eb7` up a semitone gives `E7` rather
than `Fb7`. Letter arithmetic — "up a minor second means up one letter" — is the
obvious implementation and it is wrong for exactly the cases that matter. A
chart is not a theory exercise; it is read at speed in bad light.

A slash chord transposes its bass by the same interval with the same preference.

### 7.1 What "transpose by n, then by −n, is identity" actually means

§11.2 asks for that property test. Taken literally it cannot hold, and should
not: `D#7` up a semitone is `E7`, and `E7` down a semitone is `Eb7`. The round
trip has *corrected the spelling*, which is the desired behaviour.

So the property splits in two, and both are tested:

- **Always:** the round trip preserves the pitch class, the chord type and the
  bass. Transposition never changes what is played.
- **For canonically-spelled chords:** the round trip is exactly the identity. A
  chord is canonically spelled when its root is what the preference would
  choose for its own pitch class. Every chord the app produces is canonically
  spelled, because every chord the app produces came out of this function.

## 8. Instrument transposition

A global, render-time-only setting (§9): the stored song is never mutated.

| Setting | Semitones added to concert pitch | Player |
| --- | --- | --- |
| C | 0 | piano, guitar, bass, voice |
| Bb | +2 | trumpet, tenor and soprano sax, clarinet |
| Eb | +9 | alto and baritone sax |
| F | +7 | french horn, english horn |
| G | +5 | alto flute, treble-clef instruments reading in G |

A Bb trumpet sounds a major second *below* what it reads, so to sound concert C
it must read D — the written chart moves **up** two semitones. Getting this
backwards is the classic bug, and the table above is the direction that is
correct.

The spelling preference for the transposed chart comes from the *destination*
key: a chart in concert `Eb` read by an alto player is written in `C`, and its
chords spell accordingly.
