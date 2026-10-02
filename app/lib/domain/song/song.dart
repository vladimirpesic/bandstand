import '../harmony/key_signature.dart';
import '../harmony/spelling_preference.dart';
import '../harmony/time_signature.dart';
import 'chord_leadsheet.dart';
import 'mixer_settings.dart';
import 'song_structure.dart';
import 'written_part.dart';

/// Slowest tempo a song may store, in beats per minute.
const int minTempo = 10;

/// Fastest tempo a song may store, in beats per minute.
const int maxTempo = 400;

/// The default style a new song is written for, until the generators land.
const String defaultRhythmId = 'unassigned';

/// A tune: the written chart, the arrangement, and everything about how it is
/// played (§4.3).
///
/// Immutable. Every edit produces a new song, which is what makes the command
/// pattern of §4.4 a one-liner and undo exact.
class Song {
  /// Create a song.
  ///
  /// Throws [ArgumentError] if the id or title is empty, or the tempo is
  /// outside 10–400 bpm.
  Song({
    required this.id,
    required this.title,
    required this.leadSheet,
    required this.structure,
    this.composer = '',
    this.tempo = 120,
    KeySignature? key,
    MixerSettings? mixer,
    Set<String> tags = const <String>{},
    Map<String, String> meta = const <String, String>{},
    Iterable<WrittenPart> writtenParts = const <WrittenPart>[],
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) : key = key ?? KeySignature.cMajor(),
       mixer = mixer ?? MixerSettings.empty(),
       writtenParts = List<WrittenPart>.unmodifiable(writtenParts),
       tags = Set<String>.unmodifiable(tags.toList()..sort()),
       meta = Map<String, String>.unmodifiable(meta),
       createdAt = createdAt ?? DateTime.now().toUtc(),
       modifiedAt = modifiedAt ?? createdAt ?? DateTime.now().toUtc() {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a song needs an id');
    }
    if (title.trim().isEmpty) {
      throw ArgumentError.value(title, 'title', 'a song needs a title');
    }
    if (tempo < minTempo || tempo > maxTempo) {
      throw ArgumentError.value(
        tempo,
        'tempo',
        'must be between $minTempo and $maxTempo bpm',
      );
    }
  }

