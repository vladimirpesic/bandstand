import '../harmony/ext_chord_symbol.dart';
import '../harmony/position.dart';
import '../harmony/spelling_preference.dart';
import '../harmony/time_signature.dart';
import 'lead_sheet_item.dart';
import 'section.dart';

/// The written chart: bars, chord symbols, section markers, repeats and
/// navigation marks (§4.3).
///
/// Linear and immutable. Every edit produces a new lead sheet, which is what
/// makes the command pattern of §4.4 cheap: an undo step holds the old value.
class ChordLeadSheet {
  ChordLeadSheet._({
    required this.barCount,
    required List<LeadSheetItem> items,
    required this.pickupBeats,
  }) : items = List<LeadSheetItem>.unmodifiable(items),
       _byBar = _bucketByBar(items),
       _sections = List<Section>.unmodifiable(<Section>[
         for (final item in items.whereType<CliSection>()) item.section,
       ]);

  /// Every item, bucketed by the bar it sits in.
  ///
  /// The renderer, the editor and the MusicXML exporter all walk the bars in
  /// order and ask what is in each one. Answering that by scanning every item
  /// is O(bars x items) — invisible on a 32-bar tune, quadratic on a long one.
  /// Bucketing once here, in the pass that is already sorting, makes it linear.
  final Map<int, List<LeadSheetItem>> _byBar;

  /// The sections, in bar order, resolved once.
  final List<Section> _sections;

  static Map<int, List<LeadSheetItem>> _bucketByBar(List<LeadSheetItem> items) {
    final byBar = <int, List<LeadSheetItem>>{};
    for (final item in items) {
      (byBar[item.bar] ??= <LeadSheetItem>[]).add(item);
    }
    return <int, List<LeadSheetItem>>{
      for (final entry in byBar.entries)
        entry.key: List<LeadSheetItem>.unmodifiable(entry.value),
    };
  }

  /// Create a lead sheet.
  ///
  /// Items are sorted; an item past the last bar is rejected rather than
  /// silently dropped.
  ///
  /// Throws [ArgumentError] if `barCount` is not positive, `pickupBeats` is
  /// negative, an item sits outside the sheet, or two sections share a name or
  /// a bar.
  factory ChordLeadSheet({
    required int barCount,
    Iterable<LeadSheetItem> items = const <LeadSheetItem>[],
    double pickupBeats = 0,
  }) {
    if (barCount < 1) {
      throw ArgumentError.value(barCount, 'barCount', 'must be at least one');
    }
    if (!pickupBeats.isFinite || pickupBeats < 0) {
      throw ArgumentError.value(
        pickupBeats,
        'pickupBeats',
        'must be finite and non-negative',
      );
    }
    final sorted = items.toList()..sort();
    for (final item in sorted) {
      if (item.bar >= barCount) {
        throw ArgumentError.value(
          item,
          'items',
          'sits at bar ${item.bar + 1} of a $barCount-bar sheet',
        );
      }
    }
    final sectionNames = <String>{};
    final sectionBars = <int>{};
    for (final item in sorted.whereType<CliSection>()) {
      if (!sectionNames.add(item.section.name)) {
        throw ArgumentError.value(
          item.section.name,
          'items',
          'two sections are called this',
        );
      }
      if (!sectionBars.add(item.section.startBar)) {
        throw ArgumentError.value(
          item.section.startBar,
          'items',
          'two sections start at this bar',
        );
      }
    }
    return ChordLeadSheet._(
      barCount: barCount,
      items: sorted,
      pickupBeats: pickupBeats,
    );
  }

  /// An empty chart of [barCount] bars with one section.
  factory ChordLeadSheet.empty({
    int barCount = 32,
    String sectionName = 'A',
    TimeSignature timeSignature = TimeSignature.fourFour,
  }) => ChordLeadSheet(
    barCount: barCount,
    items: <LeadSheetItem>[
      CliSection(
        Section(name: sectionName, startBar: 0, timeSignature: timeSignature),
      ),
    ],
  );

