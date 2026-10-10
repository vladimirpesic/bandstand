# Form navigation: repeats, endings, and the jumps

Written per §1 / §15, and per §4.5, which says not to skip this. Implemented by
`app/lib/domain/song/navigation.dart`.

Charts are not linear. The lead sheet stores the *written page*; playback needs a
*linear bar sequence*. Getting the expansion wrong is the single most common
cause of "the backing track went to the wrong bar", and it is wrong on most
tunes, because most tunes repeat.

## 1. What the lead sheet stores

Navigation is expressed as items attached to bars, alongside chord symbols and
section markers:

| Item | Attached to | Carries |
| --- | --- | --- |
| Repeat start | a bar | — |
| Repeat end | a bar | how many times the span is played in total (default 2) |
| Ending (volta) | a bar | which pass numbers it is played on, e.g. `{1}` or `{1,3}`, and **how many bars the bracket covers** |
| Segno | a bar | — |
| Coda | a bar | — |
| To Coda | a bar | — |
| Fine | a bar | — |
| Da Capo | a bar | plain, *al Fine*, or *al Coda* |
| Dal Segno | a bar | plain, *al Fine*, or *al Coda* |

A repeat start is *at the head of* its bar; a repeat end, To Coda, Fine, Da Capo
and Dal Segno are *at the tail of* theirs. Segno and Coda are at the head. This
matters: `|: A B :|` plays A B A B, and the jump happens after B, not before it.

## 2. What the expansion produces

`resolveNavigation(leadSheet)` returns a **flattened bar list**: for each bar of
playback, the index of the bar on the written page it came from.

```plaintext
written:   0  1  2  3          with |: 0..1 :| and bars 2,3 after
flattened: 0  1  0  1  2  3
map:       [0, 1, 0, 1, 2, 3]
```

Everything downstream — the chord sequence the generators see, the cursor that
highlights the written page during playback — reads that map. Without it the
cursor is wrong on any tune with repeats (§4.5).

## 3. The traversal

One pass, bar by bar, with a small amount of state:

- `bar` — where we are on the written page.
- `passOf[repeatEndBar]` — how many times each repeat end has been reached.
- `jumped` — whether a Da Capo or Dal Segno has been taken.
- `target` — `none`, `fine` or `coda`, set by the jump that was taken.
- `emitted` — the flattened list being built.

At each bar:

1. **Ending filter.** Endings are collected into **groups**: a run of endings
   whose lowest pass numbers climb. A new group starts as soon as an ending's
   lowest pass number does not exceed the previous one's — which is exactly what
   a second, unrelated repeat later in the chart looks like.

   Each group carries a pass counter, incremented whenever the traversal
   *arrives at the group's first bar*. Arriving is the right trigger, not
   playing: on the second pass the traversal reaches the first bracket, finds it
   is not for this pass, and jumps to the one that is.

   If no bracket in the group is played on the current pass, the traversal
   leaves the group entirely, landing on the bar after its last bracket. That
   is why an ending carries an explicit **bar count**: a two-bar bracket is
   ordinary, and the bar after the group cannot be guessed from the start bars
   alone.

   This is what makes `|: A {1} B :| {2} C |` play A B A C.

   A Da Capo or Dal Segno clears every group's counter, so the pass after a
   jump takes the first bracket again — which is what a band does.
2. **Emit** the bar.
3. **Decide the next bar**, in this order — the order is the whole specification,
   and the reason it is written down:
   1. If the bar carries **Fine** and `target == fine`, stop.
   2. If the bar carries **To Coda** and `target == coda`, jump to the Coda bar.
   3. If the bar carries **Da Capo** and it has not been taken, jump to bar 0,
      set `jumped`, and set `target` from the mark (`alFine`, `alCoda`, or
      `none`).
   4. If the bar carries **Dal Segno** and it has not been taken, jump to the
      Segno bar, likewise.
   5. If the bar carries a **repeat end** whose play count has not been reached,
      increment its counter and jump back to the matching repeat start — the
      nearest repeat start at or before this bar, or bar 0 if there is none.
   6. Otherwise, go to the next bar. If that is past the end, stop.

**After a Da Capo or Dal Segno, repeats are not taken again.** This is the
convention every published chart assumes, and it is why rule 3.5 is checked only
when `!jumped`. A chart that genuinely wants the repeat on the second pass
writes it out.

## 4. Guards

Real charts contain contradictions, and a chart that hangs the app on stage is
worse than one that plays something slightly wrong.

- **Bar cap.** The expansion stops at `maxFlattenedBars` (4096 — about two hours
  at any sane tempo) and reports the truncation. An unresolvable structure is
  reported at *import*, per §4.5, but the guard exists because import is not the
  only way a lead sheet gets built.
- **Missing targets.** A Dal Segno with no Segno, or a To Coda with no Coda, is
  a defect in the chart. The traversal ignores the mark and records a
  `NavigationProblem` rather than jumping to bar 0 and quietly playing the wrong
  form.
- **A repeat end before any repeat start** repeats from bar 0, which is what the
  notation means.
- **Zero or negative repeat counts** are treated as 1: play it once, go on.

Every problem the traversal finds is returned alongside the map, so the editor
can show them and the importer can refuse the file. Nothing is thrown: a chart
with a broken repeat still opens, still displays, and still plays *something*.

## 5. Pickup bars

A pickup (anacrusis) is bar 0 with a `pickupBeats` value on the lead sheet: the
bar is short, and playback starts partway through it. It is emitted like any
other bar; the transport applies the offset. A repeat that jumps back to bar 0
lands at the *start of the full bar*, not at the pickup — which is what a band
does, and the reason `pickupBeats` lives on the lead sheet rather than on bar 0
as an item.

## 6. What this deliberately does not do

- **Nested repeats.** `|: A |: B :| C :|` is rare, ambiguous in practice, and
  every implementation disagrees about it. A repeat start closes any open one.
- **D.C. al Coda with two codas.** One Coda mark per chart.
- **Multi-bar rests** as a navigation concept; they are a rendering concern
  (§8.1).
