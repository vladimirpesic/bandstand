import 'dart:convert';

import 'package:bandstand/domain/harmony/diagrams/chord_diagram_library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony_test_support.dart';

/// The JSON reader, per `docs/format/chord-diagrams.md`.
void main() {
  installTestHarmony();

  String oneInstrument(Map<String, Object?> instrument) => jsonEncode({
    'schemaVersion': chordDiagramsSchemaVersion,
    'instruments': <Object?>[instrument],
  });

  const shape = <String, Object?>{
    'type': '',
    'frets': <int>[-1, 3, 2, 3, 1, -1],
    'rootString': 1,
  };

  test('a well-formed instrument reads', () {
    final library = ChordDiagramLibrary.fromJson(
      oneInstrument(<String, Object?>{
        'id': 'guitar',
        'displayName': 'Guitar',
        'tuning': <int>[40, 45, 50, 55, 59, 64],
        'shapes': <Object?>[
          <String, Object?>{...shape, 'baseFret': 2},
        ],
      }),
    );
    expect(library.instruments.single.id, 'guitar');
    expect(library.instruments.single.displayName, 'Guitar');
    expect(library.instruments.single.shapes.single.baseFret, 2);
  });

  test('a non-integer baseFret is a format error, not a TypeError', () {
    // L-TQ6, the class of finding M9: a wrong-typed field must surface as a
    // FormatException naming the field — not escape as a cast error through
    // whichever layer loaded the file.
    final source = oneInstrument(<String, Object?>{
      'id': 'guitar',
      'tuning': <int>[40, 45, 50, 55, 59, 64],
      'shapes': <Object?>[
        <String, Object?>{...shape, 'baseFret': '3'},
      ],
    });
    expect(
      () => ChordDiagramLibrary.fromJson(source),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('baseFret'),
        ),
      ),
    );
  });

  test('a non-string displayName is a format error, not a TypeError', () {
    final source = oneInstrument(<String, Object?>{
      'id': 'guitar',
      'displayName': 3,
      'tuning': <int>[40, 45, 50, 55, 59, 64],
      'shapes': <Object?>[shape],
    });
    expect(
      () => ChordDiagramLibrary.fromJson(source),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('displayName'),
        ),
      ),
    );
  });
}
