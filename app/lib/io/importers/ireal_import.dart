import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_structure.dart';

/// Something the importer could not read, reported with where it was.
///
/// An import that quietly turns `C^9#11` into `C` is worse than one that says
/// it could not read bar 12.
class ImportProblem {
  /// Create a problem report.
  const ImportProblem(this.message, {this.bar, this.songTitle});

  /// What is wrong, in words.
  final String message;

  /// The one-based bar it is in, if it is about one.
  final int? bar;

  /// The song it is in, if the file held several.
  final String? songTitle;

  @override
  String toString() => <String>[
    if (songTitle != null) '"$songTitle"',
    if (bar != null) 'bar $bar',
    message,
  ].join(': ');
}

/// One chart read out of an iReal Pro URL.
class ImportedSong {
  /// Create an imported song.
  ImportedSong({
    required this.title,
    required this.composer,
    required this.style,
    required this.keyName,
    required this.leadSheet,
    required List<ImportProblem> problems,
    this.tempo,
    this.repeats,
  }) : problems = List<ImportProblem>.unmodifiable(problems);

  /// The tune's name.
  final String title;

  /// Who wrote it, with the surname put back after the forename.
  final String composer;

  /// The iReal style name, kept in `meta` so a generator can use it later.
  final String style;

  /// The key as iReal wrote it.
  final String keyName;

  /// The chart.
  final ChordLeadSheet leadSheet;

  /// Everything the importer could not read.
  final List<ImportProblem> problems;

  /// Tempo, if the export carried one.
  final int? tempo;

  /// How many times iReal was set to play the form.
  final int? repeats;

  /// Whether the chart read cleanly.
  bool get isClean => problems.isEmpty;

  /// Turn this into a song, ready for the library.
  Song toSong(String id, {String rhythmId = defaultRhythmId}) {
    final key = KeySignature.tryParse(keyName) ?? KeySignature.cMajor();
    return Song(
      id: id,
      title: title,
      composer: composer,
      leadSheet: leadSheet,
      structure: SongStructure.fromLeadSheet(leadSheet, rhythmId: rhythmId),
      tempo: (tempo ?? 120).clamp(minTempo, maxTempo),
      key: key,
      meta: <String, String>{
        'source': 'ireal',
        if (style.isNotEmpty) 'irealStyle': style,
        if (repeats != null) 'irealRepeats': '$repeats',
      },
    );
  }

  @override
  String toString() => '$title (${leadSheet.barCount} bars)';
}

/// What a whole iReal URL held.
class ImportedPlaylist {
  /// Create an import result.
  ImportedPlaylist({
    required List<ImportedSong> songs,
    required this.name,
    required List<ImportProblem> problems,
  }) : songs = List<ImportedSong>.unmodifiable(songs),
       problems = List<ImportProblem>.unmodifiable(problems);

  /// The charts, in the order the file held them.
  final List<ImportedSong> songs;

  /// The playlist's name, if the URL named one.
  final String? name;

  /// Problems that belong to the file rather than to one song.
  final List<ImportProblem> problems;

  /// Whether everything read cleanly.
  bool get isClean => problems.isEmpty && songs.every((song) => song.isClean);
}

/// Thrown when a URL is not an iReal Pro URL at all.
class NotAnIRealUrl implements Exception {
  /// Create the exception.
  const NotAnIRealUrl(this.reason);

  /// Why it was refused.
  final String reason;

  @override
  String toString() => 'Not an iReal Pro URL: $reason';
}

/// Thrown for `irealb://`, whose body is scrambled.
///
/// See `docs/rules/ireal-format.md` §7: the algorithm is published in four
/// implementations, none of which is in the local reference tree, and guessing
/// at it would produce charts that read plausibly and are the wrong tune.
class IRealScramblingNotSupported implements Exception {
  /// Create the exception.
  const IRealScramblingNotSupported();

