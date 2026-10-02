import 'package:bandstand/domain/generation/generation_context.dart';
import 'package:bandstand/domain/generation/post_processing.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/phrase/float_range.dart';
import 'package:bandstand/domain/phrase/note_event.dart';
import 'package:bandstand/domain/phrase/phrase.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  SizedPhrase phraseOf(List<NoteEvent> notes, {double beats = 8}) =>
      SizedPhrase(
        channel: 0,
        beatRange: FloatRange(0, beats),
        timeSignature: TimeSignature.fourFour,
        notes: notes,
      );

  /// Four notes struck together — a voicing.
  List<NoteEvent> chordAt(double beat, List<int> pitches) => <NoteEvent>[
    for (final pitch in pitches)
      NoteEvent(pitch: pitch, positionInBeats: beat, beatDuration: 1),
  ];

  group('humanising is correlated, not independent (§6.6)', () {
    test('a chord stays a chord — every note keeps the same onset', () {
      final phrase = phraseOf(<NoteEvent>[
        ...chordAt(0, <int>[60, 64, 67, 71]),
        ...chordAt(2, <int>[59, 62, 65, 69]),
        ...chordAt(4.5, <int>[57, 60, 64, 67]),
      ]);
      final humanised = PostProcessing.humanise(phrase, seed: 7, timing: 0.05);

      expect(
        humanised.notes.map((note) => note.positionInBeats).toSet(),
        hasLength(3),
        reason: 'independent jitter would spread each chord into four onsets',
      );
    });

    test('it still moves the chords, or it is not humanising anything', () {
      final phrase = phraseOf(<NoteEvent>[
        ...chordAt(1, <int>[60, 64, 67, 71]),
        ...chordAt(3, <int>[59, 62, 65, 69]),
      ]);
      final humanised = PostProcessing.humanise(phrase, seed: 7, timing: 0.05);
      final moved =
          humanised.notes.map((note) => note.positionInBeats).toSet().toList()
            ..sort();
      expect(moved, hasLength(2));
      expect(moved[0], isNot(1.0));
      expect(moved[1], isNot(3.0));
    });

    test('velocity still varies inside a chord', () {
      // A pianist does not strike four keys with identical force, and losing
      // that would make a voicing sound like one sampled block.
      final phrase = phraseOf(chordAt(0, <int>[60, 64, 67, 71]));
      final humanised = PostProcessing.humanise(
        phrase,
        seed: 3,
        timing: 0,
        velocity: 0.2,
      );
      expect(
        humanised.notes.map((note) => note.velocity).toSet().length,
        greaterThan(1),
      );
    });

    test('nothing leaves the phrase', () {
      final phrase = phraseOf(<NoteEvent>[
        ...chordAt(0, <int>[60, 64]),
        ...chordAt(7.9, <int>[59, 62]),
      ]);
      final humanised = PostProcessing.humanise(phrase, seed: 11, timing: 0.5);
      for (final note in humanised.notes) {
        expect(note.positionInBeats, inInclusiveRange(0, 8));
      }
    });

    test('it is deterministic', () {
      final phrase = phraseOf(<NoteEvent>[
        ...chordAt(0, <int>[60, 64, 67]),
        ...chordAt(2, <int>[59, 62, 65]),
      ]);
      List<String> run() => PostProcessing.humanise(phrase, seed: 5).notes
          .map((note) => '${note.positionInBeats}:${note.velocity}')
          .toList();
      expect(run(), run());
    });

    test('a phrase with nothing to do comes back unchanged', () {
      final phrase = phraseOf(chordAt(0, <int>[60, 64]));
      expect(
        PostProcessing.humanise(phrase, seed: 1, timing: 0, velocity: 0),
        phrase,
      );
    });
  });

  group('fixing overlaps (§6.1 step 2)', () {
    NoteEvent note(int pitch, double at, double length) =>
        NoteEvent(pitch: pitch, positionInBeats: at, beatDuration: length);

    test('a note that runs into the next is shortened', () {
      final phrase = phraseOf(<NoteEvent>[note(50, 0, 2), note(52, 1, 1)]);
      final fixed = PostProcessing.fixOverlaps(phrase);
      expect(fixed.notes.first.beatDuration, closeTo(0.98, 1e-9));
      expect(fixed.notes.last.pitch, 52);
    });

    test('a note landing on its predecessor is dropped, not stacked', () {
      // Two notes in the same place on one string: the second cannot sound,
      // and keeping it at full length would be the sampler stealing its own
      // voice.
      final phrase = phraseOf(<NoteEvent>[
        note(50, 0, 2),
        note(52, 0, 2),
        note(53, 2, 1),
      ]);
      final fixed = PostProcessing.fixOverlaps(phrase);
      expect(fixed.notes.map((n) => n.pitch).toList(), <int>[
        50,
        53,
      ], reason: 'the coincident second note must not ring at full length');
    });

    test('three coincident notes leave one', () {
      final phrase = phraseOf(<NoteEvent>[
        note(48, 1, 1),
        note(50, 1, 1),
        note(52, 1, 1),
        note(53, 3, 1),
      ]);
      final fixed = PostProcessing.fixOverlaps(phrase);
      expect(fixed.notes.map((n) => n.pitch).toList(), <int>[48, 53]);
    });
  });

  group('overlaps the chain used to put back', () {
    SizedPhrase phraseOf(List<NoteEvent> notes) => SizedPhrase(
      channel: 0,
      beatRange: FloatRange(0, 8),
      timeSignature: TimeSignature.fourFour,
      notes: notes,
    );

    /// Every place a note is still sounding when the next one starts.
    List<String> overlapsIn(SizedPhrase phrase) {
      final notes = phrase.notes;
      return <String>[
        for (var i = 0; i + 1 < notes.length; i++)
          if (notes[i].endInBeats > notes[i + 1].positionInBeats)
            '${notes[i].pitch} ends ${notes[i].endInBeats} but '
                '${notes[i + 1].pitch} starts ${notes[i + 1].positionInBeats}',
      ];
    }

    test('dropping coincident notes still shortens the one that is kept', () {
      // The kept note used to be added at its full length and never trimmed
      // against the next note still standing — leaving exactly the overlap
      // this step exists to remove.
      final fixed = PostProcessing.fixOverlaps(
        phraseOf(<NoteEvent>[
          NoteEvent(pitch: 50, positionInBeats: 0, beatDuration: 4),
          NoteEvent(pitch: 52, positionInBeats: 0, beatDuration: 1),
          NoteEvent(pitch: 53, positionInBeats: 1, beatDuration: 1),
        ]),
      );
      expect(fixed.notes.map((note) => note.pitch), <int>[50, 53]);
      expect(overlapsIn(fixed), isEmpty);
    });

    test('a coincident note at the very end keeps its length', () {
      // Nothing follows it, so there is nothing to trim against.
      final fixed = PostProcessing.fixOverlaps(
        phraseOf(<NoteEvent>[
          NoteEvent(pitch: 50, positionInBeats: 0, beatDuration: 4),
          NoteEvent(pitch: 52, positionInBeats: 0, beatDuration: 1),
        ]),
      );
      expect(fixed.notes.single.beatDuration, 4);
    });

    test('anticipation does not reopen an overlap on a monophonic voice', () {
      // Anticipation moves a note earlier *and lengthens it to match*, so its
      // onset walks back into the note before it. Running after `fixOverlaps`,
      // it put back the overlap that had just been removed.
      final context = GenerationContext(
        chords: <ContextChord>[
          ContextChord(
            chord: ExtChordSymbol.parse('Dm7'),
            startBeat: 0,
            endBeat: 4,
          ),
          ContextChord(
            chord: ExtChordSymbol.parse('G7').withRendering(
              const ChordRenderingInfo(anticipation: ChordAnticipation.eighth),
            ),
            startBeat: 4,
            endBeat: 8,
          ),
        ],
        beatRange: FloatRange(0, 8),
        timeSignature: TimeSignature.fourFour,
        tempo: 120,
        randomSeed: 1,
        parameterValues: const <String, Object>{},
      );
      final processed = PostProcessing.apply(
        phraseOf(<NoteEvent>[
          NoteEvent(pitch: 50, positionInBeats: 3, beatDuration: 1),
          NoteEvent(pitch: 55, positionInBeats: 4, beatDuration: 1),
        ]),
        context,
        monophonic: true,
        // Off, so the assertion is about the chain's order and not about
        // whether a few milliseconds of jitter happened to close the gap.
        humanizeTiming: 0,
        humanizeVelocity: 0,
      );
      expect(processed.notes.map((note) => note.positionInBeats), <double>[
        3,
        3.5,
      ]);
      expect(overlapsIn(processed), isEmpty);
    });
  });
}
