import '../harmony/key_signature.dart';
import '../harmony/spelling_preference.dart';
import 'song.dart';
import 'song_part.dart';
import 'song_structure.dart';

/// One song in a set, with the overrides that set needs.
///
/// §9 is emphatic about this: *the same tune appears in two sets in different
/// keys*, so the overrides live on the entry and never on the song. Applying an
/// entry produces a new [Song] value; the stored song is untouched.
class PlaylistEntry {
  /// Create an entry.
  ///
  /// Throws [ArgumentError] if the song id is empty, the tempo override is
  /// outside 10–400 bpm, or the chorus count is not positive.
  PlaylistEntry({
    required this.songId,
    this.tempoOverride,
    this.transposeOverride,
    this.keyOverride,
    this.chorusCount,
    this.note = '',
  }) {
    if (songId.trim().isEmpty) {
      throw ArgumentError.value(songId, 'songId', 'an entry needs a song');
    }
    if (tempoOverride != null &&
        (tempoOverride! < minTempo || tempoOverride! > maxTempo)) {
      throw ArgumentError.value(
        tempoOverride,
        'tempoOverride',
        'must be between $minTempo and $maxTempo bpm',
      );
    }
    if (transposeOverride != null &&
        (transposeOverride! < -11 || transposeOverride! > 11)) {
      throw ArgumentError.value(
        transposeOverride,
        'transposeOverride',
        'must be within an octave; use a key override for anything else',
      );
    }
    if (chorusCount != null && chorusCount! < 1) {
      throw ArgumentError.value(
        chorusCount,
        'chorusCount',
        'must be at least one',
      );
    }
  }

  /// Which song.
  final String songId;

  /// Play it at this tempo instead, or null to use the song's.
  final int? tempoOverride;

  /// Move it by this many semitones, or null for the written key.
  final int? transposeOverride;

  /// The key to read it in. Sets the spelling; combined with
  /// [transposeOverride] when both are given, and used to derive the
  /// transposition when [transposeOverride] is null.
  final KeySignature? keyOverride;

  /// Play the arrangement this many times, or null for once.
  final int? chorusCount;

  /// A note for the stand: "after the drum solo", "vocal in 2".
  final String note;

  /// Whether this entry changes anything at all.
  bool get isPlain =>
      tempoOverride == null &&
      transposeOverride == null &&
      keyOverride == null &&
      chorusCount == null;

  /// How far [song] moves under this entry, in semitones.
  ///
  /// An explicit [transposeOverride] wins; otherwise a [keyOverride] is turned
  /// into the shortest move that reaches it, so "play it in F" does not
  /// transpose the tune up eleven semitones to get down one.
  int transpositionFor(Song song) {
    final explicit = transposeOverride;
    if (explicit != null) {
      return explicit;
    }
    final target = keyOverride;
    if (target == null) {
      return 0;
    }
    final distance = (target.tonic.pitchClass - song.key.tonic.pitchClass) % 12;
    return distance > 6 ? distance - 12 : distance;
  }

  /// [song] as this entry says to play it.
  ///
  /// A pure function of the entry and the song: the library's copy is never
  /// touched, which is the guarantee §10 M2 asks to be tested.
  Song applyTo(Song song) {
    var result = song;
    final semitones = transpositionFor(song);
    if (semitones != 0) {
      final destination =
          keyOverride ??
          KeySignature(
            song.key.spell(song.key.tonic.pitchClass + semitones),
            song.key.mode,
          );
      result = result.copyWith(
        key: destination,
        leadSheet: song.leadSheet.transposed(
          semitones,
          preference: SpellingPreference.key(destination),
        ),
        modifiedAt: song.modifiedAt,
      );
    } else if (keyOverride != null && keyOverride != song.key) {
      // Same pitch, different spelling: an Eb chart written out in D#.
      result = result.copyWith(
        key: keyOverride,
        leadSheet: song.leadSheet.transposed(
          0,
          preference: SpellingPreference.key(keyOverride!),
        ),
        modifiedAt: song.modifiedAt,
      );
    }
    final tempo = tempoOverride;
    if (tempo != null && tempo != result.tempo) {
      result = result.copyWith(tempo: tempo, modifiedAt: song.modifiedAt);
    }
    final choruses = chorusCount;
    if (choruses != null && choruses > 1 && !result.structure.isEmpty) {
      // Playing the form n times is the arrangement repeated n times. Building
      // it here rather than adding a "repeat" flag to the structure keeps the
      // generators' input a plain linear list (§4.3).
      result = result.copyWith(
        structure: SongStructure(<SongPart>[
          for (var chorus = 0; chorus < choruses; chorus++)
            ...result.structure.songParts,
        ]),
        modifiedAt: song.modifiedAt,
      );
    }
    return result;
  }