  @override
  String toString() =>
      'This is an irealb:// URL, whose chord data is scrambled. Bandstand reads '
      'irealbook:// URLs. See docs/rules/ireal-format.md §7.';
}

/// Reads iReal Pro charts (§5.2).
///
/// Rules: `docs/rules/ireal-format.md`.
abstract final class IRealImporter {
  /// The scheme this importer reads.
  static const String plainScheme = 'irealbook://';

  /// The scheme whose body is scrambled.
  static const String scrambledScheme = 'irealb://';

  /// Whether [text] looks like an iReal Pro URL of either kind.
  static bool looksLikeIReal(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith(plainScheme) ||
        trimmed.startsWith(scrambledScheme);
  }

  /// Read every chart in an iReal Pro URL.
  ///
  /// Throws [NotAnIRealUrl] if it is not one, and
  /// [IRealScramblingNotSupported] for `irealb://`.
  static ImportedPlaylist parseUrl(String url, {ChordTypeDatabase? database}) {
    final trimmed = url.trim();
    if (trimmed.startsWith(scrambledScheme)) {
      throw const IRealScramblingNotSupported();
    }
    if (!trimmed.startsWith(plainScheme)) {
      throw const NotAnIRealUrl('it does not start with irealbook://');
    }

    final String body;
    try {
      body = Uri.decodeComponent(
        trimmed.substring(plainScheme.length).replaceAll('+', ' '),
      );
      // A malformed %-escape throws ArgumentError in the SDK; either way it
      // is not an iReal URL.
    } on ArgumentError {
      throw const NotAnIRealUrl('its percent-escapes are malformed');
    } on FormatException {
      throw const NotAnIRealUrl('its percent-escapes are malformed');
    }
    final chunks = body.split('===');
    final songs = <ImportedSong>[];
    final problems = <ImportProblem>[];
    String? playlistName;

    for (final chunk in chunks) {
      if (chunk.trim().isEmpty) {
        continue;
      }
      // A trailing chunk with no fields of its own names the playlist.
      if (!chunk.contains('=')) {
        playlistName = chunk.trim();
        continue;
      }
      try {
        songs.add(parseSong(chunk, database: database));
      } on FormatException catch (error) {
        problems.add(ImportProblem(error.message));
      }
    }

    if (songs.isEmpty && problems.isEmpty) {
      problems.add(const ImportProblem('the URL holds no charts'));
    }
    return ImportedPlaylist(
      songs: songs,
      name: playlistName,
      problems: problems,
    );
  }

  /// Read one chart from its `=`-separated fields.
  ///
  /// Throws [FormatException] if the chunk has too few fields to be a chart.
  static ImportedSong parseSong(String chunk, {ChordTypeDatabase? database}) {
    final fields = chunk.split('=');
    if (fields.length < 6) {
      throw FormatException(
        'a chart needs at least six fields, this has ${fields.length}',
        chunk,
      );
    }

    final title = fields[0].trim();
    final composer = _swapSurname(fields[1].trim());
    final style = fields[2].trim();
    final keyName = fields[3].trim();
    final chordString = fields[5];

    final problems = <ImportProblem>[];

    // Trailing metadata: the style again, then tempo, then repeats. Exports
    // disagree about how much of it they write, so the tail is read from the
    // end — a partial export must not misalign tempo and repeats.
    int? tempo;
    int? repeats;
    final tail = fields.sublist(6).map((field) => field.trim()).toList();
    if (tail.isNotEmpty && tail.first == style) {
      // The style repeated ahead of the numbers is not one of them.
      tail.removeAt(0);
    }
    if (tail.isNotEmpty) {
      final parsed = int.tryParse(tail.first);
      if (parsed == null) {
        problems.add(
          ImportProblem(
            '"${tail.first}" is not a tempo',
            songTitle: title.isEmpty ? null : title,
          ),
        );
      } else {
        tempo = parsed;
      }
      if (tail.length > 1) {
        repeats = int.tryParse(tail[1]);
      }
    }
    final sheet = parseChordString(
      chordString,
      problems: problems,
      songTitle: title.isEmpty ? null : title,
      database: database,
    );

    return ImportedSong(
      title: title.isEmpty ? 'Untitled' : title,
      composer: composer,
      style: style,
      keyName: keyName,
      leadSheet: sheet,
      problems: problems,
      tempo: tempo,
      repeats: repeats,
    );
  }

