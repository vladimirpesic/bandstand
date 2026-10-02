import 'dart:math';

import '../harmony/chord_rendering_info.dart';
import '../phrase/note_event.dart';
import '../phrase/phrase.dart';
import 'generation_context.dart';

/// The lowest and highest note a voice will play.
class PitchRange {
  /// Create a range.
  const PitchRange(this.lowest, this.highest);

  /// A double bass.
  static const PitchRange doubleBass = PitchRange(28, 55);

  /// A piano.
  static const PitchRange piano = PitchRange(21, 108);

  /// A guitar, sounding.
  static const PitchRange guitar = PitchRange(40, 88);

  /// The whole MIDI range, for a voice with no opinion.
  static const PitchRange full = PitchRange(0, 127);

  /// Lowest playable note.
  final int lowest;

  /// Highest playable note.
  final int highest;

  /// Whether `pitch` is playable.
  bool contains(int pitch) => pitch >= lowest && pitch <= highest;
}

/// The post-processing chain of §6.1.
///
/// Every step is a pure function from phrase to phrase, applied in the order
/// written down in `docs/rules/generation-pipeline.md` §3. The order is the
/// specification: humanising before accenting would smear the accents, and
/// clamping after humanising could push a note back out of range.
abstract final class PostProcessing {
  /// Run the whole chain.
  static SizedPhrase apply(
    SizedPhrase phrase,
    GenerationContext context, {
    PitchRange range = PitchRange.full,
    bool monophonic = false,
    double intensity = 1.0,
    double humanizeTiming = 0.012,
    double humanizeVelocity = 0.07,
  }) {
    var result = clampToRange(phrase, range);
    if (monophonic) {
      result = fixOverlaps(result);
    }
    result = applyAccents(result, context);
    result = applyAnticipation(result, context);
    if (monophonic) {
      // Again, because anticipation moves a note earlier *and lengthens it by
      // the same amount* so that its end stays put — which walks its onset
      // back into the note before it. On a monophonic voice that is the
      // overlap the step above had just removed, put back by the step after.
      result = fixOverlaps(result);
    }
    result = humanise(
      result,
      seed: context.randomSeed,
      timing: humanizeTiming,
      velocity: humanizeVelocity,
    );
    return shapeVelocity(result, intensity);
  }

  /// Move notes into the voice's range, by octaves (§6.1 step 1).
  ///
  /// Octaves rather than clamping: a bass line pushed up an octave is still the
  /// line, a bass line with three notes pinned to the same pitch is not.
  /// A drum phrase is left alone — its pitches are instruments.
  static SizedPhrase clampToRange(SizedPhrase phrase, PitchRange range) {
    if (phrase.isDrums) {
      return phrase;
    }
    return phrase.processed(
      map: (note) {
        var pitch = note.pitch;
        while (pitch < range.lowest && pitch + 12 <= range.highest) {
          pitch += 12;
        }
        while (pitch > range.highest && pitch - 12 >= range.lowest) {
          pitch -= 12;
        }
        return pitch == note.pitch
            ? note
            : note.copyWith(pitch: pitch.clamp(range.lowest, range.highest));
      },
    );
  }

