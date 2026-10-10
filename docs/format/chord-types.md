# `chord_types.json`

The chord-type database of §4.1: **data, not code**. Lives at
`app/assets/chord_types.json` (ADR 0006), read by
`ChordTypeDatabase.fromJson`, and described in prose by
`docs/rules/chord-symbols.md`.

## Top level

```json
{
  "schemaVersion": 1,
  "cores": [ ... ],
  "modifiers": [ ... ]
}
```

`schemaVersion` must match the constant `chordTypesSchemaVersion` in
`chord_type_database.dart`. A mismatch is a load failure, not a warning: a build
that half-understands the chord table would misread charts silently.

## `cores`

A complete chord with an explicit degree list.

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | Human label. Documentation only — the *canonical symbol* is `aliases[0]`. |
| `aliases` | string[] | Every way the quality is written. **The first is canonical**: it is what `format()` emits. Must be non-empty and globally unique across all cores. |
| `family` | string | One of `major`, `minor`, `dominant`, `diminished`, `augmented`, `sus`, `other`. |
| `degrees` | string[] | The chord's degrees (see below). |

Exactly one core carries the empty alias `""`. That is the major triad, and it
is what a bare `C` means; the loader fails without it.

## `modifiers`

An operation on a degree set.

| Field | Type | Meaning |
| --- | --- | --- |
| `symbol` | string | Human label; `aliases[0]` is canonical. |
| `aliases` | string[] | Every way it is written. Globally unique across all modifiers. |
| `order` | integer | Sort key for canonical formatting: fifths (10), a raised seventh (15), ninths (20), elevenths (30), thirteenths (40), added notes (45–50), suspensions (60), omissions (70), `alt` (80). |
| `set` | string[]? | Degrees to ensure are present. Each displaces any existing degree with the same degree index **or** the same semitone count. |
| `remove` | integer[]? | Degree *indices* (1–7) to drop. `3` removes a third of any quality. |
| `degrees` | string[]? | Replaces the whole set. Only `alt` uses it. |
| `family` | string? | Forces the family — `sus4` and `sus2` make a chord `sus`. |

## Degree strings

`<accidentals><number>`, where accidentals are a run of `b` or `#` (never mixed,
at most two), and the number is 1–13.

- `1`, `3`, `5`, `7` — the plain degrees.
- `b3`, `b5`, `#5`, `b7`, `bb7` — altered.
- `9`, `11`, `13` — written as extensions; the same notes as `2`, `4`, `6` and
  compare equal to them, but print differently.
- `b9`, `#9`, `#11`, `b13` — altered extensions.

A degree is spelled as if the root were C, so the letter is unambiguous: `b3` is
an E flattened and `#9` is a D sharpened, and a voicing engine can tell them
apart even though both are three semitones.

## Invariants the loader enforces

1. `schemaVersion` is understood.
2. Every entry has at least one alias.
3. No alias is claimed by two cores, or by two modifiers. (A string may be both
   a core alias and a modifier alias — they are matched in different positions.)
4. Every degree string parses.
5. Exactly one core has the empty alias.

Violating any of these throws `FormatException` at load, which happens at app
startup — long before a chart is opened.