  /// iReal stores composers surname first.
  ///
  /// Two words are swapped; one, or three or more, is left alone — "Ellington"
  /// and "Ray Noble Trio" are both already right.
  static String _swapSurname(String name) {
    final words = name.split(RegExp(r'\s+'))
      ..removeWhere((word) => word.isEmpty);
    return words.length == 2 ? '${words[1]} ${words[0]}' : name;
  }

  /// Read a chord string into a chart.
  ///
  /// The grammar is in `docs/rules/ireal-format.md` §3.
  static ChordLeadSheet parseChordString(
    String source, {
    required List<ImportProblem> problems,
    String? songTitle,
    ChordTypeDatabase? database,
  }) => _ChordStringReader(
    source: source,
    problems: problems,
    songTitle: songTitle,
    database: database,
  ).read();
}

/// One bar being built.
class _Bar {
  final List<ExtChordSymbol> chords = <ExtChordSymbol>[];

  /// How many beats' worth of the bar each chord takes, in shares.
  ///
  /// iReal does not record where in a bar a chord falls, only how the bar is
  /// divided: `C p Dm p` is two chords of two beats, not four of one
  /// (`docs/rules/ireal-format.md` §5).
  final List<int> shares = <int>[];
  final List<String> annotations = <String>[];
  bool repeatStart = false;
  bool repeatEnd = false;
  bool sectionStart = false;
  String? sectionName;
  TimeSignature? timeSignature;
  int? endingNumber;
  final List<NavigationMark> marks = <NavigationMark>[];

  /// Whether a `p` held a chord through this bar without writing one.
  bool held = false;

  /// `p` units consumed at the head of the bar, before its first chord: the
  /// entering chord starts over these, not at beat 0.
  int leadingHolds = 0;

  /// Whether anything belonging to a *finished* bar has been read.
  ///
  /// A section marker, an opening repeat, a meter and an ending number are
  /// **prefixes**: they describe the bar that is about to start. A bar line
  /// straight after one must not close a bar, or `*B|F |` invents an empty bar
  /// for the section to sit in.
  bool get hasContent =>
      chords.isNotEmpty ||
      annotations.isNotEmpty ||
      marks.isNotEmpty ||
      repeatEnd ||
      held;

  bool get hasPrefix =>
      repeatStart ||
      sectionStart ||
      timeSignature != null ||
      endingNumber != null;
}

class _ChordStringReader {
  _ChordStringReader({
    required this.source,
    required this.problems,
    required this.songTitle,
    required this.database,
  });

  final String source;
  final List<ImportProblem> problems;
  final String? songTitle;
  final ChordTypeDatabase? database;

  final List<_Bar> _bars = <_Bar>[];
  _Bar _current = _Bar();
  int _codaMarksSeen = 0;
  bool _previousTokenWasPipe = false;
  final Set<String> _usedSectionNames = <String>{};