  /// Shorten a note that runs into the next (§6.1 step 2).
  ///
  /// Only for a monophonic voice: two overlapping notes on one string is not
  /// something a bass player can do, and it makes the sampler steal its own
  /// voice.
  static SizedPhrase fixOverlaps(SizedPhrase phrase, {double gap = 0.02}) {
    if (phrase.length < 2) {
      return phrase;
    }
    final notes = phrase.notes;
    final fixed = <NoteEvent>[];
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
      if (i + 1 >= notes.length) {
        fixed.add(note);
        continue;
      }
      final next = notes[i + 1].positionInBeats;
      final longest = next - note.positionInBeats - gap;
      if (longest <= 0) {
        // Two notes in the same place: a monophonic voice can only sound
        // one. Keep the first and drop the others sharing its onset — what
        // this step has always promised — rather than letting them ring at
        // full length.
        while (i + 1 < notes.length &&
            notes[i + 1].positionInBeats - note.positionInBeats <= gap) {
          i++;
        }
        // And then trim the survivor against the next note that is still
        // there. Adding it at its full length was the bug this whole step
        // exists to prevent: dropping the coincident notes and keeping a
        // four-beat note over the one a beat later left exactly the overlap
        // it had just removed.
        final after = i + 1 < notes.length
            ? notes[i + 1].positionInBeats - note.positionInBeats - gap
            : double.infinity;
        fixed.add(
          note.beatDuration > after && after > 0
              ? note.copyWith(beatDuration: after)
              : note,
        );
      } else if (note.beatDuration > longest) {
        fixed.add(note.copyWith(beatDuration: longest));
      } else {
        fixed.add(note);
      }
    }
    return phrase.withOnly(fixed);
  }

  /// Raise the velocity of notes under an accented chord (§6.1 step 3).
  static SizedPhrase applyAccents(
    SizedPhrase phrase,
    GenerationContext context,
  ) {
    if (context.chords.isEmpty) {
      return phrase;
    }
    return phrase.processed(
      map: (note) {
        final chord = context.chordAt(note.positionInBeats);
        if (chord == null) {
          return note;
        }
        final boost = switch (chord.chord.rendering.accent) {
          ChordAccent.none => 0,
          ChordAccent.medium => 12,
          ChordAccent.strong => 24,
        };
        if (boost == 0) {
          return note;
        }
        // Only the note that lands on the chord is accented; accenting the
        // whole span would just make that chord louder, which is not an accent.
        final onTheChord =
            (note.positionInBeats - chord.startBeat).abs() < 0.125;
        return onTheChord
            ? note.copyWith(velocity: (note.velocity + boost).clamp(1, 127))
            : note;
      },
    );
  }

  /// Push notes that begin an anticipated chord earlier (§6.1 step 4, §6.6).
  static SizedPhrase applyAnticipation(
    SizedPhrase phrase,
    GenerationContext context,
  ) {
    final pushes = <double, double>{};
    for (final chord in context.chords) {
      // In the phrase's own beats. The enum counts quarters, because an
      // eighth note is half a quarter in every meter while "half a beat" is
      // an eighth in 4/4 and a sixteenth in 6/8.
      final beats = chord.chord.rendering.anticipation.beatsIn(
        phrase.timeSignature,
      );
      if (beats > 0 && chord.startBeat - beats >= phrase.beatRange.start) {
        pushes[chord.startBeat] = beats;
      }
    }
    if (pushes.isEmpty) {
      return phrase;
    }
    return phrase.processed(
      map: (note) {
        for (final entry in pushes.entries) {
          if ((note.positionInBeats - entry.key).abs() < 0.125) {
            return note
                .copyWith(
                  positionInBeats: note.positionInBeats - entry.value,
                  beatDuration: note.beatDuration + entry.value,
                )
                .tagged('anticipated', true);
          }
        }
        return note;
      },
    );
  }

  /// Timing and velocity jitter, *correlated* rather than independent
  /// (§6.1 step 5, §6.6).
  ///
  /// A random walk with a pull back to centre: a player who is dragging stays
  /// dragging for a few notes and then recovers. Independent noise sounds like
  /// a machine with a fault, which is the opposite of the point.
  static SizedPhrase humanise(
    SizedPhrase phrase, {
    required int seed,
    double timing = 0.012,
    double velocity = 0.07,
  }) {
    if (phrase.isEmpty || (timing <= 0 && velocity <= 0)) {
      return phrase;
    }
    final random = Random(seed);
    var timingWalk = 0.0;
    var velocityWalk = 0.0;
    const pull = 0.45;

    // §6.6 asks for jitter that is *correlated, not independent*, and a chord
    // is where that stops being a nicety. Advancing the timing walk per note
    // gives the four notes of one voicing four different onsets, which is an
    // arpeggio — a different articulation, not a humanised chord. So the walk
    // advances once per distinct onset and every note sharing that onset moves
    // together.
    //
    // Velocity still varies per note: a pianist does not strike four keys with
    // identical force, and that variation is what stops a voicing sounding
    // like one sampled block.
    final humanised = <NoteEvent>[];
    double? currentOnset;
    var offset = 0.0;
    for (final note in phrase.notes) {
      if (currentOnset == null || note.positionInBeats != currentOnset) {
        currentOnset = note.positionInBeats;
        timingWalk =
            timingWalk * (1 - pull) + (random.nextDouble() * 2 - 1) * pull;
        offset = timingWalk * timing;
      }
      velocityWalk =
          velocityWalk * (1 - pull) + (random.nextDouble() * 2 - 1) * pull;

      final moved = (note.positionInBeats + offset).clamp(
        phrase.beatRange.start,
        phrase.beatRange.end,
      );
      final louder = (note.velocity * (1 + velocityWalk * velocity))
          .round()
          .clamp(1, 127);
      humanised.add(note.copyWith(positionInBeats: moved, velocity: louder));
    }
    return phrase.withOnly(humanised);
  }

  /// Scale every velocity by the part's intensity (§6.1 step 6).
  static SizedPhrase shapeVelocity(SizedPhrase phrase, double intensity) {
    if ((intensity - 1.0).abs() < 1e-6) {
      return phrase;
    }
    final scale = intensity.clamp(0.1, 2.0);
    return phrase.processed(
      map: (note) => note.copyWith(
        velocity: (note.velocity * scale).round().clamp(1, 127),
      ),
    );
  }
}
