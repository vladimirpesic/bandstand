# Reading iReal Pro charts

Written per §1 / §15. Implemented by `app/lib/io/importers/ireal_import.dart`.

§5.2 calls this "the highest-leverage feature in this entire plan": it is how a
library gets populated in an evening rather than a year.

## 1. The two URL schemes

| Scheme | Body | Status here |
| --- | --- | --- |
| `irealbook://` | plain text | **implemented** |
| `irealb://` | the same text, scrambled | **not implemented** — see §7 |

Both carry the same fields and the same chord grammar, so everything below
applies to either; only the one transformation in §7 differs.

## 2. The URL

```plaintext
irealbook://Title=Composer=Style=Key=n=ChordString===Title2=...===PlaylistName
```

- Songs are separated by `===`. A trailing `===Name` after the last song names
  the playlist, and is *not* a song. It is told apart by having no `=` fields of
  its own.
- Within a song, fields are separated by `=`. The first six are title,
  composer, style, key, an unused field (always `n`), and the chord string.
- Anything after the chord string is trailing metadata — style again, tempo,
  and a repeat count. It is read when present and ignored when not, because
  exports disagree about how much of it they write.
- The whole URL is percent-encoded.

**Composer names are stored surname first**: `Dorham Kenny`. Two words are
swapped to `Kenny Dorham`; one word, or three or more, is left alone, because
"Ellington" and "Ray Noble Trio" are both already right.

## 3. The chord string, as tokens

Read left to right. Every token is one of:

| Token | Meaning |
| --- | --- |
| ` | ` | bar line |
| `[` / `]` | opening / closing double barline — also a section boundary |
| `{` / `}` | repeat barlines, ` | :` and `: | ` |
| `*A` … `*Z` | section marker; `*i` intro, `*v` verse |
| `N1` … `N9` | numbered ending, starting at the current bar |
| `S` | segno |
| `Q` | the **first** `Q` in a chart is *To Coda*; the **second** is the Coda |
| `T44`, `T34`, `T68`, … | time signature, two digits |
| `Z` | final double barline |
| `U` | end of the chart |
| `x` | repeat the previous bar |
| `r` | repeat the previous two bars |
| `p` | hold the previous chord for another beat |
| `s` / `l` | draw the next chords small / large |
| `f` | fermata on the chord just written |
| `n` | no chord — `N.C.` |
| `,` and space | separators, carrying no meaning |
| `Y` | vertical spacing, carrying no meaning |
| `XyQ` | filler, carrying no meaning |
| `<text>` | an annotation on the current bar |
| `(chord)` | an alternate chord, shown small — kept as an annotation |
| anything else | a chord symbol |

## 4. Chords

A chord is a root, a quality and optionally `/bass`. iReal's quality shorthand is
already in Bandstand's alias table (`docs/format/chord-types.md`): `^` is a major
seventh, `-` is minor, `h` is half-diminished, `o` is diminished, `+` is
augmented, `sus` and `alt` are themselves. So a chord token is handed to the
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

## 7. What `irealb://` needs

`irealb://` carries the same text with a documented scrambling applied. §5.2
names four public implementations that contain the algorithm — `pyRealParser`,
`ireal-reader`, `Data-iRealPro` and the `ireal_parser` Rust crate — none of
which is in the local reference tree at `/home/vladimir/develop/refs/`.

It is **not implemented from memory**. An unscrambler that is subtly wrong does
not fail; it produces a chart that reads plausibly and is not the tune, and
`docs/rules/` exists precisely so that this project does not do that. The
importer detects the scheme and says so.

To finish it: obtain the algorithm from one of those implementations, write it
down here in prose as §1 requires, implement from the prose, and verify against
a real `irealb://` export whose chart is known.
