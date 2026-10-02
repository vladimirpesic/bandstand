import 'dart:convert';
import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

String corpusOf(List<Map<String, Object?>> phrases, {Object? extra}) =>
    jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'name': 'test',
      'instrument': ?extra,
      'phrases': phrases,
    });

void main() {
  installTestHarmony();

  group('the short form', () {
    test('reads a pitch per beat as a walking line', () {
      final corpus = BassCorpusCodec.decode(
        corpusOf(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'ii-V',
            'chords': <String>['Dm7', 'G7'],
            'notes': <int>[38, 41, 45, 48, 47, 45, 43, 41],
          },
        ]),
      );
      final phrase = corpus.phrases.single;
      expect(phrase.notes, hasLength(8));
      expect(phrase.notes.first.beat, 0);
      expect(phrase.notes.last.beat, 7);
      expect(phrase.lengthBars, 2);
    });

    test('the downbeat of each bar is where a walking line leans', () {
      final corpus = BassCorpusCodec.decode(
        corpusOf(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'ii-V',
            'chords': <String>['Dm7', 'G7'],
            'notes': <int>[38, 41, 45, 48, 47, 45, 43, 41],
          },
        ]),
      );
      final velocities = corpus.phrases.single.notes
          .map((note) => note.velocity)
          .toList();
      expect(velocities, <int>[94, 82, 82, 82, 94, 82, 82, 82]);
    });

    test(
      'a pitch count that does not fit the bars is an error, not a trim',
      () {
        expect(
          () => BassCorpusCodec.decode(
            corpusOf(<Map<String, Object?>>[
              <String, Object?>{
                'name': 'short',
                'chords': <String>['Dm7', 'G7'],
                'notes': <int>[38, 41, 45],
              },
            ]),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('short'), contains('expected 8')),
            ),
          ),
        );
      },
    );
  });

  group('the long form', () {
    test('reads explicit beats, durations and velocities', () {
      final corpus = BassCorpusCodec.decode(
        corpusOf(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'two feel',
            'chords': <String>['Dm7'],
            'notes': <Map<String, Object?>>[
              <String, Object?>{
                'beat': 0,
                'pitch': 38,
                'duration': 1.9,
                'velocity': 96,
              },
              <String, Object?>{'beat': 2, 'pitch': 45},
            ],
          },
        ]),
      );
      final notes = corpus.phrases.single.notes;
      expect(notes, hasLength(2));
      expect(notes.first.durationBeats, 1.9);
      expect(notes.first.velocity, 96);
      expect(notes.last.beat, 2);
      expect(notes.last.durationBeats, 0.92);
    });

    test('mixing the two forms in one phrase is refused', () {
      expect(
        () => BassCorpusCodec.decode(
          corpusOf(<Map<String, Object?>>[
            <String, Object?>{
              'name': 'mixed',
              'chords': <String>['Dm7'],
              'notes': <Object?>[
                <String, Object?>{'beat': 0, 'pitch': 38},
                41,
              ],
            },
          ]),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('one form or the other'),
          ),
        ),
      );
    });
  });

  group('errors name the phrase and the field', () {
    void expectRefused(Object? phrases, Matcher message) {
      expect(
        () => BassCorpusCodec.decode(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'name': 'test',
            'phrases': phrases,
          }),
        ),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', message),
        ),
      );
    }

    test('an unreadable chord', () {
      expect(
        () => BassCorpusCodec.decode(
          corpusOf(<Map<String, Object?>>[
            <String, Object?>{
              'name': 'bad chord',
              'chords': <String>['H9'],
              'notes': <int>[38, 41, 45, 48],
            },
          ]),
        ),
        throwsFormatException,
      );
    });

    test('too many chords for a phrase', () {
      expectRefused(<Map<String, Object?>>[
        <String, Object?>{
          'name': 'long',
          'chords': <String>['Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7'],
          'notes': List<int>.filled(20, 38),
        },
      ], contains('1 to 4 chords'));
    });

    test('a phrase without a name', () {
      expectRefused(<Map<String, Object?>>[
        <String, Object?>{
          'chords': <String>['Dm7'],
          'notes': <int>[38, 41, 45, 48],
        },
      ], contains('needs a name'));
    });

    test('a note out of MIDI range says which phrase', () {
      expectRefused(<Map<String, Object?>>[
        <String, Object?>{
          'name': 'too high',
          'chords': <String>['Dm7'],
          'notes': <Map<String, Object?>>[
            <String, Object?>{'beat': 0, 'pitch': 400},
          ],
        },
      ], contains('too high'));
    });

    test('a short-form pitch out of MIDI range is a FormatException too', () {
      // The short form built its notes bare, so an out-of-range pitch
      // escaped decode() as the ArgumentError BassNoteSpec throws — wrong
      // contract, and it named no phrase.
      expectRefused(<Map<String, Object?>>[
        <String, Object?>{
          'name': 'short too high',
          'chords': <String>['Dm7'],
          'notes': <int>[38, 41, 45, 400],
        },
      ], contains('short too high'));
    });

    test('a backwards tempo range', () {
      expectRefused(<Map<String, Object?>>[
        <String, Object?>{
          'name': 'backwards',
          'chords': <String>['Dm7'],
          'notes': <int>[38, 41, 45, 48],
          'tempoRange': <int>[240, 90],
        },
      ], contains('backwards'));
    });

    test('no phrases at all', () {
      expectRefused(const <Object?>[], contains('no phrases'));
    });
  });

  group('the top level', () {
    test('a schema version this build does not know is refused', () {
      expect(
        () => BassCorpusCodec.decode(
          jsonEncode(<String, Object?>{
            'schemaVersion': 99,
            'name': 'future',
            'phrases': <Object?>[],
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('schema version 99'),
          ),
        ),
      );
    });

    test('a declared instrument range is honoured', () {
      final corpus = BassCorpusCodec.decode(
        corpusOf(
          <Map<String, Object?>>[
            <String, Object?>{
              'name': 'bass guitar',
              'chords': <String>['Dm7'],
              'notes': <int>[38, 41, 45, 48],
            },
          ],
          extra: <String, Object?>{'lowestPitch': 28, 'highestPitch': 67},
        ),
      );
      expect(corpus.range.lowest, 28);
      expect(corpus.range.highest, 67);
      expect(corpus.phrases.single.range.highest, 67);
    });

    test('a nonsensical instrument range is refused', () {
      expect(
        () => BassCorpusCodec.decode(
          corpusOf(
            <Map<String, Object?>>[
              <String, Object?>{
                'name': 'x',
                'chords': <String>['Dm7'],
                'notes': <int>[38, 41, 45, 48],
              },
            ],
            extra: <String, Object?>{'lowestPitch': 90, 'highestPitch': 40},
          ),
        ),
        throwsFormatException,
      );
    });

    test('not an object at all', () {
      expect(() => BassCorpusCodec.decode('[]'), throwsFormatException);
    });
  });

  group('encoding round-trips', () {
    test('the shipped corpus survives a write and a read', () {
      final original = BassCorpusCodec.decode(
        File('assets/bass_corpus.json').readAsStringSync(),
      );
      final again = BassCorpusCodec.decode(BassCorpusCodec.encode(original));

      expect(again.length, original.length);
      expect(again.name, original.name);
      expect(again.range, original.range);
      for (var i = 0; i < original.length; i++) {
        final before = original.phrases[i];
        final after = again.phrases[i];
        expect(after.name, before.name);
        expect(after.rootProfile, before.rootProfile);
        expect(after.tags, before.tags);
        expect(after.tempoRange.lowest, before.tempoRange.lowest);
        expect(after.tempoRange.highest, before.tempoRange.highest);
        expect(
          after.notes.map(
            (note) => <Object>[note.beat, note.pitch, note.velocity],
          ),
          before.notes.map(
            (note) => <Object>[note.beat, note.pitch, note.velocity],
          ),
        );
      }
    });

    test('a long-form phrase stays long-form', () {
      final corpus = BassCorpusCodec.decode(
        corpusOf(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'two feel',
            'chords': <String>['Dm7'],
            'notes': <Map<String, Object?>>[
              <String, Object?>{'beat': 0, 'pitch': 38, 'duration': 1.9},
              <String, Object?>{'beat': 2, 'pitch': 45, 'duration': 1.9},
            ],
          },
        ]),
      );
      final again = BassCorpusCodec.decode(BassCorpusCodec.encode(corpus));
      expect(again.phrases.single.notes.first.durationBeats, 1.9);
      expect(again.phrases.single.notes.last.beat, 2);
    });

    test('an accented long-form phrase keeps its accents', () {
      // A pitch-per-beat phrase whose velocities deviate from the accent
      // pattern is still walking, but the short form cannot carry the
      // accents — it must re-encode long or the velocities are lost.
      final corpus = BassCorpusCodec.decode(
        corpusOf(<Map<String, Object?>>[
          <String, Object?>{
            'name': 'accented',
            'chords': <String>['Dm7'],
            'notes': <Map<String, Object?>>[
              <String, Object?>{'beat': 0, 'pitch': 38, 'velocity': 110},
              <String, Object?>{'beat': 1, 'pitch': 41},
              <String, Object?>{'beat': 2, 'pitch': 45, 'velocity': 65},
              <String, Object?>{'beat': 3, 'pitch': 48},
            ],
          },
        ]),
      );
      final again = BassCorpusCodec.decode(BassCorpusCodec.encode(corpus));
      expect(
        again.phrases.single.notes.map((note) => note.velocity).toList(),
        <int>[110, 82, 65, 82],
      );
    });
  });
}
