# Reading iReal Pro charts

Written per §1 / §15. Implemented by `app/lib/io/importers/ireal_import.dart`.

§5.2 calls this "the highest-leverage feature in this entire plan": it is how a
library gets populated in an evening rather than a year.

## 1. The two URL schemes

| Scheme | Body | Status here |
| --- | --- | --- |
| `irealbook://` | plain text | **implemented** |
| `irealb://` | the same text, scrambled | **implemented** — the scrambling is §7 |

Both carry the same fields and the same chord grammar, so everything below
applies to either; only the one transformation in §7 differs.

## 2. The URL

```plaintext
irealbook://Title=Composer=Style=Key=n=ChordString===Title2=...===PlaylistName
```

- Songs are separated by `===`. A trailing `===Name` after the last song names
  the playlist, and is *not* a song. It is told apart by having no `=` fields of
  its own.
- Within a song, fields are separated by `=`, and runs of `=` are collapsed
  before reading: exports write empty fields, and where the blanks land is not
  stable between eras of the app. A modern export reads
  `Title=Composer==Style=Key==Chords==0=0` and an old one
  `Title=Composer=Style=Key=n=Chords`, which collapse to the same five leading
  fields: title, composer, style, key, chord string. An old export puts the
  marker `n`, and some exports a transposition value, in the slot between key
  and chord string; the chord string is told apart from those by carrying the
  `1r34LbKcu7` header when scrambled (§7) and by being neither `n` nor a number.
- Anything after the chord string is trailing metadata — the style again, a
  tempo, and a repeat count. It is read when present and ignored when not, because
  exports disagree about how much of it they write. iReal's own tempo is `0`
  ("none set") on most charts, so when the URL carries no usable tempo the
  **style implies one** (`IRealStyleTempo`: ballad 72, up tempo 200, bossa 132,
  waltz 132, blues 100…; unknown styles claim nothing and the model's default
  stands) — the same job iReal's own player does with the style field.
- The style also implies the **band** (`IRealStyleRhythm`): bossa and samba
  styles arrange for the latin trio, the straight-eighth styles (even 8ths,
  fusion, funk, pop…) for the straight-eighths trio, and everything else keeps
  the swing band. An explicit rhythm chosen by the caller wins, and waltz
  styles claim nothing — a chart in three reaches the waltz vocabulary through
  its meter, not through its style name.
- The whole URL is percent-encoded.

**Composer names are stored surname first**: `Dorham Kenny`. Two words are
swapped to `Kenny Dorham`; one word, or three or more, is left alone, because
"Ellington" and "Ray Noble Trio" are both already right.

## 3. The chord string, as tokens

Read left to right. Every token is one of:

| Token | Meaning |
| --- | --- |
| ` | ` | bar line |
| `LZ` | bar line, as ` | ` — real exports write it between space-separated chords |
| `[` / `]` | opening / closing double barline — also a section boundary |
| `{` / `}` | repeat barlines, ` | :` and `: | ` |
| `*A` … `*D` | section marker; `*i` intro, `*v` verse — the only letters iReal writes |
| `N1` … `N9` | numbered ending, starting at the current bar |
| `S` | segno |
| `Q` | the **first** `Q` in a chart is *To Coda*; the **second** is the Coda |
| `T44`, `T34`, `T68`, … | time signature, two digits |
| `Z` | final double barline |
| `U` | end of the chart |
| `x` | repeat the previous bar |
| `Kcl` | a bar line whose bar repeats the previous bar — `x` with a bar line in front of it |
| `r` | repeat the previous two bars |
| `p` | hold the previous chord for another beat |
| `s` / `l` | draw the next chords small / large |
| `f` | fermata on the chord just written |
| `n` | no chord — `N.C.` |
| `W` | whole-note rest, taking a chord's share of the bar — `W/D` is that rest over bass D. Both import as `N.C.`; the bass is kept on the silent symbol |
| `,` and space | separators, carrying no meaning |
| `Y` | vertical spacing, carrying no meaning |
| `XyQ` | filler, carrying no meaning — real exports write it touching the chord ahead of it, so a reader must stop the chord there (`CXyQ` is `C` plus filler, not C double sharp) |
| `<text>` | an annotation on the current bar |
| `(chord)` | an alternate chord, shown small — kept as an annotation |
| `*quality*` | a quality iReal's menus cannot spell, star-wrapped after the root — `C*-^*` is C with quality `-^`. The stars are stripped and the inside parsed |
| anything else | a chord symbol |

