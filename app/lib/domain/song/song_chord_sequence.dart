import '../harmony/ext_chord_symbol.dart';
import '../harmony/position.dart';
import '../harmony/time_signature.dart';
import 'chord_leadsheet.dart';
import 'lead_sheet_item.dart';
import 'navigation.dart';
import 'song.dart';
import 'song_part.dart';

/// One bar of playback.
class FlattenedBar {
  /// Create a flattened bar.
  const FlattenedBar({
    required this.index,
    required this.sourceBar,
    required this.timeSignature,
    required this.startQuarters,
    required this.songPartIndex,
  });

  /// Bar number in the flattened sequence, zero-based.
  final int index;

  /// The bar of the written page this came from — the map §4.5 insists on.
  final int sourceBar;

  /// The meter in this bar.
  final TimeSignature timeSignature;

  /// Quarter notes from the start of playback to this bar line.
  final double startQuarters;

  /// Which song part produced this bar, or null when the sequence was built
  /// straight from the written page.
  final int? songPartIndex;

  /// Length of this bar in quarter notes.
  double get durationQuarters => timeSignature.barDurationInQuarters;

  /// One quarter past the end of this bar.
  double get endQuarters => startQuarters + durationQuarters;

  @override
  String toString() => 'bar ${index + 1} (written ${sourceBar + 1})';
}

/// A chord at an absolute place in the flattened sequence.
class ChordEvent implements Comparable<ChordEvent> {
  /// Create a chord event.
  const ChordEvent({
    required this.chord,
    required this.barIndex,
    required this.beat,
    required this.startQuarters,
    required this.sourceBar,
  });

  /// The chord, with its performance instructions.
  final ExtChordSymbol chord;

  /// Which flattened bar it is in.
  final int barIndex;

  /// Beats into that bar, in the meter's own beats.
  final double beat;

  /// Quarter notes from the start of playback.
  final double startQuarters;

  /// The written bar it came from, so the cursor can find it on the page.
  final int sourceBar;

  /// Its place in the flattened sequence.
  Position get position => Position(barIndex, beat);

  @override
  int compareTo(ChordEvent other) =>
      startQuarters.compareTo(other.startQuarters);

  @override
  String toString() => '${chord.format()}@bar ${barIndex + 1} beat ${beat + 1}';
}

/// The linear bar-by-bar chord sequence the generators see (§4.3).
///
/// This is the *only* input a generator gets: the written page and the
/// arrangement have both been resolved away, repeats and jumps included, and
/// every bar knows which written bar it came from.
class SongChordSequence {
  SongChordSequence._({
    required List<FlattenedBar> bars,
    required List<ChordEvent> chords,
    required List<NavigationProblem> problems,
  }) : bars = List<FlattenedBar>.unmodifiable(bars),
       chords = List<ChordEvent>.unmodifiable(chords),
       problems = List<NavigationProblem>.unmodifiable(problems);

  /// Flatten a song.
  ///
  /// With an arrangement, each song part contributes its section's bars,
  /// expanded by the repeats and endings written inside that section. A part
  /// longer than its section **loops the section** — which is how "play the
  /// bridge twice" is expressed. A part shorter than its section is truncated.
  ///
  /// With no arrangement — a freshly imported chart — the whole written page is
  /// expanded instead, so the song still plays exactly as written.
  ///
  /// See `docs/rules/form-navigation.md`.
  factory SongChordSequence.of(Song song) {
    if (song.structure.isEmpty) {
      return SongChordSequence.asWritten(song.leadSheet);
    }

    final sheet = song.leadSheet;
    final bars = <FlattenedBar>[];
    final problems = <NavigationProblem>[];
    var quarters = 0.0;

    for (
      var partIndex = 0;
      partIndex < song.structure.songParts.length;
      partIndex++
    ) {
      final part = song.structure.songParts[partIndex];
      final expansion = _expandPart(sheet, part, problems);
      if (expansion.isEmpty) {
        continue;
      }
      for (var i = 0; i < part.barCount; i++) {
        final sourceBar = expansion[i % expansion.length];
        final signature = sheet.timeSignatureAt(sourceBar);
        bars.add(
          FlattenedBar(
            index: bars.length,
            sourceBar: sourceBar,
            timeSignature: signature,
            startQuarters: quarters,
            songPartIndex: partIndex,
          ),
        );
        quarters += signature.barDurationInQuarters;
      }
    }

    return SongChordSequence._(
      bars: bars,
      chords: _collectChords(sheet, bars),
      problems: problems,
    );
  }