  ChordLeadSheet read() {
    var i = 0;
    while (i < source.length) {
      final rest = source.substring(i);

      // Fillers and separators first, so nothing else has to know about them.
      if (rest.startsWith('XyQ')) {
        i += 3;
        continue;
      }
      final character = source[i];
      if (character == ' ' || character == ',' || character == 'Y') {
        i++;
        continue;
      }

      if (character == '<') {
        final end = source.indexOf('>', i);
        if (end == -1) {
          _report('an annotation is never closed');
          break;
        }
        final text = source.substring(i + 1, end).trim();
        if (text.isNotEmpty) {
          _current.annotations.add(text);
        }
        _previousTokenWasPipe = false;
        i = end + 1;
        continue;
      }

      if (character == '(') {
        final end = source.indexOf(')', i);
        if (end == -1) {
          _report('an alternate chord is never closed');
          break;
        }
        final text = source.substring(i + 1, end).trim();
        if (text.isNotEmpty) {
          _current.annotations.add('($text)');
        }
        _previousTokenWasPipe = false;
        i = end + 1;
        continue;
      }

      if (character == '*' && i + 1 < source.length) {
        _startSection(source[i + 1]);
        _previousTokenWasPipe = false;
        i += 2;
        continue;
      }

      if (character == 'T' && i + 2 < source.length) {
        final signature = _readTimeSignature(source.substring(i + 1, i + 3));
        if (signature != null) {
          _current.timeSignature = signature;
          _previousTokenWasPipe = false;
          i += 3;
          continue;
        }
      }

      if (character == 'N' && i + 1 < source.length) {
        final number = int.tryParse(source[i + 1]);
        if (number != null && number > 0) {
          _current.endingNumber = number;
          _previousTokenWasPipe = false;
          i += 2;
          continue;
        }
      }

      switch (character) {
        case '|':
          // Two bar lines with nothing between them are an empty bar, which a
          // chart uses for a break. Every other kind of barline clears the
          // flag, so `}|` and `x |` do not invent one.
          if (!_current.hasContent &&
              _previousTokenWasPipe &&
              _bars.isNotEmpty) {
            _emitEmptyBar();
          } else {
            _endBar();
          }
          _previousTokenWasPipe = true;
          i++;
          continue;
        case '[':
          _endBar();
          _previousTokenWasPipe = false;
          i++;
          continue;
        case ']':
          _endBar();
          _previousTokenWasPipe = false;
          i++;
          continue;
        case '{':
          _endBar();
          _current.repeatStart = true;
          _previousTokenWasPipe = false;
          i++;
          continue;
        case '}':
          _current.repeatEnd = true;
          _endBar();
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 'Z':
        case 'U':
          _endBar();
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 'S':
          _current.marks.add(NavigationMark.segno);
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 'Q':
          // The first Q is "To Coda"; the second is where it goes.
          _current.marks.add(
            _codaMarksSeen == 0 ? NavigationMark.toCoda : NavigationMark.coda,
          );
          _codaMarksSeen++;
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 'x':
          _repeatPreviousBars(1);
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 'r':
          _repeatPreviousBars(2);
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 'p':
          _hold();
          _previousTokenWasPipe = false;
          i++;
          continue;
        case 's':
        case 'l':
        case 'f':
          // Chord size and fermata are drawing hints iReal carries; the chart
          // does not change because of them.
          i++;
          continue;
        case 'n':
          _current.chords.add(ExtChordSymbol.noChord(database: database));
          _current.shares.add(1);
          _previousTokenWasPipe = false;
          i++;
          continue;
      }

      final chordLength = _readChord(rest);
      _previousTokenWasPipe = false;
      if (chordLength == 0) {
        _report('cannot read "${_snippet(rest)}"');
        i++;
        continue;
      }
      i += chordLength;
    }

    _endBar();
    return _build();
  }

  /// Read a chord symbol from the start of [rest], returning its length.
  ///
  /// Chord tokens are not delimited, so the longest prefix that parses wins —
  /// which is how `C^7` is told from `C` followed by junk.
  int _readChord(String rest) {
    var end = 0;
    while (end < rest.length && !_isDelimiter(rest[end])) {
      end++;
    }
    for (var length = end; length > 0; length--) {
      final token = rest.substring(0, length);
      final chord = ExtChordSymbol.tryParse(token, database: database);
      if (chord != null) {
        _current.chords.add(chord);
        _current.shares.add(1);
        return length;
      }
    }
    return 0;
  }

