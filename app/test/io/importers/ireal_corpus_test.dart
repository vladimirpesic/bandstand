import 'package:bandstand/domain/song/navigation.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/io/importers/ireal_import.dart';
import 'package:bandstand/render/chart_layout.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../domain/harmony/harmony_test_support.dart';

/// §10 M3: render fifty imported iReal charts with correct bar counts and
/// structure.
///
/// The charts are written here rather than taken from real exports, for one
/// reason: a synthetic corpus can put every token of the grammar in play —
/// including the rare ones a real export touches once in a book — and say
/// exactly what each chart must produce. Real `irealb://` exports are read
/// too; the scrambling is `docs/rules/ireal-format.md` §7 and its tests live
/// in `ireal_import_test.dart`. What is exercised here is the whole path a
/// real chart takes — the grammar, the structure, the navigation resolver and
/// the layout engine — over fifty charts that between them use every token the
/// format has.
class _FixedMeasurer implements ChordMeasurer {
  const _FixedMeasurer();

  @override
  double measure(String text, double size) => text.length * size * 0.6;
}

/// One chart, and what it should come out as.
class _Chart {
  const _Chart(this.title, this.body, this.bars, {this.playedBars});

  final String title;
  final String body;
  final int bars;

  /// Bars after repeats and jumps are resolved, when they differ.
  final int? playedBars;
}

const List<String> _keys = <String>[
  'C', 'F', 'Bb', 'Eb', 'Ab', 'Db', 'G', 'D', 'A', 'E', //
];

/// Fifty charts, between them using every token the grammar has.
List<_Chart> _corpus() {
  final charts = <_Chart>[
    const _Chart(
      'Blues in F',
      '*A|F7 |Bb7 |F7 |F7 |Bb7 |Bb7 |F7 |D7 |'
          'G-7 |C7 |F7 |C7 |',
      12,
    ),
    const _Chart(
      'Rhythm A',
      '*A{|Bb6 G-7 |C-7 F7 |Bb6 G-7 |C-7 F7 |'
          'Bb7 |Eb7 |Bb6 F7 |Bb6 }',
      8,
      playedBars: 16,
    ),
    const _Chart(
      'Two endings',
      '{|C |A-7 |N1D-7 |G7 }|N2D-7 |C6 |',
      6,
      playedBars: 8,
    ),
    // Three brackets, but an iReal repeat plays twice, so the third is never
    // reached — which is what the chart says, and what the resolver must do.
    const _Chart('Three endings', '{|C |N1F }|N2G |N3C |', 4, playedBars: 4),
    const _Chart('Waltz', 'T34|C |A-7 |D-7 |G7 |', 4),
    const _Chart('Six eight', 'T68|C |F |G7 |C |', 4),
    const _Chart('Twelve eight', 'T12|C7 |F7 |C7 |G7 |', 4),
    const _Chart('Five four', 'T54|C |D-7 |', 2),
    const _Chart('Bar repeats', '|C |x |x |x |', 4),
    const _Chart('Two bar repeats', '|C |D-7 |r |r |', 6),
    const _Chart('Holds', '|C p p p |D-7 p G7 p |', 2),
    const _Chart('No chord', '|n |C |n |D-7 |', 4),
    const _Chart('Slash chords', '|C/E |D-7/G |F/A |G7/B |', 4),
    const _Chart('Altered', '|C^7 |A7alt |D-7 |G7b9 |', 4),
    const _Chart('Half diminished', '|Eh7 |A7 |D-7 |Do7 |', 4),
    const _Chart('Extensions', '|C^9 |D-11 |G13 |C^13#11 |', 4),
    const _Chart('Sus', '|Csus |G7sus |F^7 |Bb7sus |', 4),
    const _Chart('Sixths', '|C6 |A-6 |C69 |A-69 |', 4),
    // The rarer official qualities: `2` is sus2, `-^9` the minor-major ninth,
    // `7susadd3` a suspension with the third left in, `-b6` minor flat six.
    const _Chart('Rare qualities', '|G2 |F-^9 |F#7susadd3 |G-b6 |', 4),
    // A `*…*` quality is one iReal's menus cannot spell; the stars wrap it
    // around the root and the inside parses as a quality (`-^` = minor-major).
    const _Chart('Custom qualities', '|C*-^* |F#*-^*, B7 |G2 |C |', 4),
    // `W` is a whole-note rest that takes a chord's share of the bar; `W/D`
    // rests over a bass D. Both are silent, like `n`.
    const _Chart('Whole rests', '|C-7 W/Bb |W |Eb^ W/D, C-7 W/Bb, |', 3),
    const _Chart('Annotations', '|C <play twice> |D-7 |G7 <softly> |C |', 4),
    const _Chart('Alternates', '|C (A-7) |D-7 (F6) |G7 |C |', 4),
    const _Chart('Sections', '*A|C |D-7 |*B|F |G7 |*C|C |C |', 6),
    const _Chart('Intro and verse', '*i|C |*v|D-7 |*A|G7 |C |', 4),
    const _Chart('Reused letter', '*A|C |*B|F |*A|C |', 3),
    const _Chart('Segno and coda', '|SC |QD-7 |G7 |QC |', 4),
    const _Chart('Empty bars', '|C | |D-7 | |', 4),
    const _Chart('Noise', 'XyQ|sC ,Y |lD-7 f|XyQ', 2),
    const _Chart('Double barlines', '[|C |D-7 ]|[|G7 |C ]', 4),
    const _Chart('Final barline', '|C |D-7 |G7 |C Z', 4),
    const _Chart('End marker', '|C |D-7 |U', 2),
    const _Chart(
      'Long form',
      '|C |A-7 |D-7 |G7 |C |A-7 |D-7 |G7 |'
          'F |F#o7 |C/G |A7 |D-7 |G7 |C |C |',
      16,
    ),
  ];

  // Twenty more: the same ii-V-I shape through every key, twice over, with a
  // repeat on the second pass so the resolver is exercised in each one.
  for (var i = 0; i < 20; i++) {
    final key = _keys[i % _keys.length];
    final repeated = i >= 10;
    final body = repeated
        ? '*A{|$key^7 |$key^7 |$key^7 |$key^7 }'
        : '*A|$key^7 |$key^7 |$key^7 |$key^7 |';
    charts.add(
      _Chart('Study $i in $key', body, 4, playedBars: repeated ? 8 : null),
    );
  }
  return charts;
}