  /// Flatten the written page alone, expanding its repeats and jumps.
  factory SongChordSequence.asWritten(ChordLeadSheet sheet) {
    final form = resolveNavigation(sheet);
    final bars = <FlattenedBar>[];
    var quarters = 0.0;
    for (final sourceBar in form.sourceBars) {
      final signature = sheet.timeSignatureAt(sourceBar);
      bars.add(
        FlattenedBar(
          index: bars.length,
          sourceBar: sourceBar,
          timeSignature: signature,
          startQuarters: quarters,
          songPartIndex: null,
        ),
      );
      quarters += signature.barDurationInQuarters;
    }
    return SongChordSequence._(
      bars: bars,
      chords: _collectChords(sheet, bars),
      problems: form.problems,
    );
  }

  /// Every bar of playback, in order.
  final List<FlattenedBar> bars;

  /// Every chord, in time order.
  final List<ChordEvent> chords;

  /// Everything wrong with the chart's navigation.
  final List<NavigationProblem> problems;

  /// How many bars playback lasts.
  int get barCount => bars.length;

  /// How long playback lasts, in quarter notes.
  double get totalQuarters => bars.isEmpty ? 0 : bars.last.endQuarters;

  /// Whether the sequence resolved cleanly.
  bool get isWellFormed => problems.isEmpty;

  /// For each playback bar, the written bar it came from (§4.5).
  List<int> get sourceBars => <int>[for (final bar in bars) bar.sourceBar];

  /// Every playback bar that came from written bar [sourceBar].
  List<int> playbackBarsFor(int sourceBar) => <int>[
    for (final bar in bars)
      if (bar.sourceBar == sourceBar) bar.index,
  ];

  /// The chord sounding at [quarters] into playback, or null before the first.
  ExtChordSymbol? chordAtQuarters(double quarters) {
    ExtChordSymbol? current;
    for (final event in chords) {
      if (event.startQuarters <= quarters) {
        current = event.chord;
      } else {
        break;
      }
    }
    return current;
  }

  /// The playback bar containing [quarters], or null past the end.
  FlattenedBar? barAtQuarters(double quarters) {
    for (final bar in bars) {
      if (quarters >= bar.startQuarters && quarters < bar.endQuarters) {
        return bar;
      }
    }
    return null;
  }

  /// The chords in playback bar [index].
  List<ChordEvent> chordsInBar(int index) =>
      chords.where((event) => event.barIndex == index).toList();

  /// The slice of this sequence belonging to song part [partIndex].
  List<FlattenedBar> barsOfPart(int partIndex) =>
      bars.where((bar) => bar.songPartIndex == partIndex).toList();

  /// Expand one song part's section into written bar numbers.
  static List<int> _expandPart(
    ChordLeadSheet sheet,
    SongPart part,
    List<NavigationProblem> problems,
  ) {
    final section = sheet.sectionNamed(part.parentSectionName);
    if (section == null) {
      problems.add(
        NavigationProblem(
          -1,
          'the arrangement plays a section called '
          '"${part.parentSectionName}", which the chart does not have',
        ),
      );
      return const <int>[];
    }
    final form = resolveNavigation(
      sheet,
      fromBar: section.startBar,
      toBar: sheet.sectionEndBar(section),
    );
    problems.addAll(form.problems);
    return form.sourceBars;
  }

  /// Place every written chord into the flattened bars it sounds in.
  static List<ChordEvent> _collectChords(
    ChordLeadSheet sheet,
    List<FlattenedBar> bars,
  ) {
    final byBar = <int, List<CliChordSymbol>>{};
    for (final item in sheet.items.whereType<CliChordSymbol>()) {
      byBar.putIfAbsent(item.bar, () => <CliChordSymbol>[]).add(item);
    }

    final events = <ChordEvent>[];
    for (final bar in bars) {
      for (final item in byBar[bar.sourceBar] ?? const <CliChordSymbol>[]) {
        events.add(
          ChordEvent(
            chord: item.chord,
            barIndex: bar.index,
            beat: item.position.beat,
            startQuarters:
                bar.startQuarters +
                item.position.beat * bar.timeSignature.beatDurationInQuarters,
            sourceBar: bar.sourceBar,
          ),
        );
      }
    }
    events.sort();
    return events;
  }

  @override
  String toString() =>
      'SongChordSequence($barCount bars, ${chords.length} chords)';
}