  static bool _isDelimiter(String character) =>
      character == '|' ||
      character == '[' ||
      character == ']' ||
      character == '{' ||
      character == '}' ||
      character == ',' ||
      character == ' ' ||
      character == '<' ||
      character == '(' ||
      character == '*';

  void _startSection(String letter) {
    var name = letter.toUpperCase();
    if (letter == 'i') {
      name = 'Intro';
    } else if (letter == 'v') {
      name = 'Verse';
    }
    // A lead sheet needs unique section names; a chart that reuses a letter
    // means the same section, which the arrangement expresses by listing it
    // twice rather than by naming it twice.
    var unique = name;
    var suffix = 2;
    while (_usedSectionNames.contains(unique)) {
      unique = '$name$suffix';
      suffix++;
    }
    _usedSectionNames.add(unique);
    _current
      ..sectionStart = true
      ..sectionName = unique;
  }

  static TimeSignature? _readTimeSignature(String digits) {
    // iReal writes twelve-eight as `T12`, spending both digits on the twelve.
    if (digits == '12') {
      return const TimeSignature(12, 8);
    }
    final upper = int.tryParse(digits[0]);
    final lower = int.tryParse(digits[1]);
    if (upper == null || lower == null) {
      return null;
    }
    return TimeSignature.tryParse('$upper/$lower');
  }

  /// [name], or [name] with a suffix if the chart already used it — the same
  /// deal as `_startSection`, for sections synthesized from a meter change.
  String _uniqueSectionName(String name) {
    var unique = name;
    var suffix = 2;
    while (_usedSectionNames.contains(unique)) {
      unique = '$name ($suffix)';
      suffix++;
    }
    _usedSectionNames.add(unique);
    return unique;
  }

  /// `p` holds the chord before it for another share of the bar.
  ///
  /// At the head of a bar it means the previous bar's chord is still sounding,
  /// which a chart expresses by writing nothing — so the bar is left empty and
  /// `ChordLeadSheet.chordAt` carries the chord across on its own.
  void _hold() {
    _current.held = true;
    if (_current.shares.isNotEmpty) {
      _current.shares[_current.shares.length - 1]++;
    } else {
      // A hold at the head of a bar that also holds a chord: the hold's
      // share must still be taken before the chord enters, or the chord
      // lands at beat 0 and swallows the whole bar (L-I3).
      _current.leadingHolds++;
    }
  }

  void _repeatPreviousBars(int count) {
    _endBar();
    if (_bars.length < count) {
      _report('a bar repeat with nothing before it');
      return;
    }
    for (final source in _bars.sublist(_bars.length - count)) {
      final copy = _Bar()
        ..chords.addAll(source.chords)
        ..shares.addAll(source.shares)
        ..leadingHolds = source.leadingHolds;
      _bars.add(copy);
    }
  }

  /// Close the current bar, if it holds anything.
  ///
  /// A bar carrying only prefixes stays open, so the prefixes land on the bar
  /// they describe.
  void _endBar() {
    if (!_current.hasContent) {
      return;
    }
    _bars.add(_current);
    _current = _Bar();
  }

  /// Emit a bar with nothing in it: `| |` in the source.
  void _emitEmptyBar() {
    _bars.add(_current);
    _current = _Bar();
  }

  void _report(String message) => problems.add(
    ImportProblem(message, bar: _bars.length + 1, songTitle: songTitle),
  );

  static String _snippet(String rest) =>
      rest.length <= 8 ? rest : '${rest.substring(0, 8)}…';