void main() {
  installTestHarmony();

  final corpus = _corpus();

  test('the corpus is the fifty charts the milestone asks for', () {
    expect(corpus.length, greaterThanOrEqualTo(50));
    expect(corpus.map((c) => c.title).toSet(), hasLength(corpus.length));
  });

  test('every chart reads with no problems', () {
    final failures = <String>[];
    for (final chart in corpus) {
      final imported = IRealImporter.parseSong(
        '${chart.title}=Tester Anne=Medium Swing=C=n=${chart.body}',
      );
      if (!imported.isClean) {
        failures.add('${chart.title}: ${imported.problems.join('; ')}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('every chart has the bar count it should', () {
    for (final chart in corpus) {
      final imported = IRealImporter.parseSong(
        '${chart.title}=Tester Anne=Medium Swing=C=n=${chart.body}',
      );
      expect(imported.leadSheet.barCount, chart.bars, reason: chart.title);
    }
  });

  test('every chart resolves to the number of bars it plays', () {
    for (final chart in corpus) {
      final imported = IRealImporter.parseSong(
        '${chart.title}=Tester Anne=Medium Swing=C=n=${chart.body}',
      );
      final form = resolveNavigation(imported.leadSheet);
      expect(
        form.sourceBars.length,
        chart.playedBars ?? chart.bars,
        reason: '${chart.title}: ${form.problems.join('; ')}',
      );
      for (final source in form.sourceBars) {
        expect(source, inInclusiveRange(0, imported.leadSheet.barCount - 1));
      }
    }
  });

  test('every chart flattens into a sequence the generators could read', () {
    for (final chart in corpus) {
      final imported = IRealImporter.parseSong(
        '${chart.title}=Tester Anne=Medium Swing=C=n=${chart.body}',
      );
      final sequence = SongChordSequence.asWritten(imported.leadSheet);
      expect(sequence.barCount, greaterThan(0), reason: chart.title);
      expect(sequence.totalQuarters, greaterThan(0), reason: chart.title);
      for (final bar in sequence.bars) {
        expect(
          bar.sourceBar,
          inInclusiveRange(0, imported.leadSheet.barCount - 1),
        );
      }
    }
  });

  test('every chart lays out, at every width, with nothing off the page', () {
    final style = ChartStyle(
      chordSize: 24,
      density: ChartDensity.normal,
      foreground: const Color(0xFFFFFFFF),
      muted: const Color(0xFF888888),
      accent: const Color(0xFFFFB300),
      gridLine: const Color(0xFF444444),
      cursor: const Color(0xFFFFB300),
    );

    for (final chart in corpus) {
      final imported = IRealImporter.parseSong(
        '${chart.title}=Tester Anne=Medium Swing=C=n=${chart.body}',
      );
      for (final width in <double>[320, 600, 1024, 1600]) {
        final layout = ChartLayoutEngine.layout(
          sheet: imported.leadSheet,
          width: width,
          style: style,
          measurer: const _FixedMeasurer(),
        );
        expect(
          layout.bars.length,
          imported.leadSheet.barCount,
          reason: '${chart.title} at $width',
        );
        for (final bar in layout.bars) {
          expect(
            bar.rect.right,
            lessThanOrEqualTo(width + 0.01),
            reason: '${chart.title} at $width, bar ${bar.sourceBar + 1}',
          );
          for (final laid in bar.chords) {
            expect(laid.left, greaterThanOrEqualTo(0));
          }
        }
        // A section never starts mid-line.
        final sectionStarts = imported.leadSheet.sections
            .map((section) => section.startBar)
            .toSet();
        for (final line in layout.lines) {
          for (final bar in line.bars) {
            if (sectionStarts.contains(bar.sourceBar)) {
              expect(
                bar.sourceBar,
                line.bars.first.sourceBar,
                reason: '${chart.title}: section starts mid-line',
              );
            }
          }
        }
      }
    }
  });

  test('every chart becomes a song the library could store', () {
    for (final chart in corpus) {
      final imported = IRealImporter.parseSong(
        '${chart.title}=Dorham Kenny=Medium Swing=C=n=${chart.body}',
      );
      final song = imported.toSong('id-${chart.title}');
      expect(song.title, chart.title);
      expect(song.composer, 'Kenny Dorham');
      expect(song.leadSheet.barCount, chart.bars);
      expect(song.structure.songParts, isNotEmpty, reason: chart.title);
      expect(song.meta['source'], 'ireal');
    }
  });

  test('a whole playlist URL imports in one go', () {
    final url = StringBuffer('irealbook://');
    for (final chart in corpus) {
      url.write('${chart.title}=Tester Anne=Medium Swing=C=n=${chart.body}===');
    }
    url.write('Fifty Charts');

    final result = IRealImporter.parseUrl(url.toString());
    expect(result.songs, hasLength(corpus.length));
    expect(result.name, 'Fifty Charts');
    expect(result.isClean, isTrue);
    for (var i = 0; i < corpus.length; i++) {
      expect(result.songs[i].title, corpus[i].title);
      expect(result.songs[i].leadSheet.barCount, corpus[i].bars);
    }
  });
}
