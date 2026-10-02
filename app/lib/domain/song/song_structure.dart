import 'chord_leadsheet.dart';
import 'song_part.dart';

/// The arrangement: which sections play, in what order, how many times, with
/// which style and parameters (§4.3).
///
/// Kept strictly apart from [ChordLeadSheet]: the lead sheet is the written
/// page, this is the running order. JJazzLab's best design decision, and the
/// reason the same eight bars can be played three times at three intensities.
class SongStructure {
  SongStructure._(List<SongPart> songParts)
    : songParts = List<SongPart>.unmodifiable(songParts);

  /// Create an arrangement from parts, laid out end to end.
  ///
  /// The parts' start bars are recomputed so they are contiguous from bar 0:
  /// a structure with a gap or an overlap in it is never what anyone meant, and
  /// leaving one possible means every consumer has to cope with it.
  factory SongStructure(Iterable<SongPart> parts) {
    final laid = <SongPart>[];
    var bar = 0;
    for (final part in parts) {
      laid.add(part.copyWith(startBar: bar));
      bar += part.barCount;
    }
    return SongStructure._(laid);
  }

  /// An empty arrangement.
  factory SongStructure.empty() => SongStructure._(const <SongPart>[]);

  /// One part per section of [sheet], in bar order, all using [rhythmId].
  ///
  /// What a freshly imported chart gets: play the form once, straight through.
  factory SongStructure.fromLeadSheet(
    ChordLeadSheet sheet, {
    required String rhythmId,
  }) {
    final sections = sheet.sections;
    if (sections.isEmpty) {
      return SongStructure(<SongPart>[
        SongPart(
          parentSectionName: 'A',
          startBar: 0,
          barCount: sheet.barCount,
          rhythmId: rhythmId,
        ),
      ]);
    }
    return SongStructure(<SongPart>[
      for (final section in sections)
        SongPart(
          parentSectionName: section.name,
          startBar: 0,
          barCount: sheet.sectionEndBar(section) - section.startBar,
          rhythmId: rhythmId,
        ),
    ]);
  }

  /// The parts, in playing order, laid out contiguously from bar 0.
  final List<SongPart> songParts;

  /// How many bars the arrangement lasts.
  int get barCount => songParts.isEmpty ? 0 : songParts.last.endBar;

  /// Whether the arrangement plays nothing.
  bool get isEmpty => songParts.isEmpty;

  /// The part covering [bar], or null.
  SongPart? partAt(int bar) {
    for (final part in songParts) {
      if (part.contains(bar)) {
        return part;
      }
    }
    return null;
  }

  /// The index of the part covering [bar], or −1.
  int indexAt(int bar) {
    for (var i = 0; i < songParts.length; i++) {
      if (songParts[i].contains(bar)) {
        return i;
      }
    }
    return -1;
  }

  /// A copy with [part] appended.
  SongStructure withPartAppended(SongPart part) =>
      SongStructure(<SongPart>[...songParts, part]);

  /// A copy with [part] inserted at [index].
  ///
  /// Throws [RangeError] if the index is outside `0..length`.
  SongStructure withPartInserted(int index, SongPart part) {
    if (index < 0 || index > songParts.length) {
      throw RangeError.range(index, 0, songParts.length, 'index');
    }
    return SongStructure(<SongPart>[...songParts]..insert(index, part));
  }

  /// A copy with the part at [index] removed.
  ///
  /// Throws [RangeError] if the index is outside the structure.
  SongStructure withPartRemoved(int index) {
    RangeError.checkValidIndex(index, songParts, 'index', songParts.length);
    return SongStructure(<SongPart>[...songParts]..removeAt(index));
  }

  /// A copy with the part at [index] replaced.
  ///
  /// Throws [RangeError] if the index is outside the structure.
  SongStructure withPartReplaced(int index, SongPart part) {
    RangeError.checkValidIndex(index, songParts, 'index', songParts.length);
    final parts = <SongPart>[...songParts];
    parts[index] = part;
    return SongStructure(parts);
  }

  /// A copy with the part at [from] moved to [to].
  ///
  /// Throws [RangeError] if either index is outside the structure.
  SongStructure withPartMoved(int from, int to) {
    RangeError.checkValidIndex(from, songParts, 'from', songParts.length);
    RangeError.checkValidIndex(to, songParts, 'to', songParts.length);
    final parts = <SongPart>[...songParts];
    parts.insert(to, parts.removeAt(from));
    return SongStructure(parts);
  }

  /// Every part naming a section that [sheet] does not have.
  ///
  /// An arrangement can outlive the section it points at — the user renamed it,
  /// or an import went wrong. Reported rather than repaired: silently
  /// reassigning a part is how an arrangement quietly becomes the wrong tune.
  List<SongPart> danglingParts(ChordLeadSheet sheet) => <SongPart>[
    for (final part in songParts)
      if (sheet.sectionNamed(part.parentSectionName) == null) part,
  ];

  @override
  String toString() =>
      'SongStructure(${songParts.length} parts, $barCount bars)';

  @override
  bool operator ==(Object other) {
    if (other is! SongStructure || other.songParts.length != songParts.length) {
      return false;
    }
    for (var i = 0; i < songParts.length; i++) {
      if (songParts[i] != other.songParts[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(songParts);
}