## 4. Chords

A chord is a root, a quality and optionally `/bass`. iReal's quality shorthand is
already in Bandstand's alias table (`docs/format/chord-types.md`): `^` is a major
seventh, `-` is minor, `h` is half-diminished, `o` is diminished, `+` is
augmented, `sus` and `alt` are themselves, and `2` is sus2. The rarer official
qualities compose from the same table — `7susadd3` is `7` + `sus` + `add3`,
`-^9` is an alias of the minor-major ninth. So a chord token is handed to the
ordinary parser, and a token that will not parse is **reported, not guessed at**
— an import that quietly turns `C^9#11` into `C` is worse than one that says it
could not read bar 12.

## 5. Bars and beats

A chart is a sequence of bars, and every bar holds one to four chords.
iReal does not record *where* in the bar a chord falls; it records how many
chords share it. So:

- one chord fills the bar, at beat 0;
- two chords split it in half;
- three chords land on beats 0, 1 and 2 of a 4/4 bar — which is what iReal draws;
- four chords take a beat each.

`p` (hold) extends the previous chord instead of adding a new one, so `C p p p`
is one chord filling the bar, and `C p Dm p` is two chords of two beats.

## 6. Structure

- `{` opens a repeat, `}` closes one. A `}` with no `{` repeats from the top,
  which is what the notation means (`docs/rules/form-navigation.md` §4).
- `N1`, `N2` open numbered endings. An ending runs to the next ending, the
  closing repeat, or the end of the chart — and that span is recorded, because
  the traversal needs it (`docs/rules/form-navigation.md` §3.1).
- `*A` starts a section named `A`. Two sections with the same letter get the
  second one suffixed (`A2`), because a lead sheet requires unique names and a
  chart that reuses a letter means the *same* section — which the arrangement
  layer expresses by listing it twice, not by naming it twice.
- The time signature applies from its bar onwards, and is attached to the
  section that starts there, creating one if none has.

## 7. The `irealb://` scrambling

`irealb://` carries the same text with the chord string scrambled. The
algorithm below is written out from two public implementations — `pyRealParser`
(drs251) and `ireal-reader` (pianosnake) — which agree character for character
and both credit ironss' `irealb_parser.lua` for working it out.

A scrambled chord string begins with the ten-character header `1r34LbKcu7`,
which is **not** scrambled. Everything after the header is scrambled in
fifty-character segments, each segment on its own:

- the first five characters of a segment swap with the last five, mirrorwise —
  position 0 with 49, 1 with 48, through 4 with 45;
- characters at positions 10 to 23 swap with their mirrors at positions 39 down
  to 26;
- the characters in between — positions 5 to 9, 24, 25, and 40 to 44 — are left
  alone.

The chart's last segment is shorter than fifty characters and is left alone, as
is the last *full* segment when one or zero characters follow it. A segment is
only scrambled when at least two characters come after it.

The swap is its own inverse, so unscrambling is the same operation: drop the
header, then swap each segment. The header is also how a scrambled chord string
is recognised in the first place (§2).

Verified against the Jazz 1460 forum export: all 1460 charts carry the header
and unscramble to valid chord strings, and `26-2` unscrambles to Coltrane's
rhythm changes in F — `F^7 Ab7 | Db^7 E7 | A^7 C7 | C-7 F7 | …` — with the
sections and meter as published.
