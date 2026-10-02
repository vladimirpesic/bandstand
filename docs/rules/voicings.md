# Voicings

Written per §1 / §15, for the voicing engine of §6.5 item 4.

The engine answers one question — *given this chord, and given what was just
played, which notes should the left hand put down?* — and it answers it purely:
same chord, same previous voicing, same result. §6.5 calls it "extremely
testable" and that is the point of keeping it apart from the comping rhythm
(`docs/rules/comping.md`), which answers *when* rather than *what*.

## 1. What a voicing is

An ordered list of MIDI pitches, low to high, plus the chord it was built for
and which family it came from. Nothing about time: a voicing is a shape, and
the rhythm corpus decides when it sounds.

The bass is a separate voice (M6) and it plays the root. That fact drives
everything below: a comping voicing does not need the root, and in most
families it must not have it, because doubling the bass an octave up is the
single most common way to make a small band sound muddy.

## 2. Guide tones

The **third** and the **seventh** are the guide tones. They are what tell a
listener the chord's quality: drop everything else from `Dm7` and `G7` and the
`F–C` against `F–B` still says ii-V.

Two properties make them the skeleton of the whole engine:

- **They resolve by step, and they swap roles.** Through `Dm7 | G7 | Cmaj7`:

  | | 3rd | 7th |
  | --- | --- | --- |
  | Dm7 | F | C |
  | G7 | B | F |
  | Cmaj7 | E | B |

  The third of one chord *becomes* the seventh of the next and is held; the
  seventh of one *falls a semitone* to the third of the next. F is held into
  G7 and C falls to B; B is held into Cmaj7 and F falls to E. Two voices, and
  between them they move one semitone per chord. A voicing built around them
  inherits that, which is exactly what §10's acceptance asks for.
- **A chord missing one is ambiguous.** So constraint 1 of §6 is that every
  voicing states both, wherever the chord has both.

## 3. The families

Five, in the order the engine prefers them for piano.

### 3.1 Rootless

The Bill Evans left hand, and the default for a piano in a band with a bass
player. Four notes, no root:

| Chord | The set |
| --- | --- |
| minor 7 | 3 5 7 9 |
| major 7 | 3 5 7 9 |
| half-diminished | 3 5 7 9 |
| dominant 7 | 3 13 7 9, **or** 3 5 7 9 |

**The dominant gets two sets, and it matters.** The thirteenth is the more
colourful and the one the textbooks lead with, but the fifth is equally
standard and is sometimes the only one that leads: from `Cmaj7` as `E G B D`
into `A7`, the set with the fifth holds E, G and B exactly where they are and
moves D down to C# — one semitone. The set with the thirteenth cannot get below
four, which breaks the movement cap of §6.7 on a plain I-VI turnaround.

**Inversion is a voice-leading question, not a family one.** The textbook names
two — *type A* with the third at the bottom, *type B* with the seventh — and
alternating them is the classic ii-V trick: `Dm7` as `C E F A` into `G7` as
`B E F A` moves one voice by one semitone, where playing both from the third
would move all four.

But two are not enough. The engine offers **three of the four rotations**, the
extra one starting on the fifth, because that is what the I-VI above needs and
neither named form can supply it. The rotation that puts the **ninth at the
bottom** is dropped: it lands the ninth a semitone under the third — `Dm7` as
`E F A C` — and that is the one place in a voicing where a second is a fault
rather than a colour.

The engine therefore never chooses an inversion for a chord in isolation. It
chooses whichever leads best from what came before (§5), and the textbook
alternation falls out of that rather than being imposed.

### 3.2 Shell

Root, third, seventh — three notes, the minimum that states the chord. Used
where a rootless voicing would be wrong: solo piano with no bass, a very low
register, or a chord the rootless table has no entry for.

### 3.3 Drop-2

Take a four-note close-position voicing and drop the second voice from the top
down an octave. Opens the sound out; the standard guitar and vibraphone shape,
and useful on piano when the line above is busy.

### 3.4 Quartal

Stacked fourths — the "So What" sound. Three or four voices a perfect fourth
apart, often with a major third on top. Modal rather than functional: it states
a *scale* more than a chord, so the engine offers it for static minor and
suspended harmony and not for a dominant that has to resolve.

### 3.5 Triad over bass

A plain triad, used for slash chords and for chords the other families cannot
express. The fallback, and it must sound deliberate rather than apologetic.

## 4. Register

Comping lives between **C3 (48) and C6 (84)**, and rootless voicings sit inside
a narrower band, roughly **F3 (53) to A5 (81)**. Below that the intervals turn
to mud; above it the voicing stops supporting a soloist and starts competing.

**Low interval limits** are a property of the ear, not of taste, and the engine
treats them as constraints (§6):

The standard table, as the lowest note of the interval:

