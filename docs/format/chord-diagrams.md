# `chord_diagrams.json`

The fretboard shapes of `docs/rules/chord-diagrams.md`. Lives at
`app/assets/chord_diagrams.json` (ADR 0006), read by `ChordDiagramLibrary`.

## Top level

```json
{
  "schemaVersion": 1,
  "instruments": [
    {
      "id": "guitar",
      "displayName": "Guitar",
      "tuning": [40, 45, 50, 55, 59, 64],
      "shapes": [ ... ]
    }
  ]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | `guitar`, `ukulele`, `bass`. Unique. |
| `displayName` | string | What the picker calls it. |
| `tuning` | int[] | MIDI pitch of each open string, **low string first**. Its length is the string count. |
| `shapes` | array | The shapes. At least one. |

## `shapes`

```json
{
  "type": "maj7",
  "root": "C",
  "baseFret": 1,
  "frets": [-1, 3, 2, 0, 0, 0],
  "rootString": 1,
  "barre": null
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | string | The canonical chord-type symbol, as `chord_types.json` writes it. `""` is a plain major triad. |
| `root` | string | The root this shape is *for*, or absent for a movable shape. A shape with an open string must name its root (`chord-diagrams.md` §3). |
| `baseFret` | int | The fret the diagram's first row is. 1 or more. |
| `frets` | int[] | One per string, low first: `-1` muted, `0` open, `n` the fret counting from `baseFret`. Length must equal the tuning's. |
| `rootString` | int | Which string carries the root, zero-based from the low string. **Required on a movable shape**: sliding one means putting its root under the right fret, and which string that is differs by shape — an E-shape barre is rooted on the sixth string, an A-shape on the fifth. Inferring it from the lowest played string is wrong for every rootless or inverted shape. |
| `barre` | object \| null | `{"fret": 1, "fromString": 0, "toString": 5}` — the fret, and the string range it covers, low first and inclusive. |

## Invariants the loader enforces

1. `schemaVersion` is understood.
2. Every instrument has an id, unique in the file, and a tuning of 1–12 strings.
3. Every shape's `frets` has one entry per string.
4. Every fret is `-1`, `0`, or 1 to 24.
5. `baseFret` is 1 to 20.
6. A `barre` names a fret inside the diagram and a string range inside the
   instrument, low string first.
7. A shape with an open string names a `root`, because it cannot be moved; a
   shape with no `root` names a `rootString`, because it must be.
8. `rootString` names a string of the instrument, and one that is not muted.
9. `type` parses as a chord type.

## Invariants the *tests* enforce

Properties of the data, better caught by a failing test than by a wrong diagram
on a stand:

1. **Every shape sounds the chord it claims.** The pitch each stopped or open
   string produces is computed from the tuning, and the set of pitch classes
   must contain every chord tone of `type` and nothing outside it. This is the
   one that catches a typo in a fret number, and it is the reason the format
   stores a tuning rather than assuming one.
2. **Every shape is playable.** No more than four fretted strings outside a
   barre, and no span wider than four frets — a hand is a hand.
3. **A movable shape has no open strings**, per §3.
4. **Coverage**: every chord type the shipped `chord_types.json` calls common
   has a shape for guitar, and the twelve roots each resolve to one.