  /// How many bars are written.
  final int barCount;

  /// Everything on the page, in position order.
  final List<LeadSheetItem> items;

  /// Length of the pickup bar, in beats. Zero when the chart starts on the
  /// downbeat. See `docs/rules/form-navigation.md` §5.
  final double pickupBeats;

  /// Whether the chart starts with a pickup.
  bool get hasPickup => pickupBeats > 0;

  /// The chord symbols, in order.
  List<CliChordSymbol> get chordItems =>
      items.whereType<CliChordSymbol>().toList();

  /// The sections, in bar order.
  List<Section> get sections => _sections;

  /// The items in [bar], in order.
  List<LeadSheetItem> itemsInBar(int bar) =>
      _byBar[bar] ?? const <LeadSheetItem>[];

  /// Items of one kind in [bar].
  List<T> itemsInBarOfType<T extends LeadSheetItem>(int bar) => <T>[
    for (final item in itemsInBar(bar))
      if (item is T) item,
  ];

  /// The section governing [bar], or null if nothing has started yet.
  Section? sectionAt(int bar) {
    Section? current;
    for (final section in _sections) {
      if (section.startBar <= bar) {
        current = section;
      } else {
        break;
      }
    }
    return current;
  }

  /// The section with this name, or null.
  Section? sectionNamed(String name) {
    for (final section in sections) {
      if (section.name == name) {
        return section;
      }
    }
    return null;
  }

  /// One past the last bar of [section] — the next section's start, or the end
  /// of the sheet.
  int sectionEndBar(Section section) {
    var end = barCount;
    for (final candidate in sections) {
      if (candidate.startBar > section.startBar && candidate.startBar < end) {
        end = candidate.startBar;
      }
    }
    return end;
  }

  /// The meter in force at [bar]: the governing section's, or 4/4.
  TimeSignature timeSignatureAt(int bar) =>
      sectionAt(bar)?.timeSignature ?? TimeSignature.fourFour;

  /// The chord sounding at [position], or null if none has been written yet.
  ExtChordSymbol? chordAt(Position position) {
    ExtChordSymbol? current;
    for (final item in items.whereType<CliChordSymbol>()) {
      if (item.position <= position) {
        current = item.chord;
      } else {
        break;
      }
    }
    return current;
  }

  /// A copy with [item] added.
  ///
  /// A chord replaces any chord already at that exact position; other items are
  /// added alongside. Two chords in one place is always an editing mistake, and
  /// silently keeping both would show one and play the other.
  ChordLeadSheet withItem(LeadSheetItem item) {
    final kept = <LeadSheetItem>[
      for (final existing in items)
        if (!(item is CliChordSymbol &&
            existing is CliChordSymbol &&
            existing.position == item.position))
          existing,
      item,
    ];
    return ChordLeadSheet(
      barCount: barCount,
      items: kept,
      pickupBeats: pickupBeats,
    );
  }

  /// A copy with [item] removed. Removing something absent is not an error.
  ChordLeadSheet withoutItem(LeadSheetItem item) => ChordLeadSheet(
    barCount: barCount,
    items: items.where((existing) => existing != item),
    pickupBeats: pickupBeats,
  );

  /// A copy with every item matching [test] removed.
  ChordLeadSheet withoutWhere(bool Function(LeadSheetItem) test) =>
      ChordLeadSheet(
        barCount: barCount,
        items: items.where((item) => !test(item)),
        pickupBeats: pickupBeats,
      );