  /// A copy with some fields replaced.
  PlaylistEntry copyWith({
    String? songId,
    int? tempoOverride,
    bool clearTempo = false,
    int? transposeOverride,
    bool clearTranspose = false,
    KeySignature? keyOverride,
    bool clearKey = false,
    int? chorusCount,
    bool clearChoruses = false,
    String? note,
  }) => PlaylistEntry(
    songId: songId ?? this.songId,
    tempoOverride: clearTempo ? null : (tempoOverride ?? this.tempoOverride),
    transposeOverride: clearTranspose
        ? null
        : (transposeOverride ?? this.transposeOverride),
    keyOverride: clearKey ? null : (keyOverride ?? this.keyOverride),
    chorusCount: clearChoruses ? null : (chorusCount ?? this.chorusCount),
    note: note ?? this.note,
  );

  @override
  String toString() => isPlain ? songId : '$songId (overridden)';

  @override
  bool operator ==(Object other) =>
      other is PlaylistEntry &&
      other.songId == songId &&
      other.tempoOverride == tempoOverride &&
      other.transposeOverride == transposeOverride &&
      other.keyOverride == keyOverride &&
      other.chorusCount == chorusCount &&
      other.note == note;

  @override
  int get hashCode => Object.hash(
    songId,
    tempoOverride,
    transposeOverride,
    keyOverride,
    chorusCount,
    note,
  );
}

/// An ordered set of songs: a gig, a lesson, a rehearsal (§8.2).
class Playlist {
  Playlist._({
    required this.id,
    required this.name,
    required List<PlaylistEntry> entries,
    required this.note,
    required this.createdAt,
    required this.modifiedAt,
  }) : entries = List<PlaylistEntry>.unmodifiable(entries);

  /// Create a playlist.
  ///
  /// Throws [ArgumentError] if the id or name is empty.
  factory Playlist({
    required String id,
    required String name,
    Iterable<PlaylistEntry> entries = const <PlaylistEntry>[],
    String note = '',
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a playlist needs an id');
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'a playlist needs a name');
    }
    final created = createdAt ?? DateTime.now().toUtc();
    return Playlist._(
      id: id,
      name: name,
      entries: entries.toList(),
      note: note,
      createdAt: created,
      modifiedAt: modifiedAt ?? created,
    );
  }

  /// Stable identifier; also the file name in the library.
  final String id;

  /// What the set is called: "Friday, The Vortex".
  final String name;

  /// The songs, in playing order.
  final List<PlaylistEntry> entries;

  /// A note for the whole set.
  final String note;

  /// When the playlist was created, in UTC.
  final DateTime createdAt;

  /// When it was last changed, in UTC.
  final DateTime modifiedAt;

  /// How many songs are in the set.
  int get length => entries.length;

  /// Whether the set is empty.
  bool get isEmpty => entries.isEmpty;

  /// A copy with [entry] appended.
  Playlist withEntryAppended(PlaylistEntry entry) =>
      _with(<PlaylistEntry>[...entries, entry]);

  /// A copy with [entry] inserted at [index].
  ///
  /// Throws [RangeError] if the index is outside `0..length`.
  Playlist withEntryInserted(int index, PlaylistEntry entry) {
    if (index < 0 || index > entries.length) {
      throw RangeError.range(index, 0, entries.length, 'index');
    }
    return _with(<PlaylistEntry>[...entries]..insert(index, entry));
  }

  /// A copy with the entry at [index] removed.
  Playlist withEntryRemoved(int index) {
    RangeError.checkValidIndex(index, entries, 'index', entries.length);
    return _with(<PlaylistEntry>[...entries]..removeAt(index));
  }

  /// A copy with the entry at [index] replaced.
  Playlist withEntryReplaced(int index, PlaylistEntry entry) {
    RangeError.checkValidIndex(index, entries, 'index', entries.length);
    final updated = <PlaylistEntry>[...entries];
    updated[index] = entry;
    return _with(updated);
  }

  /// A copy with the entry at [from] moved to [to] — a drag in the set list.
  Playlist withEntryMoved(int from, int to) {
    RangeError.checkValidIndex(from, entries, 'from', entries.length);
    RangeError.checkValidIndex(to, entries, 'to', entries.length);
    final updated = <PlaylistEntry>[...entries];
    updated.insert(to, updated.removeAt(from));
    return _with(updated);
  }

  /// A copy with a different name.
  Playlist renamed(String newName) => Playlist(
    id: id,
    name: newName,
    entries: entries,
    note: note,
    createdAt: createdAt,
    modifiedAt: DateTime.now().toUtc(),
  );

  /// A copy with a different note.
  Playlist withNote(String newNote) => Playlist(
    id: id,
    name: name,
    entries: entries,
    note: newNote,
    createdAt: createdAt,
    modifiedAt: DateTime.now().toUtc(),
  );

  Playlist _with(List<PlaylistEntry> updated) => Playlist(
    id: id,
    name: name,
    entries: updated,
    note: note,
    createdAt: createdAt,
    modifiedAt: DateTime.now().toUtc(),
  );

  @override
  String toString() => '$name (${entries.length} songs)';

  @override
  bool operator ==(Object other) {
    if (other is! Playlist ||
        other.id != id ||
        other.name != name ||
        other.note != note ||
        other.createdAt != createdAt ||
        other.modifiedAt != modifiedAt ||
        other.entries.length != entries.length) {
      return false;
    }
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] != other.entries[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    note,
    createdAt,
    modifiedAt,
    Object.hashAll(entries),
  );
}
