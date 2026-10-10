# `scales.json`

The standard-scale table of §4.1. Lives at `app/assets/scales.json` (ADR 0006),
read by `ScaleLibrary.fromJson`.

## Top level

```json
{
  "schemaVersion": 1,
  "scales": [ ... ]
}
```

## `scales`

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | Human label; `aliases[0]` is what the app displays. |
| `aliases` | string[] | Every name the scale goes by. Matched case-insensitively, and unique across the whole file. |
| `degrees` | string[] | The scale's degrees, ascending, starting at `1`. Same syntax as `chord_types.json`. |
| `preferredFor` | string[] | Canonical chord-type symbols a player would normally reach for this scale over. |

`preferredFor` is a **hint**, used to order the scales offered for a chord. It is
not what decides whether a scale *fits*: `StandardScale.fits` answers that
structurally, by checking that every chord tone is in the scale. A scale missing
from a chord's `preferredFor` list still appears if it fits, just lower down.

## Invariants the loader enforces

1. `schemaVersion` is understood.
2. Every scale has a name, at least one alias and at least one degree.
3. No alias is claimed twice, case-insensitively.
4. Every degree string parses.

`scale_test.dart` additionally asserts that every scale starts on `1`, ascends,
and has no duplicate pitch classes — properties of the *data* rather than of the
loader, and better caught by a failing test than by a silent oddity in the
improvisation display.
