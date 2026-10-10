import 'package:bandstand/domain/harmony/position.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/navigation.dart';
import 'package:flutter_test/flutter_test.dart';

ChordLeadSheet sheet(int barCount, List<LeadSheetItem> items) =>
    ChordLeadSheet(barCount: barCount, items: items);

CliRepeat repeatStart(int bar) => CliRepeat(Position(bar), isStart: true);
CliRepeat repeatEnd(int bar, {int times = 2}) =>
    CliRepeat(Position(bar), isStart: false, playCount: times);
CliEnding ending(int bar, Set<int> passes) => CliEnding(Position(bar), passes);
CliNavigation mark(int bar, NavigationMark m) =>
    CliNavigation(Position(bar), m);

void main() {
  group('a chart with no navigation', () {
    test('plays straight through', () {
      final form = resolveNavigation(sheet(4, <LeadSheetItem>[]));
      expect(form.sourceBars, <int>[0, 1, 2, 3]);
      expect(form.isWellFormed, isTrue);
    });

    test('maps every playback bar back to itself', () {
      final form = resolveNavigation(sheet(8, <LeadSheetItem>[]));
      for (var i = 0; i < 8; i++) {
        expect(form.sourceBarAt(i), i);
        expect(form.playbackBarsFor(i), <int>[i]);
      }
    });
  });

  group('repeats', () {
    test('a simple repeat plays its span twice', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[repeatStart(0), repeatEnd(1)]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 1, 2, 3]);
      expect(form.isWellFormed, isTrue);
    });

    test('a repeat count above two plays that many times', () {
      final form = resolveNavigation(
        sheet(3, <LeadSheetItem>[repeatStart(0), repeatEnd(1, times: 3)]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 1, 0, 1, 2]);
    });

    test('a repeat end with no start repeats from the top', () {
      final form = resolveNavigation(sheet(4, <LeadSheetItem>[repeatEnd(1)]));
      expect(form.sourceBars, <int>[0, 1, 0, 1, 2, 3]);
    });

    test('a repeat starting partway through comes back to the right bar', () {
      final form = resolveNavigation(
        sheet(5, <LeadSheetItem>[repeatStart(2), repeatEnd(3)]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 3, 2, 3, 4]);
    });

    test('two repeats in a row are independent', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          repeatEnd(1),
          repeatStart(2),
          repeatEnd(3),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 1, 2, 3, 2, 3]);
    });

    test('a repeat played once is played once', () {
      final form = resolveNavigation(
        sheet(2, <LeadSheetItem>[repeatStart(0), repeatEnd(0, times: 1)]),
      );
      expect(form.sourceBars, <int>[0, 1]);
    });

    test('a repeat cannot be written with a play count below one', () {
      expect(
        () => CliRepeat(Position(0), isStart: false, playCount: 0),
        throwsArgumentError,
      );
    });
  });

  group('numbered endings', () {
    test('the classic first-and-second-time bars', () {
      // |: A B {1} C :| {2} D |
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          ending(2, <int>{1}),
          repeatEnd(2),
          ending(3, <int>{2}),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 0, 1, 3]);
      expect(form.isWellFormed, isTrue);
    });

    test('three endings over a three-times repeat', () {
      final form = resolveNavigation(
        sheet(6, <LeadSheetItem>[
          repeatStart(0),
          ending(2, <int>{1}),
          repeatEnd(2, times: 3),
          ending(3, <int>{2}),
          repeatEnd(3, times: 3),
          ending(4, <int>{3}),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 0, 1, 3, 0, 1, 4, 5]);
    });

    test('an ending played on more than one pass', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          ending(2, <int>{1, 2}),
          repeatEnd(2, times: 3),
          ending(3, <int>{3}),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 0, 1, 2, 0, 1, 3]);
    });

    test('an ending bracket can cover several bars', () {
      // |: A {1} B C :| {2} D E |
      final form = resolveNavigation(
        sheet(5, <LeadSheetItem>[
          repeatStart(0),
          CliEnding(Position(1), <int>{1}, barCount: 2),
          repeatEnd(2),
          CliEnding(Position(3), <int>{2}, barCount: 2),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 0, 3, 4]);
      expect(form.isWellFormed, isTrue);
    });

    test('two unrelated ending groups keep separate counts', () {
      final form = resolveNavigation(
        sheet(8, <LeadSheetItem>[
          repeatStart(0),
          ending(1, <int>{1}),
          repeatEnd(1),
          ending(2, <int>{2}),
          repeatStart(4),
          ending(5, <int>{1}),
          repeatEnd(5),
          ending(6, <int>{2}),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 2, 3, 4, 5, 4, 6, 7]);
      expect(form.isWellFormed, isTrue);
    });

    test('an ending group with no bracket for this pass is left behind', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          ending(1, <int>{1}),
          repeatEnd(1, times: 3),
          ending(2, <int>{2}),
        ]),
      );
      // Pass three has no bracket, so the group is left and bar 3 follows.
      expect(form.sourceBars, <int>[0, 1, 0, 2, 3]);
    });

    test('walking past the bracket for this pass leaves the group', () {
      // Three brackets, a repeat played twice: on pass two the traversal plays
      // bracket two and must then leave, not fall into bracket three and jump
      // backwards forever.
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          ending(1, <int>{1}),
          repeatEnd(1),
          ending(2, <int>{2}),
          ending(3, <int>{3}),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 2]);
      expect(form.truncated, isFalse);
    });

    test('an ending must name at least one pass, numbered from one', () {
      expect(() => CliEnding(Position(0), <int>{}), throwsArgumentError);
      expect(() => CliEnding(Position(0), <int>{0}), throwsArgumentError);
      expect(
        () => CliEnding(Position(0), <int>{1}, barCount: 0),
        throwsArgumentError,
      );
    });
  });

  group('jumps', () {
    test('D.C. al Fine goes back to the top and stops at Fine', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          mark(1, NavigationMark.fine),
          mark(3, NavigationMark.daCapoAlFine),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 3, 0, 1]);
      expect(form.isWellFormed, isTrue);
    });

    test('D.S. al Coda goes back to the sign and out at the coda', () {
      final form = resolveNavigation(
        sheet(6, <LeadSheetItem>[
          mark(1, NavigationMark.segno),
          mark(2, NavigationMark.toCoda),
          mark(3, NavigationMark.dalSegnoAlCoda),
          mark(4, NavigationMark.coda),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 3, 1, 2, 4, 5]);
      expect(form.isWellFormed, isTrue);
    });

    test('a plain D.C. plays to the end again', () {
      final form = resolveNavigation(
        sheet(3, <LeadSheetItem>[mark(2, NavigationMark.daCapo)]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 0, 1, 2]);
    });

    test('the jump is taken once, not every time round', () {
      final form = resolveNavigation(
        sheet(2, <LeadSheetItem>[mark(1, NavigationMark.daCapo)]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 1]);
    });

    test('repeats are not taken again after a jump', () {
      // The convention every published chart assumes.
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          repeatEnd(1),
          mark(3, NavigationMark.daCapo),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 0, 1, 2, 3, 0, 1, 2, 3]);
    });

    test('Fine is ignored on the first pass', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[mark(1, NavigationMark.fine)]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 3]);
    });

    test('To Coda is ignored on the first pass', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          mark(1, NavigationMark.toCoda),
          mark(3, NavigationMark.coda),
        ]),
      );
      expect(form.sourceBars, <int>[0, 1, 2, 3]);
    });
  });

  group('charts that contradict themselves', () {
    test('a Dal Segno with no Segno is reported, not obeyed', () {
      final form = resolveNavigation(
        sheet(3, <LeadSheetItem>[mark(2, NavigationMark.dalSegno)]),
      );
      expect(form.sourceBars, <int>[0, 1, 2]);
      expect(form.problems, hasLength(1));
      expect(form.problems.single.bar, 2);
      expect(form.problems.single.message, contains('Segno'));
      expect(form.isWellFormed, isFalse);
    });

    test('a To Coda with no Coda is reported', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          mark(1, NavigationMark.toCoda),
          mark(3, NavigationMark.daCapoAlCoda),
        ]),
      );
      expect(form.problems.map((p) => p.message).join(), contains('Coda'));
      expect(form.sourceBars, isNotEmpty);
    });

    test('a Coda nothing jumps to is reported', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[mark(3, NavigationMark.coda)]),
      );
      expect(form.problems, hasLength(1));
      expect(form.problems.single.message, contains('nothing jumps to'));
    });

    test('a form that does not end is truncated rather than hanging', () {
      final form = resolveNavigation(
        sheet(2, <LeadSheetItem>[repeatStart(0), repeatEnd(1, times: 100000)]),
      );
      expect(form.truncated, isTrue);
      expect(form.length, maxFlattenedBars);
      expect(form.problems.single.message, contains('does not end'));
    });
  });

  group('the map back to the written page', () {
    test('every playback bar names a real written bar', () {
      final form = resolveNavigation(
        sheet(4, <LeadSheetItem>[
          repeatStart(0),
          ending(2, <int>{1}),
          repeatEnd(2),
          ending(3, <int>{2}),
        ]),
      );
      for (final source in form.sourceBars) {
        expect(source, inInclusiveRange(0, 3));
      }
    });

    test('a repeated bar reports every time it is played', () {
      final form = resolveNavigation(
        sheet(2, <LeadSheetItem>[repeatStart(0), repeatEnd(1, times: 3)]),
      );
      expect(form.playbackBarsFor(0), <int>[0, 2, 4]);
      expect(form.playbackBarsFor(1), <int>[1, 3, 5]);
    });
  });
}