  /// A copy with [count] empty bars inserted before [at].
  ///
  /// Everything from `at` onwards moves later, sections included. Throws
  /// [ArgumentError] if `at` is outside `0..barCount` or `count` is not
  /// positive.
  ChordLeadSheet insertBars(int at, int count) {
    if (at < 0 || at > barCount) {
      throw ArgumentError.value(at, 'at', 'must be within the sheet');
    }
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be at least one');
    }
    return ChordLeadSheet(
      barCount: barCount + count,
      items: <LeadSheetItem>[
        for (final item in items)
          // An ending is the one item with a span, so an insert *inside* it
          // has to widen it. Leaving the width alone moved its closing bracket
          // back by `count` bars and silently bracketed different music.
          if (item is CliEnding && item.bar < at && item.endBar > at)
            item.spanning(item.barCount + count)
          else if (item.bar < at)
            item
          else
            item.movedTo(item.position.copyWith(bar: item.bar + count)),
      ],
      pickupBeats: pickupBeats,
    );
  }

  /// A copy with [count] bars removed from [at], and everything in them.
  ///
  /// Throws [ArgumentError] if the range is outside the sheet, or if removing
  /// it would leave no bars at all.
  ChordLeadSheet removeBars(int at, int count) {
    if (at < 0 || count < 1 || at + count > barCount) {
      throw ArgumentError.value(
        '$at..${at + count}',
        'range',
        'must be within the sheet',
      );
    }
    if (barCount - count < 1) {
      throw ArgumentError.value(
        count,
        'count',
        'a chart needs at least one bar',
      );
    }
    return ChordLeadSheet(
      barCount: barCount - count,
      items: <LeadSheetItem?>[
        for (final item in items)
          // The same for a removal, narrowing by however much of the removed
          // range fell inside the ending. An ending left with nothing to
          // bracket goes with the bars it covered.
          if (item is CliEnding && item.bar < at && item.endBar > at)
            _narrowed(item, at, count)
          else if (item.bar < at)
            item
          else if (item.bar >= at + count)
            item.movedTo(item.position.copyWith(bar: item.bar - count)),
      ].nonNulls,
      pickupBeats: pickupBeats,
    );
  }

  /// [ending] with the removed bars taken out of its span, or null when none
  /// of the bars it bracketed are left.
  static CliEnding? _narrowed(CliEnding ending, int at, int count) {
    final from = at > ending.bar ? at : ending.bar;
    final to = (at + count) < ending.endBar ? (at + count) : ending.endBar;
    final removed = to > from ? to - from : 0;
    final remaining = ending.barCount - removed;
    return remaining >= 1 ? ending.spanning(remaining) : null;
  }

  /// A copy with a different bar count.
  ///
  /// Growing adds empty bars at the end; shrinking drops the bars past the new
  /// end, and everything written in them.
  ChordLeadSheet withBarCount(int newBarCount) {
    if (newBarCount < 1) {
      throw ArgumentError.value(
        newBarCount,
        'barCount',
        'must be at least one',
      );
    }
    if (newBarCount >= barCount) {
      return ChordLeadSheet(
        barCount: newBarCount,
        items: items,
        pickupBeats: pickupBeats,
      );
    }
    return removeBars(newBarCount, barCount - newBarCount);
  }

  /// A copy with a different pickup length.
  ChordLeadSheet withPickupBeats(double beats) =>
      ChordLeadSheet(barCount: barCount, items: items, pickupBeats: beats);

  /// A copy with every chord transposed.
  ///
  /// Transposition is a *view* concern for playback and display, but the editor
  /// also offers "transpose this chart for good", and this is that.
  ChordLeadSheet transposed(int semitones, {SpellingPreference? preference}) =>
      ChordLeadSheet(
        barCount: barCount,
        items: <LeadSheetItem>[
          for (final item in items)
            if (item is CliChordSymbol)
              item.withChord(
                item.chord.transposed(semitones, preference: preference),
              )
            else
              item,
        ],
        pickupBeats: pickupBeats,
      );

  @override
  String toString() => 'ChordLeadSheet($barCount bars, ${items.length} items)';

  @override
  bool operator ==(Object other) {
    if (other is! ChordLeadSheet ||
        other.barCount != barCount ||
        other.pickupBeats != pickupBeats ||
        other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (items[i] != other.items[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(barCount, pickupBeats, Object.hashAll(items));
}
