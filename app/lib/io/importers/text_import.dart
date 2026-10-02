import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_structure.dart';

/// A chart typed as text, with anything that could not be read.
class ImportedText {
  /// Create a result.
  ImportedText({required this.song, required List<String> problems})
    : problems = List<String>.unmodifiable(problems);

  /// The tune.
  final Song song;

  /// Anything that could not be read, each naming its line.
  ///
  /// Parsing continues past a problem: a typo in bar 30 must not lose bars 1
  /// to 29 (`docs/rules/text-import.md` §4).
  final List<String> problems;
}

/// Reads the plain text lead sheet of §5.2 item 3.
///
/// Rules: `docs/rules/text-import.md`. The audience is one person with a
/// keyboard and a tune in their head, so it has to be faster than the editor
/// and readable when they come back to it.
abstract final class TextImporter {
  /// Parse a document.
  ///
  /// Throws [FormatException] only when there are no bars at all, which is not
  /// a lead sheet. Everything else is a problem on the result.
  static ImportedText parse(
    String source, {
    required String id,
    ChordTypeDatabase? database,
  }) {
    final types = database ?? Harmony.chordTypes;
    final problems = <String>[];

    final headers = <String, String>{};
    final bars = <_Bar>[];
    final sections = <int, String>{};
    final repeats = <_PendingRepeat>[];
    final endings = <_PendingEnding>[];

    var readingHeaders = true;
    _PendingEnding? openEnding;

    final lines = source.split('\n');
    final commentStart = RegExp(r'(^|\s)#');
    for (var index = 0; index < lines.length; index++) {
      // `#` starts a comment only at the start of a line or after
      // whitespace — never inside a chord token, or `| F#7 | B7 |` would
      // import as `| F` (§1).
      final comment = commentStart.firstMatch(lines[index]);
      final raw = comment == null
          ? lines[index]
          : lines[index].substring(0, comment.start);
      final line = raw.trim();
      final number = index + 1;

      if (line.isEmpty) {
        // A blank line ends the headers (§1).
        readingHeaders = false;
        continue;
      }

      if (readingHeaders) {
        final header = RegExp(r'^([A-Za-z]+)\s*:\s*(.*)$').firstMatch(line);
        if (header != null && !line.contains('|')) {
          headers[header.group(1)!.toLowerCase()] = header.group(2)!.trim();
          continue;
        }
        readingHeaders = false;
      }

      // A line ending in `:` with no bar lines is a section name (§1).
      if (line.endsWith(':') && !line.contains('|')) {
        if (sections.containsKey(bars.length)) {
          // Two section lines with no bars between them — `A:` then `B:` —
          // would overwrite each other silently.
          problems.add('line $number: a section is already named for this bar');
          continue;
        }
        sections[bars.length] = line.substring(0, line.length - 1).trim();
        continue;
      }

      _readChartLine(
        line: line,
        lineNumber: number,
        types: types,
        bars: bars,
        repeats: repeats,
        endings: endings,
        problems: problems,
        openEnding: () => openEnding,
        setOpenEnding: (value) => openEnding = value,
      );
    }

    if (bars.isEmpty) {
      throw const FormatException(
        'this document has no bars in it, so it is not a lead sheet',
      );
    }
    if (openEnding != null) {
      endings.add(openEnding!..endBar = bars.length - 1);
    }

    final meter = _meterOf(headers, problems) ?? TimeSignature.fourFour;
    var sheet = ChordLeadSheet.empty(
      barCount: bars.length,
      timeSignature: meter,
    );

    void add(LeadSheetItem item) {
      try {
        sheet = sheet.withItem(item);
      } on ArgumentError catch (error) {
        problems.add('${error.message}');
      }
    }

    for (final entry in sections.entries) {
      if (entry.key >= bars.length) {
        // A section line after the last bar names nothing. Reported rather
        // than dropped: the duplicate-section case a few lines up *is*
        // reported, and silence here meant a chart could lose its coda
        // marking with nothing said about it.
        problems.add(
          'the section "${entry.value}" comes after the last bar, so it was '
          'left out',
        );
        continue;
      }
      final section = Section(
        name: entry.value,
        startBar: entry.key,
        timeSignature: meter,
      );
      if (entry.key == 0) {
        if (entry.value == 'A') {
          continue; // The empty sheet's default section is already this.
        }
        // A section declared on the first chart line replaces the default
        // 'A' rather than duplicating bar 0, which the sheet refuses (§1).
        sheet = sheet.withoutWhere(
          (item) => item is CliSection && item.section.startBar == 0,
        );
      }
      add(CliSection(section));
    }
    for (final (index, bar) in bars.indexed) {
      for (final chord in bar.chordsAt(meter)) {
        add(CliChordSymbol(Position(index, chord.beat), chord.chord));
      }
    }
    for (final repeat in repeats) {
      add(
        CliRepeat(
          Position(repeat.bar),
          isStart: repeat.isStart,
          playCount: repeat.playCount,
        ),
      );
    }
    for (final ending in endings) {
      final barCount = ending.endBar - ending.startBar + 1;
      if (barCount < 1) {
        // A dangling marker: `|2.` with no bar written after it. The ending
        // closes at the last bar there is, which is before it starts, and
        // `CliEnding` rejects that with an `ArgumentError` — thrown here,
        // outside `add`'s catch, so it escaped `parse` and crashed the import
        // screen instead of being reported like every other bad line.
        problems.add(
          'the ending "${ending.passes.join(', ')}" names no bars, so it was '
          'left out',
        );
        continue;
      }
      add(
        CliEnding(Position(ending.startBar), ending.passes, barCount: barCount),
      );
    }

    // An empty `Title:` header leaves an empty string, not a null, so `??`
    // never fired and `Song` rejected it with an `ArgumentError` that escaped
    // `parse`. A chart with a blank title is untitled, which is not an error.
    final title = headers['title']?.trim();

    final song = Song(
      id: id,
      title: title == null || title.isEmpty ? 'Untitled' : title,
      composer: headers['composer'] ?? '',
      tempo: _tempoOf(headers, problems) ?? 120,
      key: _keyOf(headers, problems) ?? KeySignature.cMajor(),
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: defaultRhythmId),
    );
    return ImportedText(song: song, problems: problems);
  }

  /// One line of chart: bars between pipes, with the structure markers (§3).
  static void _readChartLine({
    required String line,
    required int lineNumber,
    required ChordTypeDatabase types,
    required List<_Bar> bars,
    required List<_PendingRepeat> repeats,
    required List<_PendingEnding> endings,
    required List<String> problems,
    required _PendingEnding? Function() openEnding,
    required void Function(_PendingEnding?) setOpenEnding,
  }) {
    if (!line.contains('|')) {
      problems.add('line $lineNumber: "$line" is neither a header nor bars');
      return;
    }

    // Find every bar line first, then take the text *between* them. Consuming
    // separators one at a time in a loop reads `| |` as two separators with
    // nothing between, which silently loses the empty bar — and an empty bar
    // is a real thing that sounds as the one before it (§2).
    //
    // Order in the alternation matters: `|:` and `:|` and `|1.` must be tried
    // before a bare `|`, or the bare one wins and eats their first character.
    final markers = RegExp(r'\|:|:\|(?:\s*[xX]\s*(\d+))?|\|\s*(\d+)\.|\|')
        .allMatches(line)
        .toList();

    void addBar(String text) {
      final trimmed = text.trim();
      if (trimmed == '%') {
        // Repeat the previous bar, chords and divisions and all (§2).
        bars.add(_Bar(bars.isEmpty ? const <String>[] : bars.last.tokens));
        return;
      }
      bars.add(
        _Bar(
          trimmed.isEmpty ? const <String>[] : trimmed.split(RegExp(r'\s+')),
        ),
      );
    }

    // Anything before the first bar line is a bar: the leading pipe is
    // optional, so `C | Am` is two bars.
    final lead = line.substring(0, markers.first.start).trim();
    if (lead.isNotEmpty) {
      addBar(lead);
    }

    for (var i = 0; i < markers.length; i++) {
      final marker = markers[i];
      final text = marker.group(0)!;

      if (text == '|:') {
        repeats.add(_PendingRepeat(bars.length, isStart: true));
      } else if (text.startsWith(':|')) {
        final times = int.tryParse(marker.group(1) ?? '') ?? 2;
        repeats.add(
          _PendingRepeat(
            bars.isEmpty ? 0 : bars.length - 1,
            isStart: false,
            playCount: times < 1 ? 2 : times,
          ),
        );
        final previous = openEnding();
        if (previous != null) {
          endings.add(previous..endBar = bars.length - 1);
          setOpenEnding(null);
        }
      } else if (marker.group(2) != null) {
        final pass = int.parse(marker.group(2)!);
        final previous = openEnding();
        if (previous != null) {
          endings.add(previous..endBar = bars.length - 1);
        }
        setOpenEnding(_PendingEnding(bars.length, <int>{pass}));
      }

      // The bar this marker opens runs to the next marker, or to end of line.
      final from = marker.end;
      final to = i + 1 < markers.length ? markers[i + 1].start : line.length;
      final between = line.substring(from, to);
      // A trailing pipe closes the last bar rather than opening an empty one.
      if (i + 1 < markers.length || between.trim().isNotEmpty) {
        addBar(between);
      }
    }

    // Resolve the tokens now, so a bad chord names its line.
    for (final bar in bars.where((bar) => !bar.resolved)) {
      bar.resolve(types, lineNumber, problems);
    }
  }

  static TimeSignature? _meterOf(
    Map<String, String> headers,
    List<String> problems,
  ) {
    final text = headers['time'] ?? headers['meter'];
    if (text == null) {
      return null;
    }
    // Through `tryParse`, which validates. The constructor is `const` and
    // guards with `assert`, which is stripped in a release build — so
    // constructing from a user's file directly would accept `4/5` in the
    // shipping app and throw only in a test.
    final meter = TimeSignature.tryParse(text);
    if (meter == null) {
      problems.add('"$text" is not a time signature');
    }
    return meter;
  }

  static int? _tempoOf(Map<String, String> headers, List<String> problems) {
    final text = headers['tempo'];
    if (text == null) {
      return null;
    }
    final beats = int.tryParse(text);
    if (beats == null || beats < minTempo || beats > maxTempo) {
      problems.add('"$text" is not a tempo between $minTempo and $maxTempo');
      return null;
    }
    return beats;
  }

  static KeySignature? _keyOf(
    Map<String, String> headers,
    List<String> problems,
  ) {
    final text = headers['key'];
    if (text == null) {
      return null;
    }
    final key = KeySignature.tryParse(text);
    if (key == null) {
      problems.add('"$text" is not a key');
    }
    return key;
  }
}

