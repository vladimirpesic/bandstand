import 'chord_leadsheet.dart';
import 'lead_sheet_item.dart';

/// The most bars an expansion will produce before giving up.
///
/// About two hours of music at any sane tempo. A chart that needs more is a
/// chart with a contradiction in it, and hanging on stage is worse than playing
/// something slightly wrong. See `docs/rules/form-navigation.md` §4.
const int maxFlattenedBars = 4096;

/// Something wrong with the chart's navigation.
///
/// Reported rather than thrown: a chart with a broken repeat still opens, still
/// displays, and still plays something.
class NavigationProblem {
  /// Create a problem report.
  const NavigationProblem(this.bar, this.message);

  /// The written bar the problem is at, or −1 if it is about the chart overall.
  final int bar;

  /// What is wrong, in words a musician would use.
  final String message;

  @override
  String toString() => bar < 0 ? message : 'bar ${bar + 1}: $message';

  @override
  bool operator ==(Object other) =>
      other is NavigationProblem &&
      other.bar == bar &&
      other.message == message;

  @override
  int get hashCode => Object.hash(bar, message);
}

/// The result of expanding a chart's form.
class FlattenedForm {
  /// Create a flattened form.
  FlattenedForm({
    required List<int> sourceBars,
    required List<NavigationProblem> problems,
    required this.truncated,
  }) : sourceBars = List<int>.unmodifiable(sourceBars),
       problems = List<NavigationProblem>.unmodifiable(problems);

  /// For each bar of playback, the bar of the written page it came from.
  ///
  /// This is the map §4.5 insists on: without it the cursor highlights the
  /// wrong place on any tune with repeats, which is most tunes.
  final List<int> sourceBars;

  /// Everything wrong with the chart's navigation.
  final List<NavigationProblem> problems;

  /// Whether the expansion hit [maxFlattenedBars] and stopped early.
  final bool truncated;

  /// How many bars playback lasts.
  int get length => sourceBars.length;

  /// Whether the chart's navigation is sound.
  bool get isWellFormed => problems.isEmpty && !truncated;

  /// The written bar playback bar [index] came from.
  int sourceBarAt(int index) => sourceBars[index];

  /// Every playback bar that came from written bar [sourceBar], in order.
  List<int> playbackBarsFor(int sourceBar) => <int>[
    for (var i = 0; i < sourceBars.length; i++)
      if (sourceBars[i] == sourceBar) i,
  ];

  @override
  String toString() =>
      'FlattenedForm(${sourceBars.length} bars, ${problems.length} problems)';
}

/// One run of numbered endings belonging to the same repeat.
class _EndingGroup {
  _EndingGroup(this.endings);

  final List<CliEnding> endings;

  int get firstBar => endings.first.bar;

  int get endBar =>
      endings.map((e) => e.endBar).reduce((a, b) => a > b ? a : b);

  CliEnding? forPass(int pass) {
    for (final ending in endings) {
      if (ending.passNumbers.contains(pass)) {
        return ending;
      }
    }
    return null;
  }
}

/// Split the chart's endings into groups.
///
/// A group is a run of endings whose pass numbers climb. A new group starts
/// when an ending's lowest pass number does not exceed the previous ending's —
/// which is what a second, unrelated repeat later in the chart looks like.
List<_EndingGroup> _groupEndings(List<CliEnding> endings) {
  if (endings.isEmpty) {
    return const <_EndingGroup>[];
  }
  final groups = <_EndingGroup>[];
  var current = <CliEnding>[endings.first];
  for (var i = 1; i < endings.length; i++) {
    final previousLowest = current.last.passNumbers.first;
    if (endings[i].passNumbers.first <= previousLowest) {
      groups.add(_EndingGroup(current));
      current = <CliEnding>[endings[i]];
    } else {
      current.add(endings[i]);
    }
  }
  groups.add(_EndingGroup(current));
  return groups;
}

