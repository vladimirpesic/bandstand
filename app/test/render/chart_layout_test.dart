import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/render/chart_layout.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// A measurer with known metrics, so the layout can be reasoned about exactly.
///
/// Real text measurement is tested where it matters — in the golden images —
/// but a layout test that depends on the platform's font metrics tells you
/// about the font, not about the layout.
class _FixedMeasurer implements ChordMeasurer {
  const _FixedMeasurer() : perCharacter = 0.6;

  final double perCharacter;

  @override
  double measure(String text, double size) => text.length * size * perCharacter;
}

void main() {
  installTestHarmony();

  ChartStyle style({
    ChartDensity density = ChartDensity.normal,
    double chordSize = 24,
  }) => ChartStyle(
    chordSize: chordSize,
    density: density,
    foreground: const Color(0xFFFFFFFF),
    muted: const Color(0xFF888888),
    accent: const Color(0xFFFFB300),
    gridLine: const Color(0xFF444444),
    cursor: const Color(0xFFFFB300),
  );

  ChartLayout layOut(
    ChordLeadSheet sheet, {
    double width = 1200,
    ChartStyle? chartStyle,
    int transposition = 0,
    SpellingPreference? preference,
    KeySignature? numbersIn,
  }) => ChartLayoutEngine.layout(
    sheet: sheet,
    width: width,
    style: chartStyle ?? style(),
    measurer: const _FixedMeasurer(),
    transposition: transposition,
    preference: preference,
    numbersIn: numbersIn,
  );

  CliChordSymbol chord(int bar, double beat, String symbol) =>
      CliChordSymbol(Position(bar, beat), ExtChordSymbol.parse(symbol));

  group('bars per line', () {
    test('a wide chart takes the density preference', () {
      expect(layOut(ChordLeadSheet(barCount: 32)).barsPerLine, 4);
      expect(
        layOut(
          ChordLeadSheet(barCount: 32),
          chartStyle: style(density: ChartDensity.wide),
        ).barsPerLine,
        8,
      );
      expect(
        layOut(
          ChordLeadSheet(barCount: 32),
          chartStyle: style(density: ChartDensity.dense),
        ).barsPerLine,
        2,
      );
    });

    test('a narrow screen takes fewer bars rather than smaller type', () {
      final narrow = layOut(ChordLeadSheet(barCount: 32), width: 320);
      expect(narrow.barsPerLine, lessThan(4));
      // The type is untouched: §8.1 resolves every trade towards legibility.
      expect(narrow.style.chordSize, 24);
      for (final bar in narrow.bars) {
        expect(
          bar.rect.width,
          greaterThanOrEqualTo(narrow.style.minimumBarWidth),
        );
      }
    });

    test('never goes below one bar to a line', () {
      final tiny = layOut(ChordLeadSheet(barCount: 8), width: 60);
      expect(tiny.barsPerLine, 1);
      expect(tiny.lines, hasLength(8));
    });

    test('bars on a line are equal width', () {
      // Equal to floating point: the bars are placed by accumulating widths,
      // which guarantees no gap between them and costs a few ulps.
      final layout = layOut(ChordLeadSheet(barCount: 8));
      for (final line in layout.lines) {
        final first = line.bars.first.rect.width;
        for (final bar in line.bars) {
          expect(bar.rect.width, closeTo(first, 1e-9));
        }
      }
    });
  });

  group('section boundaries', () {
    ChordLeadSheet sectioned() => ChordLeadSheet(
      barCount: 16,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliSection(Section(name: 'B', startBar: 6)),
        CliSection(Section(name: 'C', startBar: 12)),
      ],
    );

    test('a section never starts mid-line', () {
      final layout = layOut(sectioned());
      final starts = <int>{0, 6, 12};
      for (final line in layout.lines) {
        for (final bar in line.bars) {
          if (starts.contains(bar.sourceBar)) {
            expect(
              bar,
              same(line.bars.first),
              reason: 'bar ${bar.sourceBar + 1} starts a section mid-line',
            );
          }
        }
      }
    });

    test('a short section makes a short line, not a stretched one', () {
      final layout = layOut(sectioned());
      // A is six bars at four to a line: 4 + 2.
      expect(layout.lines[0].bars.map((b) => b.sourceBar), <int>[0, 1, 2, 3]);
      expect(layout.lines[1].bars.map((b) => b.sourceBar), <int>[4, 5]);
      expect(
        layout.lines[1].bars.first.rect.width,
        layout.lines[0].bars.first.rect.width,
      );
    });

    test('the section letter is drawn on its first bar only', () {
      final layout = layOut(sectioned());
      final starters = layout.bars.where((b) => b.startsSection).toList();
      expect(starters.map((b) => b.sourceBar), <int>[0, 6, 12]);
      expect(starters.map((b) => b.section!.name), <String>['A', 'B', 'C']);
      expect(layout.barFor(3)!.section!.name, 'A');
      expect(layout.barFor(3)!.startsSection, isFalse);
    });
  });

  group('chords in a bar', () {
    test('sit proportionally to their beats', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 1,
          items: <LeadSheetItem>[chord(0, 0, 'C'), chord(0, 2, 'F')],
        ),
      );
      final bar = layout.barFor(0)!;
      expect(bar.chords, hasLength(2));
      final inset = layout.style.barPadding;
      final usable = bar.rect.width - inset * 2;
      expect(bar.chords[0].left, closeTo(inset, 0.01));
      expect(bar.chords[1].left, closeTo(inset + usable / 2, 0.01));
    });

    test('never overlap, however crowded the bar', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 1,
          items: <LeadSheetItem>[
            chord(0, 0, 'Bbm7b5'),
            chord(0, 1, 'Ebm9'),
            chord(0, 2, 'Abmaj7#11'),
            chord(0, 3, 'Db13b9'),
          ],
        ),
        width: 700,
      );
      final bar = layout.barFor(0)!;
      for (var i = 1; i < bar.chords.length; i++) {
        expect(
          bar.chords[i].left,
          greaterThanOrEqualTo(bar.chords[i - 1].right),
          reason: 'chord $i overlaps the one before it',
        );
      }
    });

    test('the last chord stays inside the bar', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 1,
          items: <LeadSheetItem>[
            chord(0, 0, 'Cmaj7'),
            chord(0, 3.5, 'Abmaj7#11'),
          ],
        ),
        width: 600,
      );
      final bar = layout.barFor(0)!;
      expect(bar.chords.last.right, lessThanOrEqualTo(bar.rect.width + 0.01));
    });

    test('an empty bar has no chords and still occupies its place', () {
      final layout = layOut(ChordLeadSheet(barCount: 4));
      expect(layout.barFor(2)!.chords, isEmpty);
      expect(layout.barFor(2)!.rect.width, greaterThan(0));
    });

    test('display transposition shifts the chords and not the song', () {
      final sheet = ChordLeadSheet(
        barCount: 1,
        items: <LeadSheetItem>[chord(0, 0, 'Dm7')],
      );
      final layout = layOut(sheet, transposition: 2);
      expect(layout.barFor(0)!.chords.single.text, 'Em7');
      expect(sheet.chordItems.single.chord.format(), 'Dm7');
    });

    test('display transposition spells by the destination key', () {
      final sheet = ChordLeadSheet(
        barCount: 1,
        items: <LeadSheetItem>[chord(0, 0, 'C7')],
      );
      expect(
        layOut(
          sheet,
          transposition: 6,
          preference: SpellingPreference.key(KeySignature.parse('E')),
        ).barFor(0)!.chords.single.text,
        'F#7',
      );
      expect(
        layOut(
          sheet,
          transposition: 6,
          preference: SpellingPreference.key(KeySignature.parse('Db')),
        ).barFor(0)!.chords.single.text,
        'Gb7',
      );
    });

    test('N.C. is drawn as N.C.', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 1,
          items: <LeadSheetItem>[
            CliChordSymbol(Position(0), ExtChordSymbol.noChord()),
          ],
        ),
      );
      expect(layout.barFor(0)!.chords.single.text, 'N.C.');
    });
  });

  group('structure', () {
    test('chords clear a repeat barline', () {
      final plain = layOut(
        ChordLeadSheet(
          barCount: 2,
          items: <LeadSheetItem>[chord(0, 0, 'C'), chord(1, 0, 'C')],
        ),
      );
      final repeated = layOut(
        ChordLeadSheet(
          barCount: 2,
          items: <LeadSheetItem>[
            CliRepeat(Position(0), isStart: true),
            chord(0, 0, 'C'),
            chord(1, 0, 'C'),
          ],
        ),
      );
      expect(
        repeated.barFor(0)!.chords.single.left,
        greaterThan(plain.barFor(0)!.chords.single.left),
      );
      // The bar without the barline is untouched.
      expect(
        repeated.barFor(1)!.chords.single.left,
        plain.barFor(1)!.chords.single.left,
      );
    });

    test('a tap on a repeated bar still lands on the right beat', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 2,
          items: <LeadSheetItem>[CliRepeat(Position(0), isStart: true)],
        ),
      );
      final bar = layout.barFor(0)!;
      expect(layout.beatAt(bar, bar.rect.left), 0);
      expect(layout.beatAt(bar, bar.rect.right), 3.5);
    });

    test('repeat barlines land on the right edges', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 4,
          items: <LeadSheetItem>[
            CliRepeat(Position(0), isStart: true),
            CliRepeat(Position(3), isStart: false, playCount: 3),
          ],
        ),
      );
      expect(layout.barFor(0)!.repeatStart, isTrue);
      expect(layout.barFor(0)!.repeatEnd, isFalse);
      expect(layout.barFor(3)!.repeatEnd, isTrue);
      expect(layout.barFor(3)!.repeatPlayCount, 3);
      expect(layout.barFor(1)!.repeatStart, isFalse);
    });

    test('an ending bracket covers every bar it spans', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 6,
          items: <LeadSheetItem>[
            CliEnding(Position(2), <int>{1}, barCount: 2),
            CliEnding(Position(4), <int>{2}, barCount: 2),
          ],
        ),
      );
      expect(layout.barFor(1)!.ending, isNull);
      expect(layout.barFor(2)!.ending, isNotNull);
      expect(layout.barFor(2)!.endingIsFirstBar, isTrue);
      expect(layout.barFor(3)!.ending, isNotNull);
      expect(layout.barFor(3)!.endingIsFirstBar, isFalse);
      expect(layout.barFor(4)!.ending!.passNumbers, <int>{2});
    });

    test('navigation marks are carried to their bars', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 8,
          items: <LeadSheetItem>[
            CliNavigation(Position(2), NavigationMark.segno),
            CliNavigation(Position(7), NavigationMark.dalSegnoAlCoda),
          ],
        ),
      );
      expect(layout.barFor(2)!.marks, <NavigationMark>[NavigationMark.segno]);
      expect(layout.barFor(7)!.marks.single, NavigationMark.dalSegnoAlCoda);
      expect(layout.barFor(3)!.marks, isEmpty);
    });

    test('annotations are carried to their bars', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 4,
          items: <LeadSheetItem>[CliAnnotation(Position(1), 'solo break')],
        ),
      );
      expect(layout.barFor(1)!.annotations, <String>['solo break']);
    });

    test('the meter is written at the start and at every change', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 8,
          items: <LeadSheetItem>[
            CliSection(Section(name: 'A', startBar: 0)),
            CliSection(
              Section(
                name: 'B',
                startBar: 4,
                timeSignature: TimeSignature.threeFour,
              ),
            ),
          ],
        ),
      );
      expect(layout.barFor(0)!.showsTimeSignature, isTrue);
      expect(layout.barFor(1)!.showsTimeSignature, isFalse);
      expect(layout.barFor(4)!.showsTimeSignature, isTrue);
      expect(layout.barFor(4)!.timeSignature, TimeSignature.threeFour);
    });
  });

  group('pickup bars', () {
    test('are drawn narrow, and numbered zero', () {
      final layout = layOut(ChordLeadSheet(barCount: 8, pickupBeats: 1));
      final pickup = layout.barFor(0)!;
      expect(pickup.isPickup, isTrue);
      expect(pickup.displayNumber, 0);
      expect(pickup.rect.width, lessThan(layout.barFor(1)!.rect.width));
      expect(layout.barFor(1)!.displayNumber, 2);
    });

    test('a chart with no pickup numbers from one', () {
      final layout = layOut(ChordLeadSheet(barCount: 4));
      expect(layout.barFor(0)!.isPickup, isFalse);
      expect(layout.barFor(0)!.displayNumber, 1);
    });
  });

  group('finding things on the page', () {
    test('every bar can be found, and none is off the page', () {
      final layout = layOut(ChordLeadSheet(barCount: 32));
      for (var bar = 0; bar < 32; bar++) {
        final laid = layout.barFor(bar);
        expect(laid, isNotNull, reason: 'bar $bar');
        expect(laid!.rect.right, lessThanOrEqualTo(layout.size.width + 0.01));
        expect(laid.rect.bottom, lessThanOrEqualTo(layout.size.height + 0.01));
      }
      expect(layout.barFor(32), isNull);
    });

    test('a tap resolves to a bar and a beat', () {
      final layout = layOut(ChordLeadSheet(barCount: 8));
      final bar = layout.barFor(5)!;
      final hit = layout.barAt(bar.rect.center.dx, bar.rect.center.dy);
      expect(hit!.sourceBar, 5);
      expect(layout.beatAt(bar, bar.rect.left), 0);
      expect(layout.beatAt(bar, bar.rect.right), 3.5);
      expect(layout.beatAt(bar, bar.rect.center.dx), 2);
    });

    test('a tap past the end of a short line lands on its last bar', () {
      final layout = layOut(
        ChordLeadSheet(
          barCount: 6,
          items: <LeadSheetItem>[
            CliSection(Section(name: 'A', startBar: 0)),
            CliSection(Section(name: 'B', startBar: 4)),
          ],
        ),
      );
      final shortLine = layout.lines[1];
      expect(shortLine.bars, hasLength(2));
      final hit = layout.barAt(layout.size.width - 4, shortLine.rect.center.dy);
      expect(hit!.sourceBar, 5);
    });

    test('a tap outside the chart hits nothing', () {
      final layout = layOut(ChordLeadSheet(barCount: 4));
      expect(layout.barAt(10, layout.size.height + 100), isNull);
    });

    test('a tap left of the first bar hits nothing', () {
      final layout = layOut(ChordLeadSheet(barCount: 8));
      final line = layout.lines.first;
      final hit = layout.barAt(
        line.bars.first.rect.left - 4,
        line.rect.center.dy,
      );
      expect(hit, isNull);
    });

    test('the beat is rounded to a half, so a tap is not beat 1.037', () {
      final layout = layOut(ChordLeadSheet(barCount: 1));
      final bar = layout.barFor(0)!;
      final inset = layout.style.barPadding;
      final usable = bar.rect.width - inset * 2;
      final beat = layout.beatAt(bar, bar.rect.left + inset + usable * 0.31);
      expect(beat, 1.0);
      expect((beat * 2) % 1, 0);
    });

    test('a line knows which written bars it holds', () {
      final layout = layOut(ChordLeadSheet(barCount: 12));
      expect(layout.lines.first.firstSourceBar, 0);
      expect(layout.lines.first.lastSourceBar, 3);
      expect(layout.lineFor(5)!.index, 1);
      expect(layout.lineFor(99), isNull);
    });
  });

  group('Nashville numbers (§6b)', () {
    ChordLeadSheet iiVI() => ChordLeadSheet(
      barCount: 4,
      items: <LeadSheetItem>[
        chord(0, 0, 'Dm7'),
        chord(1, 0, 'G7'),
        chord(2, 0, 'Cmaj7'),
        chord(3, 0, 'Cmaj7'),
      ],
    );

    List<String> textsOf(ChartLayout layout) => <String>[
      for (final bar in layout.bars) ...bar.chords.map((c) => c.text),
    ];

    test('a ii-V-I in C is 2m7 57 1maj7', () {
      final layout = layOut(iiVI(), numbersIn: KeySignature.cMajor());
      expect(textsOf(layout), <String>['2m7', '57', '1maj7', '1maj7']);
    });

    test('without a key it is still letters', () {
      expect(textsOf(layOut(iiVI())), <String>['Dm7', 'G7', 'Cmaj7', 'Cmaj7']);
    });

    test('the numbers do not move when the chart is transposed', () {
      // The whole point of the system: one sheet of numbers works in twelve
      // keys, because a number is an interval above the tonic and transposing
      // moves the tonic with everything else.
      final key = KeySignature.cMajor();
      final plain = textsOf(layOut(iiVI(), numbersIn: key));
      for (final semitones in <int>[-5, -1, 2, 7, 11]) {
        expect(
          textsOf(layOut(iiVI(), numbersIn: key, transposition: semitones)),
          plain,
          reason: 'transposing by $semitones changed the numbers',
        );
      }
    });

    test('the same tune written in another key reads the same', () {
      // Blues in Bb and blues in C are one tune in numbers. This is what a
      // player actually uses the system for.
      final inC = layOut(iiVI(), numbersIn: KeySignature.cMajor());
      final inF = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          chord(0, 0, 'Gm7'),
          chord(1, 0, 'C7'),
          chord(2, 0, 'Fmaj7'),
          chord(3, 0, 'Fmaj7'),
        ],
      );
      expect(
        textsOf(layOut(inF, numbersIn: KeySignature.parse('F'))),
        textsOf(inC),
      );
    });

    test('a slash chord keeps its bass as a number', () {
      final sheet = ChordLeadSheet(
        barCount: 1,
        items: <LeadSheetItem>[chord(0, 0, 'C/E')],
      );
      expect(textsOf(layOut(sheet, numbersIn: KeySignature.cMajor())), <String>[
        '1/3',
      ]);
    });

    test('widths follow the drawn text, not the letters behind it', () {
      // Numbers are not uniformly shorter: in C every degree happens to be as
      // long as the note name it replaces, but in F a `B` becomes a `b5` and
      // gets wider. A layout that measured the letters and drew the numbers
      // would misplace them, so this asserts the width tracks what is drawn.
      const size = 24.0;
      const perCharacter = 0.6;
      final sheet = ChordLeadSheet(
        barCount: 1,
        items: <LeadSheetItem>[chord(0, 0, 'B7'), chord(0, 2, 'Bb7')],
      );
      final letters = layOut(sheet);
      final numbers = layOut(sheet, numbersIn: KeySignature.parse('F'));

      expect(numbers.barFor(0)!.chords.first.text, 'b57');
      expect(numbers.barFor(0)!.chords.last.text, '47');

      for (final chord in <LaidOutChord>[
        ...letters.barFor(0)!.chords,
        ...numbers.barFor(0)!.chords,
      ]) {
        expect(
          chord.width,
          closeTo(chord.text.length * size * perCharacter, 0.001),
          reason: '"${chord.text}" was laid out at a width it is not',
        );
      }

      // And the direction, for this pair: `b57` is wider than `B7`.
      expect(
        numbers.barFor(0)!.chords.first.width,
        greaterThan(letters.barFor(0)!.chords.first.width),
      );
    });
  });

  test('the chart grows downwards, never sideways', () {
    for (final width in <double>[320, 480, 800, 1600]) {
      final layout = layOut(ChordLeadSheet(barCount: 32), width: width);
      expect(layout.size.width, width);
      for (final bar in layout.bars) {
        expect(bar.rect.right, lessThanOrEqualTo(width + 0.01));
      }
    }
  });
}
