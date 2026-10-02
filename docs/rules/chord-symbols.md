# Chord symbols: the type database, the grammar, and formatting

Written per §1 / §15. Implemented by `app/lib/domain/harmony/chord_type*.dart`
and `chord_parser.dart`, with the data in `app/assets/chord_types.json`.

§4.1 requires two things of this layer: the chord-type database is **data, not
code**, and parsing uses **a grammar, not regexes stacked on regexes**.

## 1. Why a grammar and not a lookup table alone

The set of chord symbols in real charts is not finite in any useful sense.
`13b9#11`, `maj7#5`, `m11b5`, `7sus4b9`, `6/9`, `7alt` — enumerating every
combination is thousands of entries, and the thousand-and-first appears in the
next iReal file you import.

So the database holds two kinds of entry, and the grammar composes them:

- **Core types** — a complete chord with an explicit degree list and a set of
  aliases. About seventy of them, covering everything a chart writes as a single
  token: triads, sixths, sevenths, ninths, elevenths, thirteenths, and the
  common alterations that have their own names (`m7b5`, `o7`, `7sus4`).
- **Modifiers** — an operation on a degree set, with aliases. `b9`, `#11`,
  `sus4`, `no5`, `alt`, `add9`.

`C13b9#11` is then the core `13` with the modifiers `b9` and `#11` applied, and
the parser needs no entry for it.

## 2. Degree-set operations

A modifier does one of three things, expressed as data:

- **`set`** — ensure these degrees are present. *Any existing degree with the
  same number is removed first.* So `b9` applied to `1 3 5 b7 9 13` gives
  `1 3 5 b7 b9 13` — it replaces the ninth rather than sitting beside it, which
  is what a musician means by `13b9`.
- **`remove`** — drop every degree with these numbers. `no5`, and the first half
  of `sus4`.
- **`degrees`** — replace the whole set. Only `alt` uses this: `7alt` is
  `1 3 b7 b9 #9 #11 b13`, and it is not usefully derived from `7`.

`sus4` is `remove: [3], set: ["4"]`; `sus2` is `remove: [3], set: ["2"]`.

## 3. The grammar

```plaintext
chord       := root quality ( '/' root )?
root        := [A-Ga-g] accidental*
accidental  := 'b' | '#'
quality     := coreAlias? modifier*
modifier    := modifierAlias | '(' modifier+ ')' | separator
separator   := ' ' | ',' | '(' | ')'
```

Parsed left to right, **longest alias first** at every step:

1. **Root.** One letter, then any run of `b`/`#`. `Cb`, `F##`, `A`. Lower-case
   letters are accepted — text charts use them — and normalised to upper.
2. **Core type.** Longest matching core alias at the cursor. If nothing matches,
   the core is the major triad, whose canonical alias is the empty string. That
   single rule is what makes `C` parse.
3. **Modifiers.** Repeatedly take the longest matching modifier alias.
   Parentheses, spaces and commas are skipped wherever they appear, so
   `C7(b9,#11)` and `C7b9#11` parse identically.
4. **Bass.** After `/`, a root. `C/E`, `Dm7/G`. The bass is a spelling, not a
   chord; `C/E` means a C major triad over an E in the bass.

Anything left over is an error. The parser never guesses: `Cwobble` fails
loudly, because a silently mis-parsed chord is worse on stage than a red
squiggle in the editor.

**`N.C.`** — aliases `N.C.`, `NC`, `n.c.` — is not a chord and does not go
through this grammar. It parses to the canonical no-chord symbol (§6).

## 4. Longest-alias matching, and why it matters

Aliases are indexed by length, longest first, so `m7b5` wins over `m7` and
`maj7` wins over `maj`. Without that, `Cm7b5` parses as `Cm7` followed by the
unknown text `b5`, or worse, as `Cm7` plus a `b5` modifier that happens to give
the right degrees but the wrong canonical name.

The alias tables are checked at load: a duplicate alias across two entries is a
fatal error in the data file, not a silent last-one-wins.

## 5. Families

Every core type declares a family: `major`, `minor`, `dominant`, `diminished`,
`augmented`, `sus`, `other`. `sus4` and `sus2` override the family to `sus`.

`isMinorish` is *not* the family test. It asks whether the chord contains a
minor third — a degree three semitones from the root, spelled as a third. It is
true for `m7`, `m7b5`, `o7` and `mMaj7`; false for `7#9`, whose `#9` is the same
three semitones spelled as a ninth. Generators use it to decide whether to
treat a chord as minor; voicing engines use the spelling.

## 6. Formatting, and `parse(format(x)) == x`

`format` writes the root spelling, then the type's canonical name, then `/` and
the bass spelling if there is one.

The canonical name comes from one of two places:

1. If the finished degree set matches a core type exactly, that core's canonical
   alias. `7` plus the modifier `b5` gives the degrees of the core `7b5`, so it
   formats as `C7b5`, not `C7b5` built from parts that happen to agree.
2. Otherwise the core's canonical alias followed by the applied modifiers'
   canonical symbols, in the order declared by each modifier's `order` field —
   alterations of the fifth, then ninth, then eleventh, then thirteenth, then
   suspensions and omissions.

The canonical alias of an entry is the **first** alias in its list. That is the
only reason the order of aliases in the JSON matters, and the file says so.

The round trip is then exact by construction, and `chord_symbol_test.dart`
asserts it over every core type in every one of the twelve roots in both
accidental directions, plus every core type with every applicable modifier.

## 7. What the database deliberately does not contain

- **Polychords** (`C/D` meaning a D bass under a C triad is a slash chord; `C|D`
  meaning two stacked triads is not modelled). Real charts use slash notation
  and mean the bass.
- **Inversions as figures** (`C6/3`). Charts write slash chords.
- **Microtonal or non-twelve-tone anything.**