  /// A new, empty song.
  factory Song.blank({
    required String id,
    String title = 'Untitled',
    int barCount = 32,
    TimeSignature timeSignature = TimeSignature.fourFour,
    String rhythmId = defaultRhythmId,
  }) {
    final sheet = ChordLeadSheet.empty(
      barCount: barCount,
      timeSignature: timeSignature,
    );
    return Song(
      id: id,
      title: title,
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: rhythmId),
    );
  }

  /// Stable identifier; also the file name in the library.
  final String id;

  /// What the tune is called.
  final String title;

  /// Who wrote it.
  final String composer;

  /// The written chart.
  final ChordLeadSheet leadSheet;

  /// The arrangement.
  final SongStructure structure;

  /// Tempo in beats per minute.
  final int tempo;

  /// The key the chart is written in. Drives chord spelling on transposition.
  final KeySignature key;

  /// Per-voice levels and instruments.
  final MixerSettings mixer;

  /// Parts somebody already wrote, played exactly as they stand — the head, a
  /// horn part, a cue (§9). Empty for a tune that is only chords, which is
  /// most of them.
  ///
  /// Muted by default; see `docs/rules/written-parts.md` §4.
  final List<WrittenPart> writtenParts;

  /// Whether this tune carries a written part at all.
  bool get hasWrittenParts => writtenParts.any((part) => !part.isEmpty);

  /// Free-form tags for the library screen: `bebop`, `ballad`, `gig`.
  final Set<String> tags;

  /// Anything else the app or an importer wants to remember: style hint,
  /// source file, comments.
  final Map<String, String> meta;

  /// When the song was first written, in UTC.
  final DateTime createdAt;

  /// When it was last changed, in UTC.
  final DateTime modifiedAt;

  /// The spelling preference the chart's own key implies.
  SpellingPreference get spellingPreference => SpellingPreference.key(key);

  /// The meter at the start of the chart.
  TimeSignature get timeSignature => leadSheet.timeSignatureAt(0);

  /// How many bars are written on the page.
  int get writtenBarCount => leadSheet.barCount;

  /// A copy with some fields replaced.
  ///
  /// [modifiedAt] moves to now unless it is given explicitly, because almost
  /// every caller of this is an edit. [id] and [createdAt] are here for the one
  /// caller that is not — [duplicatedAs] — and default to this song's own.
  ///
  /// This is the single list of the song's fields, and the only safe way to
  /// derive one song from another: an enumerated constructor call elsewhere
  /// drops whatever field its author forgot, and says nothing about it.
  Song copyWith({
    String? id,
    String? title,
    String? composer,
    ChordLeadSheet? leadSheet,
    SongStructure? structure,
    int? tempo,
    KeySignature? key,
    MixerSettings? mixer,
    Set<String>? tags,
    Map<String, String>? meta,
    Iterable<WrittenPart>? writtenParts,
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) => Song(
    id: id ?? this.id,
    title: title ?? this.title,
    composer: composer ?? this.composer,
    leadSheet: leadSheet ?? this.leadSheet,
    structure: structure ?? this.structure,
    tempo: tempo ?? this.tempo,
    key: key ?? this.key,
    mixer: mixer ?? this.mixer,
    tags: tags ?? this.tags,
    meta: meta ?? this.meta,
    writtenParts: writtenParts ?? this.writtenParts,
    createdAt: createdAt ?? this.createdAt,
    modifiedAt: modifiedAt ?? DateTime.now().toUtc(),
  );

  /// This song again under a new [id] and [title] — the library's "duplicate".
  ///
  /// Everything else comes across, written parts included. Both timestamps are
  /// fresh, because the copy is a new song rather than an edit of this one.
  Song duplicatedAs({required String id, required String title}) {
    final now = DateTime.now().toUtc();
    return copyWith(id: id, title: title, createdAt: now, modifiedAt: now);
  }

  /// This song transposed by [semitones], chart and key together.
  ///
  /// The stored song *is* changed — this is the editor's "transpose this tune
  /// for good". Reading a chart in another key without changing it is a render
  /// setting (§9), and does not come through here.
  Song transposed(int semitones) {
    final newKey = key.transposed(semitones);
    return copyWith(
      key: newKey,
      leadSheet: leadSheet.transposed(
        semitones,
        preference: SpellingPreference.key(newKey),
      ),
    );
  }

  @override
  String toString() => '$title (${leadSheet.barCount} bars, $tempo bpm)';

  @override
  bool operator ==(Object other) =>
      other is Song &&
      other.id == id &&
      other.title == title &&
      other.composer == composer &&
      other.leadSheet == leadSheet &&
      other.structure == structure &&
      other.tempo == tempo &&
      other.key == key &&
      other.mixer == mixer &&
      other.tags.length == tags.length &&
      other.tags.containsAll(tags) &&
      _sameMeta(other.meta) &&
      other.writtenParts.length == writtenParts.length &&
      _sameWrittenParts(other.writtenParts) &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt;

  bool _sameWrittenParts(List<WrittenPart> other) {
    for (var i = 0; i < writtenParts.length; i++) {
      if (writtenParts[i] != other[i]) {
        return false;
      }
    }
    return true;
  }

  bool _sameMeta(Map<String, String> other) {
    if (other.length != meta.length) {
      return false;
    }
    for (final entry in meta.entries) {
      if (other[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    composer,
    leadSheet,
    structure,
    tempo,
    key,
    mixer,
    Object.hashAllUnordered(tags),
    Object.hashAllUnordered(
      meta.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAll(writtenParts),
    createdAt,
    modifiedAt,
  );
}
