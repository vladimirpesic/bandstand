# Importing MusicXML

Written per §1 / §15, for §5.2 item 2. Written from the MusicXML 4.0
specification and from the format's own documentation — **not** from the
converters in `/home/vladimir/develop/refs/vree/`, which §14.2 puts out of
scope unless the human has said otherwise, and which they have not.

## 1. What Bandstand takes from a MusicXML file

A chord chart, and nothing else. The format carries a full score; Bandstand's
model (§4.3) holds chords, bars, sections and structure. So:

| MusicXML | Becomes |
| --- | --- |
| `<harmony>` | a chord at a bar and beat |
| `<measure>` | a bar |
| `<attributes><time>` | the time signature |
| `<attributes><key>` | the key signature |
| `<barline><repeat>` | a repeat |
| `<barline><ending>` | an ending |
| `<sound segno/coda/dalsegno/tocoda/fine>`, `<rehearsal>` | navigation and sections |
| `<work-title>`, `<creator type="composer">` | title and composer |
| `<sound tempo>` | the tempo |
| everything else — notes, dynamics, lyrics, layout | **discarded** |

Discarding the notes is not a limitation to apologise for: a chord chart is
what this app is, and a file's melody has nowhere to go until §9's melody
display exists.

## 2. Both encodings

MusicXML comes **partwise** (`<score-partwise>`, measures inside parts) and
**timewise** (`<score-timewise>`, parts inside measures). Partwise is what
everything writes; timewise is in the specification and almost never seen.

Bandstand reads partwise and **refuses timewise with a message that says so**,
rather than silently importing an empty chart. A file nobody produces is not
worth a transformation pass, but a file that imports as nothing is worth an
explanation.

A `.mxl` file is a **zip** containing the `.xml` plus a `META-INF/container.xml`
naming it. That is worth supporting, because it is what most software actually
saves.

## 3. Which part

A score has parts; a chart has one. Bandstand takes the part with the **most
`<harmony>` elements**, because that is where the chords are — in a piano-vocal
score it is the piano, in a big-band chart it is the guitar, and in a lead sheet
there is only one anyway.

A file with **no `<harmony>` anywhere** is not a chord chart. It imports as a
song with the right number of empty bars and reports that it found no chords,
rather than failing: the bar count and the structure are still worth having.

## 4. Chords

`<harmony>` gives a root, a kind, and optionally a bass and alterations.

- **The root is spelled**, `<root-step>` plus `<root-alter>`, and the spelling
  is kept: `B` with an alter of −1 is B♭ and must not become A♯
  (`docs/rules/pitch-and-spelling.md`).
- **The kind maps to a chord type.** The vocabulary is fixed by the format and
  is smaller than Bandstand's, so the mapping is a table. Where a `<kind>`
  carries a `text` attribute — which is how software records a symbol the
  vocabulary cannot express — **the text wins**, parsed through the ordinary
  chord parser. That is what round-trips Bandstand's own exports, and what
  preserves `7alt` rather than flattening it to `dominant`.
- **`<degree>` elements alter the kind**: an added, altered or subtracted
  degree. They are applied on top of the mapped type, so `major-seventh` plus
  `add 9` is `maj9`.
- **`kind="none"`** is `N.C.`
- **`<offset>`** places the chord inside the bar, in divisions. Absent, it sits
  on the downbeat.

## 5. Structure

The hard part, and the one §4.5 already solved for the iReal importer: the
model has repeats, endings, and D.C./D.S./coda navigation, and MusicXML spells
them across `<barline>` and `<direction>`.

- `<repeat direction="forward">` on a left barline opens a repeat;
  `direction="backward"` on a right barline closes one, with `times` giving the
  play count.
- `<ending number="1,2" type="start">` opens an ending; `type="stop"` or
  `"discontinue"` closes it. The numbers are a comma-separated list and a
  first-and-third ending is legal.
- `<sound>` carries `segno`, `coda`, `dalsegno`, `tocoda`, `fine` as
  attributes, and `<direction-type><segno/>` / `<coda/>` carry the marks
  themselves. Both spellings are read, because software disagrees about which
  to write.
- `<rehearsal>` becomes a section name. A file with rehearsal marks gets its
  sections from them; one without gets a single section, as
  `ChordLeadSheet.empty` does.

**A structure that cannot be resolved is reported, not repaired.** The form
navigator (§4.5) already refuses to guess at a broken repeat; an importer that
quietly closed one would be hiding the same fault a bar earlier.

## 6. What arrives, and what is checked

The acceptance §5.2 names is the **Unofficial MusicXML Test Suite** — about 130
files, built for LilyPond's importer, and data rather than code so no licence
question arises.

It is **not vendored**. It is fetched on demand into `build/`, which is
git-ignored, by `just fetch-musicxml-suite`, and the tests skip with a message
when it is absent. The same discipline as the soundfont: third-party corpora
are a thing to point at, not to copy in.

What the suite is for is **not** asserting that every file imports to something
specific — most of them are notation edge cases with no chords in them at all.
It is asserting that **no file crashes the importer**, and that the ones which
do carry harmony produce the chords they name. A parser that survives 130
adversarial files is a parser that will survive a user's library.

## 7. What this deliberately does not do

- **Melody.** Nowhere to put it (§1).
- **Multiple parts, transposing instruments, percussion staves.**
- **Round-tripping.** Export is `docs/rules/exporters.md` §5 and is tested
  separately. A file that goes out and comes back should be the same *chart*,
  and that is asserted — but byte equality is not a goal and would be a wrong
  one.
- **`<figured-bass>`**, which is a different notation for a different music.
