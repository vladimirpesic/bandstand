import 'package:bandstand/domain/harmony/chord_type.dart';
import 'package:bandstand/domain/harmony/ext_chord_symbol.dart';
import 'package:bandstand/domain/harmony/time_signature.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/song.dart';

/// Writes a chart as MusicXML 4.0, partwise.
///
/// The exporter half of the round-trip whose importer rule is
/// `docs/rules/musicxml-import.md` §7. This exports what the player **wrote**
/// — the written page, repeats and all. A repeat exports as a repeat, because
/// flattening it would lose the thing the format is best at.
abstract final class MusicXmlExporter {
  /// Divisions per quarter note.
  ///
  /// Bandstand's charts carry no melody, so the only durations written are
  /// whole-measure rests; a small number keeps the file readable.
  static const int divisions = 4;

  /// Write `song` as a MusicXML document.
  static String export(Song song) {
    final sheet = song.leadSheet;
    final out = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<!DOCTYPE score-partwise PUBLIC '
        '"-//Recordare//DTD MusicXML 4.0 Partwise//EN" '
        '"http://www.musicxml.org/dtds/partwise.dtd">',
      )
      ..writeln('<score-partwise version="4.0">')
      ..writeln('  <work>')
      ..writeln('    <work-title>${_escape(song.title)}</work-title>')
      ..writeln('  </work>');

    if (song.composer.trim().isNotEmpty) {
      out
        ..writeln('  <identification>')
        ..writeln(
          '    <creator type="composer">${_escape(song.composer)}</creator>',
        )
        ..writeln('  </identification>');
    }

    out
      ..writeln('  <part-list>')
      ..writeln('    <score-part id="P1">')
      ..writeln('      <part-name>Chords</part-name>')
      ..writeln('    </score-part>')
      ..writeln('  </part-list>')
      ..writeln('  <part id="P1">');

    final endingsClosingAt = _endingsClosingAt(sheet);
    for (var bar = 0; bar < sheet.barCount; bar++) {
      _measure(out, song, sheet, bar, endingsClosingAt);
    }

