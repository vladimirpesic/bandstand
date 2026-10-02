import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

CliChordSymbol chord(int bar, double beat, String symbol) =>
    CliChordSymbol(Position(bar, beat), ExtChordSymbol.parse(symbol));

void main() {
  // Installed eagerly rather than in setUpAll: the group bodies below build
  // chord symbols while the test file is being collected, which happens before
  // any setUp runs.
  installTestHarmony();

  group('construction', () {
    test('rejects a sheet with no bars', () {
      expect(() => ChordLeadSheet(barCount: 0), throwsArgumentError);
    });

    test('rejects an item past the end rather than dropping it', () {
      expect(
        () => ChordLeadSheet(
          barCount: 2,
          items: <LeadSheetItem>[chord(5, 0, 'C')],
        ),
        throwsArgumentError,
      );
    });

    test('rejects two sections with the same name or bar', () {
      expect(
        () => ChordLeadSheet(
          barCount: 8,
          items: <LeadSheetItem>[
            CliSection(Section(name: 'A', startBar: 0)),
            CliSection(Section(name: 'A', startBar: 4)),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => ChordLeadSheet(
          barCount: 8,
          items: <LeadSheetItem>[
            CliSection(Section(name: 'A', startBar: 0)),
            CliSection(Section(name: 'B', startBar: 0)),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('rejects a negative pickup', () {
      expect(
        () => ChordLeadSheet(barCount: 4, pickupBeats: -1),
        throwsArgumentError,
      );
    });

    test('keeps items in position order whatever order they arrive in', () {
      final sheet = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          chord(3, 0, 'G7'),
          chord(0, 2, 'Dm7'),
          chord(0, 0, 'Cmaj7'),
        ],
      );
      expect(sheet.chordItems.map((c) => c.chord.format()).toList(), <String>[
        'Cmaj7',
        'Dm7',
        'G7',
      ]);
    });

    test('a bar head comes before its chords, and its tail after', () {
      final sheet = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          CliRepeat(Position(0), isStart: false),
          chord(0, 0, 'C'),
          CliRepeat(Position(0), isStart: true),
          CliSection(Section(name: 'A', startBar: 0)),
        ],
      );
      expect(sheet.items.first, isA<CliSection>());
      expect(sheet.items[1], isA<CliRepeat>());
      expect((sheet.items[1] as CliRepeat).isStart, isTrue);
      expect(sheet.items.last, isA<CliRepeat>());
      expect((sheet.items.last as CliRepeat).isStart, isFalse);
    });
  });

  group('reading the chart', () {
    final sheet = ChordLeadSheet(
      barCount: 16,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliSection(
          Section(
            name: 'B',
            startBar: 8,
            timeSignature: TimeSignature.threeFour,
          ),
        ),
        chord(0, 0, 'Cmaj7'),
        chord(0, 2, 'A7'),
        chord(4, 0, 'Dm7'),
        chord(8, 0, 'Fm7'),
      ],
    );

    test('finds the section governing a bar', () {
      expect(sheet.sectionAt(0)!.name, 'A');
      expect(sheet.sectionAt(7)!.name, 'A');
      expect(sheet.sectionAt(8)!.name, 'B');
      expect(sheet.sectionAt(15)!.name, 'B');
      expect(ChordLeadSheet(barCount: 4).sectionAt(0), isNull);
    });

    test('finds a section by name, and where it ends', () {
      expect(sheet.sectionNamed('B')!.startBar, 8);
      expect(sheet.sectionNamed('C'), isNull);
      expect(sheet.sectionEndBar(sheet.sectionNamed('A')!), 8);
      expect(sheet.sectionEndBar(sheet.sectionNamed('B')!), 16);
    });

    test('the meter follows the section', () {
      expect(sheet.timeSignatureAt(0), TimeSignature.fourFour);
      expect(sheet.timeSignatureAt(8), TimeSignature.threeFour);
    });

    test('the chord sounding at a position is the last one written', () {
      expect(sheet.chordAt(Position(0, 0))!.format(), 'Cmaj7');
      expect(sheet.chordAt(Position(0, 1))!.format(), 'Cmaj7');
      expect(sheet.chordAt(Position(0, 2))!.format(), 'A7');
      expect(sheet.chordAt(Position(3, 3))!.format(), 'A7');
      expect(sheet.chordAt(Position(4, 0))!.format(), 'Dm7');
      expect(sheet.chordAt(Position(15, 0))!.format(), 'Fm7');
    });

    test('items can be listed per bar', () {
      expect(sheet.itemsInBar(0), hasLength(3));
      expect(sheet.itemsInBarOfType<CliChordSymbol>(0), hasLength(2));
      expect(sheet.itemsInBar(1), isEmpty);
    });
  });

  group('editing', () {
    final base = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        chord(0, 0, 'C'),
        chord(4, 0, 'F'),
      ],
    );

    test('a chord replaces one already in its place', () {
      final edited = base.withItem(chord(0, 0, 'Cmaj7'));
      expect(edited.chordItems, hasLength(2));
      expect(edited.chordAt(Position(0, 0))!.format(), 'Cmaj7');
    });

    test('a chord elsewhere in the same bar is kept', () {
      final edited = base.withItem(chord(0, 2, 'G7'));
      expect(edited.chordItems, hasLength(3));
    });

    test('removing something absent is not an error', () {
      expect(base.withoutItem(chord(7, 0, 'Ab13')).items, base.items);
    });

    test('inserting bars moves everything after them', () {
      final edited = base.insertBars(2, 4);
      expect(edited.barCount, 12);
      expect(edited.chordAt(Position(0, 0))!.format(), 'C');
      expect(edited.chordItems.last.bar, 8);
      expect(edited.sectionAt(0)!.name, 'A');
    });

    test('inserting at the end grows the sheet', () {
      expect(base.insertBars(8, 2).barCount, 10);
    });

    test('removing bars takes what was written in them', () {
      final edited = base.removeBars(0, 2);
      expect(edited.barCount, 6);
      expect(edited.chordItems, hasLength(1));
      expect(edited.chordItems.single.bar, 2);
      expect(edited.sections, isEmpty);
    });

    test('a chart always keeps at least one bar', () {
      expect(() => base.removeBars(0, 8), throwsArgumentError);
      expect(() => base.withBarCount(0), throwsArgumentError);
      expect(() => base.removeBars(6, 4), throwsArgumentError);
    });

    test('shrinking drops what falls off the end', () {
      final edited = base.withBarCount(3);
      expect(edited.barCount, 3);
      expect(edited.chordItems, hasLength(1));
    });

    test('growing adds empty bars', () {
      final edited = base.withBarCount(16);
      expect(edited.barCount, 16);
      expect(edited.items.length, base.items.length);
    });

    test('transposing moves every chord and nothing else', () {
      final edited = base.transposed(2);
      expect(edited.chordItems.map((c) => c.chord.format()).toList(), <String>[
        'D',
        'G',
      ]);
      expect(edited.sections, base.sections);
      expect(base.chordAt(Position(0, 0))!.format(), 'C');
    });

    test('every edit leaves the original alone', () {
      final before = base.items.length;
      base
        ..withItem(chord(1, 0, 'Bb'))
        ..insertBars(0, 4)
        ..removeBars(0, 1)
        ..transposed(5);
      expect(base.items.length, before);
      expect(base.barCount, 8);
    });
  });

  test('equality is by content', () {
    final a = ChordLeadSheet(
      barCount: 4,
      items: <LeadSheetItem>[chord(0, 0, 'C')],
    );
    final b = ChordLeadSheet(
      barCount: 4,
      items: <LeadSheetItem>[chord(0, 0, 'C')],
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(ChordLeadSheet(barCount: 5, items: a.items)));
  });

  group('an ending spans bars, so an edit inside it resizes it', () {
    /// A sheet whose first ending covers bars 2..5.
    ChordLeadSheet withEnding() => ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliEnding(Position(2), <int>{1}, barCount: 4),
      ],
    );

    CliEnding endingOf(ChordLeadSheet sheet) =>
        sheet.items.whereType<CliEnding>().single;

    test('inserting inside the span widens it', () {
      // Only the position moved, so the bracket kept its width and slid back
      // over different music: an ending over bars 2..5 became one over 2..5
      // again after two bars were pushed into the middle of it.
      final sheet = withEnding().insertBars(3, 2);
      final ending = endingOf(sheet);
      expect(ending.bar, 2);
      expect(ending.endBar, 8);
    });

    test('inserting before the span moves it without resizing', () {
      final ending = endingOf(withEnding().insertBars(0, 2));
      expect(ending.bar, 4);
      expect(ending.barCount, 4);
    });

    test('inserting after the span leaves it alone', () {
      final ending = endingOf(withEnding().insertBars(6, 2));
      expect(ending.bar, 2);
      expect(ending.barCount, 4);
    });

    test('removing inside the span narrows it', () {
      final ending = endingOf(withEnding().removeBars(3, 2));
      expect(ending.bar, 2);
      expect(ending.endBar, 4);
    });

    test('removing every bar it covered removes the ending', () {
      final sheet = withEnding().removeBars(2, 4);
      expect(sheet.items.whereType<CliEnding>(), isEmpty);
    });

    test('removing before the span moves it without resizing', () {
      final ending = endingOf(withEnding().removeBars(0, 2));
      expect(ending.bar, 0);
      expect(ending.barCount, 4);
    });
  });
}