| Interval | Lowest usable bottom note |
| --- | --- |
| minor 2nd | E3 (52) |
| major 2nd | Eb3 (51) |
| minor 3rd | C3 (48) |
| major 3rd | Bb2 (46) |
| tritone | Eb3 (51) |
| perfect 4th | F2 (41) |
| perfect 5th | Bb1 (34) |
| minor 6th | F2 (41) |
| major 6th | Eb2 (39) |

A voicing whose lowest interval falls below its limit is rejected before it is
scored. This is the rule that stops the engine putting a rootless `Dm7` down at
`F2` where the third and fifth beat against each other.

## 5. Voice leading

The engine holds the **previous voicing** and chooses the candidate that moves
least from it.

**Movement** is the sum of the semitone distances between the voices of the two
voicings, paired in order, low to high. Where the two have different voice
counts the extra voices at the top count their full distance from the nearest
voice below.

Three refinements, all of which matter audibly:

1. **The largest single move is capped, not just the total.** §10 asks for
   "voice movement under 4 semitones between successive chords", so a candidate
   where any one voice moves 4 or more is rejected outright rather than scored
   low. A voicing whose total movement is small because three voices held still
   while the fourth leapt a fifth is not good voice leading; it is three good
   voices and a mistake.
2. **A common tone held is better than a common tone re-struck an octave away.**
   Where two candidates move the same total distance, the one with more voices
   *unchanged* wins.
3. **Direction is shared.** Where voices must move, moving them the same way
   reads as one gesture; contrary motion inside a four-note left hand reads as
   two. This breaks remaining ties.

### 5.1 Where the hand starts

The first voicing of a tune has nothing to lead from, and choosing it for
register alone is not good enough. Where a hand starts decides everything after
it: seeded on register, `Gm7 | C7 | Fmaj7` picks `D F A Bb`, and from there *no*
`C7` voicing moves less than four semitones — over the cap of §6.7, on an
ordinary ii-V-I in F.

So a whole sequence is voiced by trying **every candidate for its first chord as
a seed**, chaining the rest greedily from each, and keeping the best chain.
A chain is judged in this order: nothing relaxed, then the smallest largest-move,
then the least total movement, then register. Register comes last and small — it
exists to settle seeds an octave apart, which produce chains that are otherwise
identical, and without it the tune sits wherever the search happened to land.

This is bounded and cheap: a few dozen seeds times the length of the sequence,
with no search after the seed. Greedy from a good start is not optimal, and
where it falls short the relaxation is reported rather than hidden (§7).

## 6. Constraints

Applied before scoring; a candidate failing any of them is discarded, not
ranked low.

1. **Both guide tones present**, where the chord has them. A voicing that omits
   the third of a minor chord has not said the chord.
2. **No root**, in the rootless families. The bass has it, and doubling it is
   the mud described in §1.
3. **No doubled pitch class.** Four voices, four different notes. Doubling
   inside a four-note voicing wastes a voice that could have carried a colour.
4. **No minor ninth between any two voices** — thirteen semitones — *except*
   above the root of a dominant chord, where it is the point of a `7b9`. In a
   rootless voicing there is no root, so the exception never applies and the
   rule is absolute.
5. **No minor second between adjacent voices** whose lower note is below E3
   (52) — the same limit as §4, stated separately because it is the one that
   bites most often. Note that a second here is not an accident to be designed
   out: the dominant type-A voicing is `3 13 7 9`, which puts the 13th and the
   7th a semitone apart (`G7` as `B E F A`), and that rub is the sound. The
   rule is about where it sits, not whether it may exist.
6. **Every note inside the register band** of §4, and every interval above its
   low limit.
7. **Every voice moves less than 4 semitones** from the previous voicing (§5.1),
   where there is one.

Constraints 4 and 5 are what §10 means by "no interval clashes"; 3 is "no root
doubling"; 7 is "voice movement under 4 semitones".

## 7. Choosing

1. Build every candidate the families offer for this chord, at every octave that
   keeps it in the band.
2. Discard those failing §6.
3. Score the rest: voice leading (§5) at weight 3, register centredness at
   weight 1, and family preference at weight 0.5 — rootless first for a band,
   shell where there is no bass.
4. Take the highest. Ties break by the rules in §5.

**When nothing survives.** Relax in a fixed order, so the failure is
predictable rather than a surprise: first drop the movement cap (§6.7), then
allow a shell, then allow the root. Record which relaxation was used, because a
chord that repeatedly needs the third one is a gap in the family tables and
should be visible as such rather than silently papered over — the same
discipline as the tiler's gaps in `corpus-tiling.md` §11.

## 8. What this deliberately does not do

- **Melody avoidance.** The engine does not know what a soloist is playing.
- **Left-hand/right-hand split.** One voicing, one hand's worth.
- **Voicings above the staff for a solo intro**, block chords, locked hands.
- **Guitar-specific shapes.** A guitar cannot play every four-note voicing a
  piano can; fingering is a constraint this engine does not model, and a guitar
  voice should use the shell and drop-2 families until it does.