  ChordLeadSheet _build() {
    if (_bars.isEmpty) {
      _report('the chart has no bars');
      return ChordLeadSheet.empty(barCount: 1);
    }

    final items = <LeadSheetItem>[];
    var signature = TimeSignature.fourFour;

    for (var index = 0; index < _bars.length; index++) {
      final bar = _bars[index];
      // A meter that changes mid-chart with no `*` section of its own still
      // needs a section to live in: the sheet reads a bar's meter from the
      // section governing it, so without one the change is written but never
      // applied (L-I4). The MusicXML importer does the same at
      // `_startMeterSection`; the synthesized section is named for the
      // meter, because there is no rehearsal letter to borrow.
      final changesMeter =
          bar.timeSignature != null && bar.timeSignature != signature;
      if (bar.timeSignature != null) {
        signature = bar.timeSignature!;
      }
      if (bar.sectionStart) {
        items.add(
          CliSection(
            Section(
              name: bar.sectionName!,
              startBar: index,
              timeSignature: signature,
            ),
          ),
        );
      } else if (index == 0) {
        _usedSectionNames.add('A');
        items.add(
          CliSection(Section(name: 'A', startBar: 0, timeSignature: signature)),
        );
      } else if (changesMeter) {
        items.add(
          CliSection(
            Section(
              name: _uniqueSectionName('$signature'),
              startBar: index,
              timeSignature: signature,
            ),
          ),
        );
      }

      if (bar.repeatStart) {
        items.add(CliRepeat(Position(index), isStart: true));
      }
      if (bar.repeatEnd) {
        items.add(CliRepeat(Position(index), isStart: false));
      }
      for (final mark in bar.marks) {
        items.add(CliNavigation(Position(index), mark));
      }
      for (final annotation in bar.annotations) {
        items.add(CliAnnotation(Position(index), annotation));
      }
      items.addAll(_chordItems(bar, index, signature));
    }

    // The first bar always gets a section above — `index == 0` — so there is
    // no longer a chart-left-unnamed case to patch up here.
    items.addAll(_endingItems());

    return ChordLeadSheet(barCount: _bars.length, items: items);
  }

  /// Place a bar's chords by their shares (`docs/rules/ireal-format.md` §5).
  List<LeadSheetItem> _chordItems(
    _Bar bar,
    int index,
    TimeSignature signature,
  ) {
    if (bar.chords.isEmpty) {
      return const <LeadSheetItem>[];
    }
    final total =
        bar.shares.fold(0, (sum, share) => sum + share) + bar.leadingHolds;
    if (total == 0) {
      return const <LeadSheetItem>[];
    }
    final beats = signature.upper;
    final items = <LeadSheetItem>[];
    // The leading holds count towards the bar's shares: the first chord
    // enters over them (L-I3).
    var taken = bar.leadingHolds;
    for (var i = 0; i < bar.chords.length; i++) {
      items.add(
        CliChordSymbol(
          Position(index, _roundToHalf(beats * taken / total)),
          bar.chords[i],
        ),
      );
      taken += bar.shares[i];
    }
    return items;
  }

  static double _roundToHalf(double beat) => (beat * 2).round() / 2;

  /// Endings run to the next ending, the closing repeat, or the end (§6).
  List<LeadSheetItem> _endingItems() {
    final starts = <int, int>{};
    for (var index = 0; index < _bars.length; index++) {
      final number = _bars[index].endingNumber;
      if (number != null) {
        starts[index] = number;
      }
    }
    if (starts.isEmpty) {
      return const <LeadSheetItem>[];
    }

    final barsWithEndings = starts.keys.toList()..sort();
    final items = <LeadSheetItem>[];
    for (var i = 0; i < barsWithEndings.length; i++) {
      final start = barsWithEndings[i];
      var end = i + 1 < barsWithEndings.length
          ? barsWithEndings[i + 1]
          : _bars.length;
      for (var bar = start; bar < end; bar++) {
        if (_bars[bar].repeatEnd) {
          end = bar + 1;
          break;
        }
      }
      items.add(
        CliEnding(Position(start), <int>{
          starts[start]!,
        }, barCount: (end - start).clamp(1, _bars.length - start)),
      );
    }
    return items;
  }
}
