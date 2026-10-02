import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/exporters/midi_export.dart';
import 'package:bandstand/io/exporters/musicxml_export.dart';
import 'package:bandstand/io/exporters/pdf_export.dart';
import 'package:bandstand/io/song_library.dart';

/// What an export produced.
class ExportResult {
  /// Create a result.
  const ExportResult({required this.file, required this.bytes});

  /// Where it went. An export the user cannot find has not happened
  /// (`docs/rules/exporters.md` §6).
  final File file;

  /// How big it is.
  final int bytes;

  /// The file's name, for a message.
  String get name => file.uri.pathSegments.last;
}

/// Writes songs out in the formats of §5.3.
///
/// Rules: `docs/rules/exporters.md`. Everything lands in one place —
/// `<library>/exports/` — because a player exporting a set does not want twelve
/// file dialogues, and the library folder itself belongs to `SongLibrary` and
/// must stay tidy (§5.4).
class ExportService {
  /// Create a service writing beside `library`.
  ExportService(this.library);

  /// The library whose folder the exports sit beside.
  final SongLibrary library;

  /// Where exports go.
  Directory get exportsDirectory =>
      Directory('${library.root.path}${Platform.pathSeparator}exports');

  /// Write `generated` as a Standard MIDI File (§2).
  Future<ExportResult> exportMidi(Song song, GeneratedSong generated) =>
      _write(song, 'mid', MidiExporter.export(song, generated));

  /// Write the written chart as MusicXML (§5).
  Future<ExportResult> exportMusicXml(Song song) => _write(
    song,
    'musicxml',
    Uint8List.fromList(MusicXmlExporter.export(song).codeUnits),
  );

  /// Write the chart as a PDF page (§4).
  Future<ExportResult> exportPdf(Song song, {int transposition = 0}) async =>
      _write(
        song,
        'pdf',
        await PdfExporter.export(song, transposition: transposition),
      );

  /// The path an audio render should be written to.
  ///
  /// The render itself is the Rust engine's (§3) — it renders through the same
  /// synth as playback, so what is exported is what was heard — and this only
  /// decides where the file goes.
  Future<File> audioDestination(Song song) async {
    await exportsDirectory.create(recursive: true);
    return File(_pathFor(song, 'wav'));
  }

  Future<ExportResult> _write(
    Song song,
    String extension,
    Uint8List bytes,
  ) async {
    await exportsDirectory.create(recursive: true);
    final file = File(_pathFor(song, extension));
    // Atomically, like everything else that writes to the library folder
    // (§5.4): a half-written export found later is worse than none.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    return ExportResult(file: file, bytes: bytes.length);
  }

  String _pathFor(Song song, String extension) =>
      '${exportsDirectory.path}${Platform.pathSeparator}'
      '${safeFileName(song.title)}-${song.id}.$extension';

  /// A song title reduced to something every filesystem accepts.
  ///
  /// Titles have slashes, colons and quotes in them — `Love For Sale`, but also
  /// `A/B Blues` — and any of those makes a path that either fails or lands
  /// somewhere unexpected. The length limit counts UTF-8 bytes, which is what
  /// filesystems and network shares enforce, and the cut lands on a character
  /// boundary so the name reads back the same.
  static String safeFileName(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) {
      return 'Untitled';
    }
    // Windows refuses these regardless of extension.
    const reserved = <String>{
      'CON', 'PRN', 'AUX', 'NUL', //
      'COM1', 'COM2', 'COM3', 'COM4', 'LPT1', 'LPT2', 'LPT3',
    };
    if (reserved.contains(cleaned.toUpperCase())) {
      return '_$cleaned';
    }
    return _limitBytes(cleaned, 120);
  }

  static String _limitBytes(String text, int maxBytes) {
    final out = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final size = rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      if (used + size > maxBytes) {
        break;
      }
      used += size;
      out.writeCharCode(rune);
    }
    return out.toString().trim();
  }
}