/// One bar's chords, before and after they are parsed.
class _Bar {
  _Bar(this.tokens);

  final List<String> tokens;
  final List<ExtChordSymbol> chords = <ExtChordSymbol>[];

  /// Beats each chord holds, once the meter is known.
  bool resolved = false;

  /// Parse the tokens, reporting anything that is not a chord.
  ///
  /// `/` is a beat of the chord before it, which is what a player writes when
  /// they want the beats visible (§2).
  void resolve(ChordTypeDatabase types, int lineNumber, List<String> problems) {
    resolved = true;
    for (final token in tokens) {
      if (token == '/') {
        if (chords.isEmpty) {
          problems.add('line $lineNumber: a bar starts with "/"');
          continue;
        }
        chords.add(chords.last);
        continue;
      }
      final chord = ExtChordSymbol.tryParse(token, database: types);
      if (chord == null) {
        problems.add('line $lineNumber: "$token" is not a chord');
        continue;
      }
      chords.add(chord);
    }
  }

  /// The chords with the beat each falls on, dividing the bar evenly (§2).
  ///
  /// A repeated chord — from `/` — is not written again: the model holds a
  /// chord where it *changes*, and re-stating it would put two identical
  /// symbols on one bar.
  List<({ExtChordSymbol chord, double beat})> chordsAt(TimeSignature meter) {
    if (chords.isEmpty) {
      return const <({ExtChordSymbol chord, double beat})>[];
    }
    final share = meter.upper / chords.length;
    final out = <({ExtChordSymbol chord, double beat})>[];
    for (final (index, chord) in chords.indexed) {
      if (index > 0 && chord == chords[index - 1]) {
        continue;
      }
      out.add((chord: chord, beat: index * share));
    }
    return out;
  }
}

class _PendingRepeat {
  _PendingRepeat(this.bar, {required this.isStart, this.playCount = 2});
  final int bar;
  final bool isStart;
  final int playCount;
}

class _PendingEnding {
  _PendingEnding(this.startBar, this.passes);
  final int startBar;
  final Set<int> passes;
  int endBar = 0;
}
