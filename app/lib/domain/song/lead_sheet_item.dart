import '../harmony/ext_chord_symbol.dart';
import '../harmony/position.dart';
import 'section.dart';

/// Where a navigation mark sits relative to its bar.
///
/// A repeat start is at the head of its bar; a repeat end is at the tail. That
/// is not decoration — it is what makes `|: A B :|` play A B A B rather than
/// A B A. See `docs/rules/form-navigation.md` §1.
enum BarAnchor {
  /// At the start of the bar, before anything in it.
  head,

  /// At the end of the bar, after everything in it.
  tail,
}

/// Anything that can be written on the chart at a position.
///
/// Sealed: the set of things a chart can carry is fixed, and every consumer —
/// the renderer, the flattener, the exporter — must handle all of them. A new
/// kind of item should break every switch until it is dealt with.
sealed class LeadSheetItem implements Comparable<LeadSheetItem> {
  const LeadSheetItem(this.position);

  /// Where the item sits.
  final Position position;

  /// The bar the item is in.
  int get bar => position.bar;

  /// Where in the bar the item binds.
  BarAnchor get anchor;

  /// A copy of this item at a new position.
  LeadSheetItem movedTo(Position newPosition);

  /// Items sort by position, then by a fixed kind order so that a bar's head
  /// items come before its chords and its tail items come last.
  @override
  int compareTo(LeadSheetItem other) {
    final byPosition = position.compareTo(other.position);
    if (byPosition != 0) {
      return byPosition;
    }
    return _sortRank.compareTo(other._sortRank);
  }

  int get _sortRank => switch (this) {
    CliSection() => 0,
    CliRepeat(:final isStart) => isStart ? 1 : 8,
    CliEnding() => 2,
    CliNavigation(:final mark) => switch (mark) {
      NavigationMark.segno || NavigationMark.coda => 3,
      _ => 7,
    },
    CliChordSymbol() => 5,
    CliAnnotation() => 6,
  };
}

/// A chord symbol on the chart.
final class CliChordSymbol extends LeadSheetItem {
  /// Create a chord item.
  const CliChordSymbol(super.position, this.chord);

  /// The chord, with its performance instructions.
  final ExtChordSymbol chord;

  @override
  BarAnchor get anchor => BarAnchor.head;

  @override
  CliChordSymbol movedTo(Position newPosition) =>
      CliChordSymbol(newPosition, chord);

  /// A copy with a different chord.
  CliChordSymbol withChord(ExtChordSymbol newChord) =>
      CliChordSymbol(position, newChord);

  @override
  String toString() => '${chord.format()}@$position';

  @override
  bool operator ==(Object other) =>
      other is CliChordSymbol &&
      other.position == position &&
      other.chord == chord;

  @override
  int get hashCode => Object.hash(position, chord);
}

/// A section marker.
final class CliSection extends LeadSheetItem {
  /// Create a section item. Sections always sit at the head of a bar.
  CliSection(this.section) : super(Position(section.startBar));

  /// The section.
  final Section section;

  @override
  BarAnchor get anchor => BarAnchor.head;

  @override
  CliSection movedTo(Position newPosition) =>
      CliSection(section.copyWith(startBar: newPosition.bar));

  @override
  String toString() => 'section $section';

  @override
  bool operator ==(Object other) =>
      other is CliSection && other.section == section;

  @override
  int get hashCode => section.hashCode;
}

/// A repeat barline, either start or end.
final class CliRepeat extends LeadSheetItem {
  /// Create a repeat barline.
  ///
  /// Throws [ArgumentError] if `playCount` is less than one on an end barline.
  CliRepeat(super.position, {required this.isStart, this.playCount = 2}) {
    if (!isStart && playCount < 1) {
      throw ArgumentError.value(
        playCount,
        'playCount',
        'a repeat is played at least once',
      );
    }
  }

  /// Whether this opens (`|:`) or closes (`:|`) the repeat.
  final bool isStart;

  /// How many times the span is played in total. Meaningless on a start.
  final int playCount;

  @override
  BarAnchor get anchor => isStart ? BarAnchor.head : BarAnchor.tail;

  @override
  CliRepeat movedTo(Position newPosition) =>
      CliRepeat(newPosition, isStart: isStart, playCount: playCount);

  @override
  String toString() => isStart ? '|:@$position' : ':|×$playCount@$position';

  @override
  bool operator ==(Object other) =>
      other is CliRepeat &&
      other.position == position &&
      other.isStart == isStart &&
      other.playCount == playCount;

  @override
  int get hashCode => Object.hash(position, isStart, playCount);
}

/// A numbered ending (volta).
///
/// The span is explicit rather than implied by the next barline. An ending
/// bracket covering two bars is ordinary, and the traversal has to know where
/// the group ends in order to leave it — see `docs/rules/form-navigation.md`
/// §3.1.
final class CliEnding extends LeadSheetItem {
  /// Create an ending covering [barCount] bars from its position.
  ///
  /// Throws [ArgumentError] if `passNumbers` is empty, contains a number below
  /// one, or `barCount` is not positive.
  CliEnding(super.position, Set<int> passNumbers, {this.barCount = 1})
    : passNumbers = Set<int>.unmodifiable(passNumbers.toList()..sort()) {
    if (this.passNumbers.isEmpty) {
      throw ArgumentError.value(
        passNumbers,
        'passNumbers',
        'an ending is played on at least one pass',
      );
    }
    if (this.passNumbers.any((n) => n < 1)) {
      throw ArgumentError.value(
        passNumbers,
        'passNumbers',
        'passes are numbered from one',
      );
    }
    if (barCount < 1) {
      throw ArgumentError.value(barCount, 'barCount', 'must be at least one');
    }
  }