    out
      ..writeln('  </part>')
      ..writeln('</score-partwise>');
    return out.toString();
  }

  /// The ending brackets that close at each bar, resolved once: an ending
  /// knows where it starts, and the stop has to be written at the other end.
  static Map<int, List<CliEnding>> _endingsClosingAt(ChordLeadSheet sheet) {
    final byBar = <int, List<CliEnding>>{};
    for (final ending in sheet.items.whereType<CliEnding>()) {
      // Clamped to the last bar there is. An ending whose span overhangs the
      // end of the chart used to close at a bar the file never writes, so its
      // `<ending type="start">` had no matching stop and the document was not
      // valid MusicXML — readers either refuse it or bracket the rest of the
      // piece.
      final closes = ending.endBar - 1;
      final bar = closes >= sheet.barCount ? sheet.barCount - 1 : closes;
      (byBar[bar] ??= <CliEnding>[]).add(ending);
    }
    return byBar;
  }

  static void _measure(
    StringBuffer out,
    Song song,
    ChordLeadSheet sheet,
    int bar,
    Map<int, List<CliEnding>> endingsClosingAt,
  ) {
    final meter = sheet.timeSignatureAt(bar);
    final beats = meter.upper;
    out.writeln('    <measure number="${bar + 1}">');

    // What opens at this bar. MusicXML allows one leading barline, so a
    // repeat and an ending bracket that open together share it.
    final opensRepeat = sheet
        .itemsInBarOfType<CliRepeat>(bar)
        .any((repeat) => repeat.isStart);
    final openingEndings = sheet.itemsInBarOfType<CliEnding>(bar);
    if (opensRepeat || openingEndings.isNotEmpty) {
      out.writeln('      <barline location="left">');
      if (opensRepeat) {
        out.writeln('        <bar-style>heavy-light</bar-style>');
      }
      for (final ending in openingEndings) {
        out.writeln(
          '        <ending number="${ending.passNumbers.join(',')}" '
          'type="start">${ending.passNumbers.join(', ')}.</ending>',
        );
      }
      if (opensRepeat) {
        out.writeln('        <repeat direction="forward"/>');
      }
      out.writeln('      </barline>');
    }

    if (bar == 0) {
      out
        ..writeln('      <attributes>')
        ..writeln('        <divisions>$divisions</divisions>')
        ..writeln(
          '        <key><fifths>${song.key.sharpCount}</fifths>'
          '<mode>${song.key.mode.name}</mode></key>',
        )
        ..writeln(
          '        <time><beats>$beats</beats>'
          '<beat-type>${meter.lower}</beat-type></time>',
        )
        // Slash notation: a chart has no melody, so there is no clef anyone
        // reads. Notation software renders this as a rhythm staff, which is
        // what a chord chart is.
        ..writeln('        <clef><sign>percussion</sign></clef>')
        ..writeln('      </attributes>')
        ..writeln('      <sound tempo="${song.tempo}"/>');
    } else if (meter != sheet.timeSignatureAt(bar - 1)) {
      // The meter this section brings. Notation software reflows the bars
      // from here until the next `<time>`.
      out
        ..writeln('      <attributes>')
        ..writeln(
          '        <time><beats>$beats</beats>'
          '<beat-type>${meter.lower}</beat-type></time>',
        )
        ..writeln('      </attributes>');
    }

    final section = sheet.sections
        .where((candidate) => candidate.startBar == bar)
        .firstOrNull;

    if (section != null) {
      out
        ..writeln('      <direction placement="above">')
        ..writeln('        <direction-type>')
        ..writeln('          <rehearsal>${_escape(section.name)}</rehearsal>')
        ..writeln('        </direction-type>')
        ..writeln('      </direction>');
    }

    // Head-anchored marks only. A `Segno` or a `Coda` is a place you jump
    // *to*, so it belongs before the bar's music; `D.C.`, `D.S.`, `To Coda`
    // and `Fine` fire *after* the bar (`BarAnchor.tail`) and are written at
    // the end of the measure, below. Emitting all of them here put the jump a
    // whole bar early, and a reader following it dropped the bar it was
    // written on.
    for (final navigation in sheet.itemsInBarOfType<CliNavigation>(bar)) {
      if (navigation.anchor == BarAnchor.head) {
        _navigation(out, navigation.mark);
      }
    }

    for (final annotation in sheet.itemsInBarOfType<CliAnnotation>(bar)) {
      _annotation(out, annotation, meter);
    }

    for (final chord in sheet.itemsInBarOfType<CliChordSymbol>(bar)) {
      _harmony(out, chord.chord, chord.position.beat, meter);
    }

    // A whole-measure rest carries the bar — as many divisions as the bar's
    // own meter holds. Notation software draws the chord symbols above it
    // and the slashes beneath, which is the chart.
    final duration = (divisions * meter.barDurationInQuarters).round();
    out
      ..writeln('      <note>')
      ..writeln('        <rest measure="yes"/>')
      ..writeln('        <duration>${duration < 1 ? 1 : duration}</duration>')
      ..writeln('        <voice>1</voice>')
      ..writeln('      </note>');

    // The tail-anchored marks, after the bar's music: the jump happens once
    // the bar has been played.
    for (final navigation in sheet.itemsInBarOfType<CliNavigation>(bar)) {
      if (navigation.anchor == BarAnchor.tail) {
        _navigation(out, navigation.mark);
      }
    }

    // What closes at this bar: an ending's bracket and a backward repeat
    // share the one right barline, which is the only spelling notation
    // software accepts.
    final closingEndings = endingsClosingAt[bar] ?? const <CliEnding>[];
    final closingRepeats = sheet
        .itemsInBarOfType<CliRepeat>(bar)
        .where((repeat) => !repeat.isStart);
    if (closingEndings.isNotEmpty || closingRepeats.isNotEmpty) {
      out.writeln('      <barline location="right">');
      if (closingRepeats.isNotEmpty) {
        out.writeln('        <bar-style>light-heavy</bar-style>');
      }
      for (final ending in closingEndings) {
        out.writeln(
          '        <ending number="${ending.passNumbers.join(',')}" '
          'type="stop"/>',
        );
      }
      for (final repeat in closingRepeats) {
        out.writeln(
          '        <repeat direction="backward" times="${repeat.playCount}"/>',
        );
      }
      out.writeln('      </barline>');
    }

    out.writeln('    </measure>');
  }

  /// One chord symbol, spelled.
  ///
  /// Root and quality are spelled rather than reduced to pitch classes: B♭ is
  /// `<root-step>B</root-step><root-alter>-1</root-alter>`, and writing A♯
  /// would be wrong in exactly the way `docs/rules/pitch-and-spelling.md`
  /// exists to prevent.
  ///
  /// [beat] counts the bar's own written beats, and MusicXML `<offset>`
  /// counts divisions per quarter: in 6/8 the chord on the third written
  /// beat is one quarter into the bar, not two.
  static void _harmony(
    StringBuffer out,
    ExtChordSymbol chord,
    double beat,
    TimeSignature meter,
  ) {
    if (chord.isNoChord) {
      return;
    }
    final offset = (beat * meter.beatDurationInQuarters * divisions).round();
    out
      ..writeln('      <harmony>')
      ..writeln('        <root>')
      ..writeln(
        '          <root-step>${chord.root.natural.name.toUpperCase()}'
        '</root-step>',
      );
    if (chord.root.alteration != 0) {
      out.writeln(
        '          <root-alter>${chord.root.alteration}</root-alter>',
      );
    }
    out
      ..writeln('        </root>')
      // The `text` attribute carries the symbol as Bandstand writes it, so a
      // quality MusicXML has no `kind` for is never silently renamed.
      ..writeln(
        '        <kind text="${_escape(chord.type.name)}">'
        '${_kindOf(chord.type)}</kind>',
      );

    final bass = chord.bass;
    if (bass != null && bass.pitchClass != chord.root.pitchClass) {
      out
        ..writeln('        <bass>')
        ..writeln(
          '          <bass-step>${bass.natural.name.toUpperCase()}'
          '</bass-step>',
        );
      if (bass.alteration != 0) {
        out.writeln('          <bass-alter>${bass.alteration}</bass-alter>');
      }
      out.writeln('        </bass>');
    }

    if (offset != 0) {
      out.writeln('        <offset>$offset</offset>');
    }
    out.writeln('      </harmony>');
  }

  /// A navigation mark as a direction: the written label for the reader, and
  /// the `<sound>` attributes notation software follows when it plays the
  /// jump (`docs/rules/form-navigation.md` §5).
  static void _navigation(StringBuffer out, NavigationMark mark) {
    out
      ..writeln('      <direction placement="above">')
      ..writeln('        <direction-type>')
      ..writeln('          <words>${_escape(mark.label)}</words>');
    switch (mark) {
      case NavigationMark.segno:
        out.writeln('          <segno/>');
      case NavigationMark.coda:
        out.writeln('          <coda/>');
      case NavigationMark.toCoda ||
          NavigationMark.fine ||
          NavigationMark.daCapo ||
          NavigationMark.daCapoAlFine ||
          NavigationMark.daCapoAlCoda ||
          NavigationMark.dalSegno ||
          NavigationMark.dalSegnoAlFine ||
          NavigationMark.dalSegnoAlCoda:
        break;
    }
    out.writeln('        </direction-type>');
    final sound = switch (mark) {
      NavigationMark.segno || NavigationMark.coda => null,
      NavigationMark.toCoda => 'tocoda="coda"',
      NavigationMark.fine => 'fine="yes"',
      NavigationMark.daCapo => 'dacapo="yes"',
      NavigationMark.daCapoAlFine => 'dacapo="yes" fine="yes"',
      NavigationMark.daCapoAlCoda => 'dacapo="yes" tocoda="coda"',
      NavigationMark.dalSegno => 'dalsegno="segno"',
      NavigationMark.dalSegnoAlFine => 'dalsegno="segno" fine="yes"',
      NavigationMark.dalSegnoAlCoda => 'dalsegno="segno" tocoda="coda"',
    };
    if (sound != null) {
      out.writeln('        <sound $sound/>');
    }
    out.writeln('      </direction>');
  }

  /// Free text on the chart, as a direction's words.
  static void _annotation(
    StringBuffer out,
    CliAnnotation item,
    TimeSignature meter,
  ) {
    final offset =
        (item.position.beat * meter.beatDurationInQuarters * divisions).round();
    out
      ..writeln('      <direction placement="above">')
      ..writeln('        <direction-type>')
      ..writeln('          <words>${_escape(item.text)}</words>')
      ..writeln('        </direction-type>');
    if (offset != 0) {
      out.writeln('        <offset>$offset</offset>');
    }
    out.writeln('      </direction>');
  }

  /// The nearest MusicXML `kind` for a chord type.
  ///
  /// The vocabulary is fixed by the format and is smaller than Bandstand's, so
  /// the mapping is by family with the exact symbol preserved in `text`.
  static String _kindOf(ChordType type) {
    final name = type.name;
    const exact = <String, String>{
      '': 'major',
      'm': 'minor',
      '7': 'dominant',
      'maj7': 'major-seventh',
      'm7': 'minor-seventh',
      'm7b5': 'half-diminished',
      'o7': 'diminished-seventh',
      'o': 'diminished',
      '+': 'augmented',
      '6': 'major-sixth',
      'm6': 'minor-sixth',
      'sus4': 'suspended-fourth',
      'sus2': 'suspended-second',
      '9': 'dominant-ninth',
      'maj9': 'major-ninth',
      'm9': 'minor-ninth',
      '11': 'dominant-11th',
      '13': 'dominant-13th',
      'mMaj7': 'major-minor',
      '5': 'power',
    };
    final direct = exact[name];
    if (direct != null) {
      return direct;
    }
    return switch (type.family) {
      ChordFamily.major => 'major',
      ChordFamily.minor => 'minor',
      ChordFamily.dominant => 'dominant',
      ChordFamily.diminished => 'diminished',
      ChordFamily.augmented => 'augmented',
      ChordFamily.sus => 'suspended-fourth',
      ChordFamily.other => 'other',
    };
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