/// Expand a chart's repeats, endings and jumps into a linear bar sequence.
///
/// The traversal and the order its rules are applied in are written down in
/// `docs/rules/form-navigation.md` §3; this is that, and nothing else.
///
/// [fromBar] and [toBar] confine the expansion to part of the chart, which is
/// what flattening one song part needs: within the range, "the top" is
/// [fromBar], and marks outside it are invisible.
FlattenedForm resolveNavigation(
  ChordLeadSheet sheet, {
  int fromBar = 0,
  int? toBar,
}) {
  final start = fromBar.clamp(0, sheet.barCount);
  final end = (toBar ?? sheet.barCount).clamp(start, sheet.barCount);
  final problems = <NavigationProblem>[];
  final emitted = <int>[];

  bool inRange(int bar) => bar >= start && bar < end;

  final repeatStarts = <int>{
    for (final item in sheet.items.whereType<CliRepeat>())
      if (item.isStart && inRange(item.bar)) item.bar,
  };
  final repeatEnds = <int, CliRepeat>{
    for (final item in sheet.items.whereType<CliRepeat>())
      if (!item.isStart && inRange(item.bar)) item.bar: item,
  };
  final groups = _groupEndings(<CliEnding>[
    for (final item in sheet.items.whereType<CliEnding>())
      if (inRange(item.bar)) item,
  ]);
  final groupOfBar = <int, int>{
    for (var g = 0; g < groups.length; g++)
      for (final ending in groups[g].endings) ending.bar: g,
  };
  final marksByBar = <int, List<NavigationMark>>{};
  for (final item in sheet.items.whereType<CliNavigation>()) {
    if (inRange(item.bar)) {
      marksByBar.putIfAbsent(item.bar, () => <NavigationMark>[]).add(item.mark);
    }
  }

  int? barWithMark(NavigationMark mark) {
    for (final entry in marksByBar.entries) {
      if (entry.value.contains(mark)) {
        return entry.key;
      }
    }
    return null;
  }

  final segnoBar = barWithMark(NavigationMark.segno);
  final codaBar = barWithMark(NavigationMark.coda);

  final repeatPass = <int, int>{};
  final groupPass = <int, int>{};
  var jumped = false;
  var target = _JumpTarget.none;
  var bar = start;
  var truncated = false;

  while (bar < end) {
    if (emitted.length >= maxFlattenedBars) {
      truncated = true;
      problems.add(
        const NavigationProblem(
          -1,
          'the form does not end: expansion stopped after $maxFlattenedBars bars',
        ),
      );
      break;
    }

    // 1. Ending filter (`docs/rules/form-navigation.md` §3.1).
    final groupIndex = groupOfBar[bar];
    if (groupIndex != null) {
      final group = groups[groupIndex];
      if (bar == group.firstBar) {
        groupPass[groupIndex] = (groupPass[groupIndex] ?? 0) + 1;
      }
      final pass = groupPass[groupIndex] ?? 1;
      final wanted = group.forPass(pass);
      if (wanted == null || bar >= wanted.endBar) {
        // Either nothing is played on this pass, or the bracket that was has
        // finished and the traversal has walked into a later one. Either way,
        // leave the group.
        if (group.endBar <= bar) {
          problems.add(
            NavigationProblem(bar, 'this ending group has no way out'),
          );
          break;
        }
        bar = group.endBar;
        continue;
      }
      if (bar < wanted.bar) {
        // The bracket for this pass is further on; skip to it.
        bar = wanted.bar;
        continue;
      }
    }

    // 2. Emit.
    emitted.add(bar);

    // 3. Decide the next bar. The order is the specification.
    final marks = marksByBar[bar] ?? const <NavigationMark>[];

    if (target == _JumpTarget.fine && marks.contains(NavigationMark.fine)) {
      break;
    }

    if (target == _JumpTarget.coda && marks.contains(NavigationMark.toCoda)) {
      if (codaBar == null) {
        problems.add(
          NavigationProblem(bar, 'To Coda, but the chart has no Coda'),
        );
      } else {
        bar = codaBar;
        continue;
      }
    }

    final jump = marks.where((mark) => mark.isJump).firstOrNull;
    if (jump != null && !jumped) {
      if (jump.isDalSegno && segnoBar == null) {
        problems.add(
          NavigationProblem(bar, '${jump.label}, but the chart has no Segno'),
        );
      } else {
        jumped = true;
        target = jump.isAlFine
            ? _JumpTarget.fine
            : (jump.isAlCoda ? _JumpTarget.coda : _JumpTarget.none);
        // After a jump the form is played from the top again, so the endings
        // start from their first bracket — which is what a band does.
        groupPass.clear();
        bar = jump.isDalSegno ? segnoBar! : start;
        continue;
      }
    }

    // Repeats are not taken again after a Da Capo or Dal Segno — the
    // convention every published chart assumes.
    final repeatEnd = repeatEnds[bar];
    if (!jumped && repeatEnd != null) {
      final taken = repeatPass[bar] ?? 0;
      if (taken + 1 < repeatEnd.playCount) {
        repeatPass[bar] = taken + 1;
        bar = _matchingRepeatStart(repeatStarts, bar, start);
        continue;
      }
    }

    bar++;
  }

  if (emitted.isEmpty) {
    problems.add(const NavigationProblem(-1, 'the chart plays no bars at all'));
  }
  if (codaBar != null && barWithMark(NavigationMark.toCoda) == null) {
    problems.add(NavigationProblem(codaBar, 'a Coda that nothing jumps to'));
  }

  return FlattenedForm(
    sourceBars: emitted,
    problems: problems,
    truncated: truncated,
  );
}

enum _JumpTarget { none, fine, coda }

/// The nearest repeat start at or before [endBar], or the top of the range.
int _matchingRepeatStart(Set<int> starts, int endBar, int top) {
  var best = top;
  for (final candidate in starts) {
    if (candidate <= endBar && candidate > best) {
      best = candidate;
    }
  }
  return best;
}