  /// Which passes this ending is played on: `{1}`, `{2}`, `{1, 3}`.
  final Set<int> passNumbers;

  /// How many bars the bracket covers.
  final int barCount;

  /// One past the last bar of the bracket.
  int get endBar => bar + barCount;

  @override
  BarAnchor get anchor => BarAnchor.head;

  @override
  CliEnding movedTo(Position newPosition) =>
      CliEnding(newPosition, passNumbers, barCount: barCount);

  /// A copy spanning [newBarCount] bars instead.
  ///
  /// Needed by [ChordLeadSheet.insertBars] and `removeBars`: an ending is the
  /// only item with a *span*, so it is the only one an edit inside its span
  /// has to resize rather than merely move. Moving it alone left the bracket
  /// the same width over a different set of bars.
  CliEnding spanning(int newBarCount) =>
      CliEnding(position, passNumbers, barCount: newBarCount);

  @override
  String toString() =>
      '{${passNumbers.join(',')}}${barCount > 1 ? '×$barCount' : ''}@$position';

  @override
  bool operator ==(Object other) =>
      other is CliEnding &&
      other.position == position &&
      other.barCount == barCount &&
      other.passNumbers.length == passNumbers.length &&
      other.passNumbers.containsAll(passNumbers);

  @override
  int get hashCode =>
      Object.hash(position, barCount, Object.hashAllUnordered(passNumbers));
}

/// The navigation marks a chart carries.
enum NavigationMark {
  /// The sign a Dal Segno jumps to.
  segno('Segno', BarAnchor.head),

  /// Where a To Coda jumps to.
  coda('Coda', BarAnchor.head),

  /// Jump to the coda, on the pass after a Da Capo or Dal Segno al Coda.
  toCoda('To Coda', BarAnchor.tail),

  /// Stop here, on the pass after a Da Capo or Dal Segno al Fine.
  fine('Fine', BarAnchor.tail),

  /// Back to the top.
  daCapo('D.C.', BarAnchor.tail),

  /// Back to the top, then stop at Fine.
  daCapoAlFine('D.C. al Fine', BarAnchor.tail),

  /// Back to the top, then jump at To Coda.
  daCapoAlCoda('D.C. al Coda', BarAnchor.tail),

  /// Back to the sign.
  dalSegno('D.S.', BarAnchor.tail),

  /// Back to the sign, then stop at Fine.
  dalSegnoAlFine('D.S. al Fine', BarAnchor.tail),

  /// Back to the sign, then jump at To Coda.
  dalSegnoAlCoda('D.S. al Coda', BarAnchor.tail);

  const NavigationMark(this.label, this.anchor);

  /// How the mark is written on a chart.
  final String label;

  /// Whether the mark binds to the head or the tail of its bar.
  final BarAnchor anchor;

  /// Whether taking this mark jumps back to the top.
  bool get isDaCapo =>
      this == daCapo || this == daCapoAlFine || this == daCapoAlCoda;

  /// Whether taking this mark jumps back to the segno.
  bool get isDalSegno =>
      this == dalSegno || this == dalSegnoAlFine || this == dalSegnoAlCoda;

  /// Whether this mark is a jump at all.
  bool get isJump => isDaCapo || isDalSegno;

  /// Whether the pass after this jump stops at Fine.
  bool get isAlFine => this == daCapoAlFine || this == dalSegnoAlFine;

  /// Whether the pass after this jump takes the To Coda.
  bool get isAlCoda => this == daCapoAlCoda || this == dalSegnoAlCoda;
}

/// A navigation mark on the chart.
final class CliNavigation extends LeadSheetItem {
  /// Create a navigation item.
  const CliNavigation(super.position, this.mark);

  /// Which mark.
  final NavigationMark mark;

  @override
  BarAnchor get anchor => mark.anchor;

  @override
  CliNavigation movedTo(Position newPosition) =>
      CliNavigation(newPosition, mark);

  @override
  String toString() => '${mark.label}@$position';

  @override
  bool operator ==(Object other) =>
      other is CliNavigation &&
      other.position == position &&
      other.mark == mark;

  @override
  int get hashCode => Object.hash(position, mark);
}

/// Free text on the chart: a lyric cue, a rehearsal note, `solo 2×`.
final class CliAnnotation extends LeadSheetItem {
  /// Create an annotation.
  ///
  /// Throws [ArgumentError] if the text is empty.
  CliAnnotation(super.position, this.text) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'an annotation needs text');
    }
  }

  /// What it says.
  final String text;

  @override
  BarAnchor get anchor => BarAnchor.head;

  @override
  CliAnnotation movedTo(Position newPosition) =>
      CliAnnotation(newPosition, text);

  @override
  String toString() => '"$text"@$position';

  @override
  bool operator ==(Object other) =>
      other is CliAnnotation &&
      other.position == position &&
      other.text == text;

  @override
  int get hashCode => Object.hash(position, text);
}
