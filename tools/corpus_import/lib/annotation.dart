import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/domain/harmony/ext_chord_symbol.dart';

/// A chord annotation: what was on the stand when the take was played.
///
/// Format is deliberately plain text, one chord per bar, because it is written
/// by a person next to an instrument and read in a diff (ADR 0008):
///
/// ```
/// # A blues in F, two choruses.
/// name: blues-in-f
/// tags: walking blues
/// tempoRange: 100 200
///
/// F7  Bb7 F7  F7
/// Bb7 Bb7 F7  F7
/// C7  Bb7 F7  C7
/// ```
///
/// Everything after the headers is chords, whitespace-separated, one per bar,
/// in the order they were played. Line breaks are for the reader.
class ChordAnnotation {
  /// Create an annotation.
  ChordAnnotation({
    required this.name,
    required List<ExtChordSymbol> bars,
    this.tags = const <String>{},
    this.tempoRange,
    this.beatsPerBar = 4,
    this.track,
    this.range = const BassRange(),
  }) : bars = List<ExtChordSymbol>.unmodifiable(bars);

  /// Names the corpus, and prefixes every phrase harvested from this take.
  final String name;

  /// One chord per bar, for the whole take.
  final List<ExtChordSymbol> bars;

  /// Tags applied to every phrase harvested.
  final Set<String> tags;

  /// The tempo band applied to every phrase harvested.
  final TempoRange? tempoRange;

  /// Beats per bar.
  final int beatsPerBar;

  /// Which MIDI track holds the bass, or null to merge every track.
  final int? track;

  /// The instrument the phrases must fit.
  final BassRange range;

  /// How many bars the take covers.
  int get barCount => bars.length;

  /// Parse an annotation file.
  ///
  /// Throws [FormatException] naming the line on anything malformed.
  factory ChordAnnotation.parse(String source) {
    String? name;
    var tags = const <String>{};
    TempoRange? tempoRange;
    var beatsPerBar = 4;
    int? track;
    var lowest = 28;
    var highest = 55;
    final chords = <ExtChordSymbol>[];

    final lines = source.split('\n');
    final commentStart = RegExp(r'(^|\s)#');
    for (var i = 0; i < lines.length; i++) {
      // `#` starts a comment only at the start of a line or after
      // whitespace — never inside a chord token, or `F#7` would harvest
      // as `F`.
      final comment = commentStart.firstMatch(lines[i]);
      final line =
          (comment == null ? lines[i] : lines[i].substring(0, comment.start))
              .trim();
      if (line.isEmpty) {
        continue;
      }
      final header = RegExp(r'^([A-Za-z][A-Za-z]*)\s*:\s*(.*)$')
          .firstMatch(line);
      if (header != null) {
        final key = header.group(1)!.toLowerCase();
        final value = header.group(2)!.trim();
        switch (key) {
          case 'name':
            name = value;
          case 'tags':
            tags = value
                .split(RegExp(r'\s+'))
                .where((t) => t.isNotEmpty)
                .toSet();
          case 'temporange':
            final parts = value.split(RegExp(r'\s+'));
            final low = parts.length == 2 ? int.tryParse(parts[0]) : null;
            final high = parts.length == 2 ? int.tryParse(parts[1]) : null;
            // `TempoRange` asserts the same thing with an `ArgumentError`, and
            // this parser's contract is `FormatException` naming the line —
            // so the ordering is checked here rather than left to escape the
            // parser as a stack trace.
            if (low == null || high == null || low < 1 || low > high) {
              throw FormatException(
                'line ${i + 1}: tempoRange needs two tempos above zero, '
                'low first',
              );
            }
            tempoRange = TempoRange(low, high);
          case 'beatsperbar':
            final beats = int.tryParse(value);
            if (beats == null || beats < 1 || beats > 16) {
              throw FormatException('line ${i + 1}: beatsPerBar is not 1..16');
            }
            beatsPerBar = beats;
          case 'track':
            final index = int.tryParse(value);
            if (index == null || index < 0) {
              throw FormatException('line ${i + 1}: track is not an index');
            }
            track = index;
          case 'range':
            final parts = value.split(RegExp(r'\s+'));
            final low = parts.length == 2 ? int.tryParse(parts[0]) : null;
            final high = parts.length == 2 ? int.tryParse(parts[1]) : null;
            if (low == null || high == null || low >= high) {
              throw FormatException(
                'line ${i + 1}: range needs two MIDI pitches, low first',
              );
            }
            lowest = low;
            highest = high;
          default:
            throw FormatException('line ${i + 1}: unknown header "$key"');
        }
        continue;
      }
      for (final token in line.split(RegExp(r'\s+'))) {
        if (token.isEmpty) {
          continue;
        }
        final chord = ExtChordSymbol.tryParse(token);
        if (chord == null) {
          throw FormatException('line ${i + 1}: "$token" is not a chord');
        }
        chords.add(chord);
      }
    }

    if (name == null || name.isEmpty) {
      throw const FormatException('the annotation needs a "name:" header');
    }
    if (chords.isEmpty) {
      throw const FormatException('the annotation names no chords');
    }
    return ChordAnnotation(
      name: name,
      bars: chords,
      tags: tags,
      tempoRange: tempoRange,
      beatsPerBar: beatsPerBar,
      track: track,
      range: BassRange(lowest: lowest, highest: highest),
    );
  }
}
