# Comping

Written per §1 / §15, for §6.5 item 3: *"Piano/guitar comping — rhythmic pattern
corpus × voicing engine. Split these two concerns: **when** to play (corpus of
rhythmic cells) and **what notes** (voicing engine below)."*

This document is the *when*. The *what* is `docs/rules/voicings.md`, and the
split is load-bearing: a comping part that plays the right chords at the wrong
moments is unusable, and the two failure modes have nothing to do with each
other. Keeping them apart means each can be judged, tested and tuned alone.

## 1. What a rhythmic cell is

One or two bars of **onsets**, each with a duration and an accent, and nothing
about pitch. A cell says "hit on the and-of-two, hold it across the bar line";
it does not say what to hit.

Stored per cell:

- the onsets: position in beats, length in beats, accent (0..1);
- the meter it was written for (§4.6: meter coverage is a corpus decision);
- an **intensity band**, the range of §6.6 intensities it suits;
- a **density**, derived: onsets per bar, which is what the arranger's density
  arc (§6.6) actually selects on;
- style tags — `charleston`, `sparse`, `pushed`, `on-the-beat`, `montuno`.

Cells are data, not code (§15), and live beside the drum patterns in
`app/assets/comping_cells.json`.

## 2. Why a corpus rather than rules

The same reasoning as §6.3, one level down. The characteristic sound of jazz
comping is *syncopation that is not random* — the Charleston figure, the push
into the bar, the held chord that lets the bass walk through. Those are learned
figures. A rule that says "play on beats 2 and 4 with 30% probability of an
eighth-note anticipation" produces something that is technically syncopated and
audibly generated.

A small corpus of real figures, selected rather than sampled, does not.

## 3. Placement

A cell is placed against the **chord spans**, not against the bar grid, because
the harmony is what a comper is responding to.

1. Walk the part a cell-length at a time.
2. Collect the cells whose meter matches, whose intensity band contains the
   part's intensity, and which fit in the bars remaining.
3. Reject any whose onsets would fall in a bar with no chord at all.
4. Choose by the same freshness rule as the drums and the bass tiler
   (`corpus-tiling.md` §6): freshness **gates**, score **ranks**. A comper who
   plays the same two-bar figure eight times is the loop sound the whole design
   is against.

## 4. Anticipation

§6.6 asks for it explicitly: *"push chords an eighth before the bar when the
source phrase supports it."*

A chord change anticipated by an eighth is the single most characteristic thing
a comper does. The rule:

- A cell onset within an eighth **before** a chord change takes the *new*
  chord, not the old one.
- The onset that would otherwise land **on** that change is then suppressed —
  playing both is the sound of a mistake, not of a push.
- Anticipation is off across a **section boundary**, where the form's own
  weight wants the downbeat.

The chord model already carries an `anticipation` on its rendering info, which
the post-processing stage of M5 applies. Comping honours it rather than
inventing its own.

## 5. Voicing continuity

Every onset asks the voicing engine for notes, and the engine leads from the
previous voicing (`voicings.md` §5). Two consequences worth stating:

- **Repeated onsets on one chord re-strike the same voicing.** A comper does not
  re-voice a chord they are holding; they hit it again. Only a chord *change*
  asks for a new voicing.
- **The lead-from voicing persists across a rest.** A bar of silence does not
  reset the voice leading — the next chord still leads from the last thing
  actually played, which is what a player's hands do.

## 6. Density across the form

§6.6's density arc, applied here:

- Intensity selects the cell's band, so a quiet head gets sparse figures and a
  last chorus gets busy ones. It is a *filter*, not a volume knob — a busy
  figure played quietly is still busy, and that is not what "quieter" means.
- The **first bar of a section** biases towards a cell that states the downbeat,
  so the form is audible.
- The **last bar before a section** biases towards one that leaves space, so the
  next section has somewhere to arrive.

## 7. What a comper must not do

Constraints, checked rather than hoped for:

1. **Never on every beat.** A cell whose onsets fall on all of 1, 2, 3 and 4 of
   a 4/4 bar is a metronome with chords on it. Excluded from the corpus, and
   the corpus test asserts it.
2. **Never two onsets closer than a sixteenth.** That is a flam, not a comp.
3. **Never sounding the old chord through a change.** A held voicing that
   spans a change states the wrong harmony for half its length.

   The exception is not an exception: a note starting within an eighth *before*
   the change is an **anticipation** (§4), and it takes the new chord, so it
   states the right harmony throughout. What is forbidden is a note that starts
   earlier than that and sustains across — it began as the old chord and stays
   the old chord.

   A cell tagged `pedal` is exempt entirely, which is what the tag is for.
4. **Never longer than the part.** A two-bar cell does not start in the last
   bar — the same rule, and the same bug, as the two-bar drum groove that
   stepped over a fill.

## 8. What this deliberately does not do

- **Listen to the soloist.** There is no soloist to listen to.
- **Trade fours, or comp behind a specific instrument differently.**
- **Guitar-idiomatic rhythm.** A guitar comps differently from a piano — Freddie
  Green quarter notes are a different corpus, not a parameter — and until that
  corpus exists a guitar voice should use the piano cells and the shell
  voicings of `voicings.md` §3.2.
