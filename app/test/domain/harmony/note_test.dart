import 'package:bandstand/domain/harmony/key_signature.dart';
import 'package:bandstand/domain/harmony/note.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('construction', () {
    test('rejects pitches, velocities and durations outside their range', () {
      expect(() => Note(-1), throwsArgumentError);
      expect(() => Note(128), throwsArgumentError);
      expect(() => Note(60, velocity: 0), throwsArgumentError);
      expect(() => Note(60, velocity: 128), throwsArgumentError);
      expect(() => Note(60, beatDuration: 0), throwsArgumentError);
      expect(() => Note(60, beatDuration: -1), throwsArgumentError);
      expect(() => Note(60, beatDuration: double.nan), throwsArgumentError);
      expect(
        () => Note(60, beatDuration: double.infinity),
        throwsArgumentError,
      );
    });

    test('accepts the whole MIDI range', () {
      expect(Note(0).pitch, 0);
      expect(Note(127).pitch, 127);
    });
  });

  test('middle C is MIDI 60, in octave 4', () {
    expect(Note(60).octave, 4);
    expect(Note(60).pitchClass, 0);
    expect(Note(21).octave, 0); // bottom A of a piano
    expect(Note(21).pitchClass, 9);
    expect(Note(0).octave, -1);
  });

  test('spelling depends on the key', () {
    final eFlatNote = Note(63);
    expect(eFlatNote.spellingIn(KeySignature.parse('C')).toString(), 'Eb');
    expect(eFlatNote.spellingIn(KeySignature.parse('E')).toString(), 'D#');
    expect(eFlatNote.nameIn(KeySignature.parse('C')), 'Eb4');
    expect(Note(66).nameIn(KeySignature.parse('E')), 'F#4');
    expect(Note(66).nameIn(KeySignature.parse('Db')), 'Gb4');
  });

  group('transposition', () {
    test('moves the pitch and keeps everything else', () {
      final note = Note(60, beatDuration: 0.5, velocity: 90);
      final moved = note.transposed(7);
      expect(moved.pitch, 67);
      expect(moved.beatDuration, 0.5);
      expect(moved.velocity, 90);
    });

    test('clamps at the ends of the keyboard rather than throwing', () {
      expect(Note(2).transposed(-12).pitch, 0);
      expect(Note(125).transposed(12).pitch, 127);
    });
  });

  test('copyWith replaces one field at a time', () {
    final note = Note(60, beatDuration: 1, velocity: 64);
    expect(note.copyWith(pitch: 62).pitch, 62);
    expect(note.copyWith(pitch: 62).velocity, 64);
    expect(note.copyWith(velocity: 100).velocity, 100);
  });

  test('sorts by pitch, then length, then velocity', () {
    final notes = <Note>[
      Note(62),
      Note(60, velocity: 100),
      Note(60, velocity: 30),
      Note(60, beatDuration: 0.5),
    ]..sort();
    expect(
      notes.map((n) => '${n.pitch}/${n.beatDuration}/${n.velocity}').toList(),
      <String>['60/0.5/64', '60/1.0/30', '60/1.0/100', '62/1.0/64'],
    );
  });

  test('equality is by all three fields', () {
    expect(Note(60), Note(60));
    expect(Note(60), isNot(Note(61)));
    expect(Note(60, velocity: 64), isNot(Note(60, velocity: 65)));
    expect(<Note>{Note(60), Note(60)}, hasLength(1));
  });
}
