import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

void main() {
  setUpAll(installTestHarmony);

  test('the intervals are the direction that is correct', () {
    // A Bb trumpet sounds a major second below what it reads, so to sound
    // concert C it must read D — the chart moves UP.
    expect(InstrumentTransposition.concert.semitones, 0);
    expect(InstrumentTransposition.bFlat.semitones, 2);
    expect(InstrumentTransposition.eFlat.semitones, 9);
    expect(InstrumentTransposition.f.semitones, 7);
    expect(InstrumentTransposition.g.semitones, 5);
    expect(InstrumentTransposition.concert.isConcert, isTrue);
    expect(InstrumentTransposition.bFlat.isConcert, isFalse);
  });

  group('a chart read by a transposing player', () {
    test('a Bb tenor reading a tune in concert C reads it in D', () {
      final chord = ChordSymbol.parse('C7');
      const setting = InstrumentTransposition.bFlat;
      final key = KeySignature.parse('C');
      expect(setting.writtenKey(key).toString(), 'D');
      expect(
        chord
            .transposed(
              setting.semitones,
              preference: setting.preferenceFor(key),
            )
            .format(),
        'D7',
      );
    });

    test('an alto reading a tune in concert Eb reads it in C', () {
      const setting = InstrumentTransposition.eFlat;
      final key = KeySignature.parse('Eb');
      expect(setting.writtenKey(key).toString(), 'C');
      final progression = <String>['Fm7', 'Bb7', 'Ebmaj7'];
      final written = <String>[
        for (final text in progression)
          ChordSymbol.parse(text)
              .transposed(
                setting.semitones,
                preference: setting.preferenceFor(key),
              )
              .format(),
      ];
      expect(written, <String>['Dm7', 'G7', 'Cmaj7']);
    });

    test('a horn in F reading a tune in concert Bb reads it in F', () {
      const setting = InstrumentTransposition.f;
      final key = KeySignature.parse('Bb');
      expect(setting.writtenKey(key).toString(), 'F');
    });

    test('the written key is the simplest spelling of its pitch class', () {
      // Concert Db up nine semitones is pitch class 10: Bb (two flats), not
      // A# (which is not a key).
      expect(
        InstrumentTransposition.eFlat
            .writtenKey(KeySignature.parse('Db'))
            .toString(),
        'Bb',
      );
      // Concert B up two is pitch class 1: Db (five flats) beats C# (seven
      // sharps).
      expect(
        InstrumentTransposition.bFlat
            .writtenKey(KeySignature.parse('B'))
            .toString(),
        'Db',
      );
    });

    test('minor keys stay minor', () {
      final written = InstrumentTransposition.bFlat.writtenKey(
        KeySignature.parse('Gm'),
      );
      expect(written.mode, KeyMode.minor);
      expect(written.toString(), 'Am');
    });

    test('concert pitch changes nothing at all', () {
      final key = KeySignature.parse('Eb');
      expect(InstrumentTransposition.concert.writtenKey(key), key);
      final chord = ChordSymbol.parse('Ebmaj7');
      expect(
        chord.transposed(
          InstrumentTransposition.concert.semitones,
          preference: InstrumentTransposition.concert.preferenceFor(key),
        ),
        same(chord),
      );
    });

    test('every setting produces a readable key from every concert key', () {
      for (final setting in InstrumentTransposition.values) {
        for (final tonic in <String>[
          'Cb', 'Gb', 'Db', 'Ab', 'Eb', 'Bb', 'F', 'C', 'G', 'D', 'A', 'E', //
          'B', 'F#', 'C#',
        ]) {
          for (final suffix in <String>['', 'm']) {
            final key = KeySignature.tryParse('$tonic$suffix');
            if (key == null) {
              continue;
            }
            final written = setting.writtenKey(key);
            expect(
              written.tonic.accidentalCount,
              lessThanOrEqualTo(1),
              reason: '$setting from $key gives $written',
            );
            expect(
              written.tonic.pitchClass,
              (key.tonic.pitchClass + setting.semitones) % 12,
              reason: '$setting from $key',
            );
            expect(written.mode, key.mode);
          }
        }
      }
    });
  });

  test('the setting never mutates the stored chord', () {
    final stored = ChordSymbol.parse('Bbmaj7');
    final read = stored.transposed(InstrumentTransposition.eFlat.semitones);
    expect(read.format(), 'Gmaj7');
    expect(stored.format(), 'Bbmaj7');
  });
}
