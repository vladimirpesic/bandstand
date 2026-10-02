# Chord diagrams

Written per §1 / §15, for §9's *"Guitar/uke/piano chord diagrams — build in M8.
Pure data + a small painter. Nice, self-contained, low risk."*

Low risk because nothing else depends on it: a diagram is drawn from a chord
symbol the harmony core already parsed, and nothing reads back.

## 1. What a shape is

For a fretted instrument, a shape is a **fret per string**, low string first,
plus where the diagram starts:

- `0` — the open string.
- `-1` — a string that is not played, drawn with a cross above the nut.
- `n` — the fret, counting from the diagram's first fret rather than from the
  nut, so a shape high on the neck does not need a twelve-fret diagram.

Stored with it: the **base fret** the diagram starts at, and the **barre**, if
there is one, as the fret and the range of strings it covers. A barre is drawn
rather than derived: three fingers at the same fret is not a barre, and only the
person who worked the shape out knows which it was.

Nothing about fingering. A fingering is a teaching decision that depends on
what comes next, and a chart is not a lesson.

## 2. What a shape is *for*

A diagram answers *"how do I play this chord"*, and it answers it for the chord
**as written**, including its bass note. `C/G` is not `C`: a guitarist plays a
different shape, and showing the `C` shape for it is worse than showing nothing,
because it is confidently wrong.

So a shape is stored against the **chord type** and looked up by it, and a slash
chord looks up its own entry or reports that it has none.

## 3. Transposition

Shapes are stored **once per chord type, at a root**, and moved.

- A shape with **no open strings** is movable: it is transposed by shifting the
  base fret, and the fingering does not change. `Fmaj7` at fret 1 is `Gmaj7` at
  fret 3.
- A shape **with open strings is not movable.** Shifting `Cmaj7`'s open shape up
  two frets gives something nobody plays. An open shape belongs to its root.

So the table holds an open shape per root where a good one exists, and one
movable shape per chord type for everything else. The lookup takes the open
shape when there is one and moves the shape otherwise.

A movable shape that would land **above the twelfth fret** is moved down an
octave instead: a guitarist plays `Bbmaj7` at fret 6, not fret 18.

## 4. Instruments

Three, and they differ only in their tuning and string count:

| Instrument | Strings | Tuning, low to high |
| --- | --- | --- |
| Guitar | 6 | E2 A2 D3 G3 B3 E4 |
| Ukulele | 4 | G4 C4 E4 A4 — re-entrant |
| Bass | 4 | E1 A1 D2 G2 |

The ukulele's G is **above** its C, which is what "re-entrant" means and which
matters here only in that the shapes were worked out on a real instrument and
are stored, not derived.

Piano is not a fretted instrument and gets a different drawing entirely: the
keys of one octave with the chord's notes filled in. It shares nothing with the
above but the screen it appears on.

## 5. Drawing

A `CustomPainter`, like the chart renderer (§8.1), and for the same reason: this
is a grid with dots on it, and no library is smaller than the code that draws
one.

- Six vertical lines, five horizontal, the nut heavier when the diagram starts
  at fret 1.
- A dot per stopped string, a circle above the nut per open string, a cross
  above the nut per muted string.
- The base fret printed beside the diagram when it is not 1.
- A barre as a rounded bar across its strings, drawn *under* the dots.

**Legible at arm's length, not at 2 m.** A diagram is something a player looks
down at while working a tune out, unlike the chart itself (§8.1), so it is
sized for reading rather than for the stand.

## 6. What this deliberately does not do

- **Every voicing of every chord.** One good shape beats six the player has to
  choose between mid-tune. A second shape per chord type is a later decision,
  and the format allows it without changing.
- **Fingerings**, per §1.
- **Left-handed diagrams.** A mirror flag on the painter, when someone asks.
- **Deriving shapes from the harmony core.** A search over playable fingerings
  is a genuinely hard problem and the results are worse than a table someone
  played. Prefer data over code (§15).
