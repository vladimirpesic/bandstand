import '../command/command.dart';
import '../harmony/ext_chord_symbol.dart';
import '../harmony/key_signature.dart';
import '../harmony/position.dart';
import 'chord_leadsheet.dart';
import 'lead_sheet_item.dart';
import 'mixer_settings.dart';
import 'section.dart';
import 'song.dart';
import 'song_part.dart';
import 'song_structure.dart';

/// The edits the editor makes to a song (§4.4).
///
/// Every one is a [Command], so every one is undoable, and the UI cannot
/// mutate the model by accident because there is nothing mutable to reach.
abstract final class SongCommands {
  /// Write a chord at [position], replacing anything already there.
  ///
  /// Merges with other chord edits at the same position, so typing `Dm7` is one
  /// undo step rather than three.
  static Command<Song> setChord(Position position, ExtChordSymbol chord) =>
      FunctionCommand<Song>(
        'Set chord',
        (song) => song.copyWith(
          leadSheet: song.leadSheet.withItem(CliChordSymbol(position, chord)),
        ),
        mergeKey: 'chord@${position.bar}:${position.beat}',
      );

  /// Remove the chord at [position], if there is one.
  static Command<Song> removeChord(Position position) => FunctionCommand<Song>(
    'Remove chord',
    (song) => song.copyWith(
      leadSheet: song.leadSheet.withoutWhere(
        (item) => item is CliChordSymbol && item.position == position,
      ),
    ),
  );

  /// Add or replace an item that is not a chord.
  static Command<Song> addItem(LeadSheetItem item) => FunctionCommand<Song>(
    'Add ${item.runtimeType}',
    (song) => song.copyWith(leadSheet: song.leadSheet.withItem(item)),
  );

  /// Remove an item.
  static Command<Song> removeItem(LeadSheetItem item) => FunctionCommand<Song>(
    'Remove ${item.runtimeType}',
    (song) => song.copyWith(leadSheet: song.leadSheet.withoutItem(item)),
  );

  /// Insert [count] empty bars before [at].
  static Command<Song> insertBars(int at, int count) => FunctionCommand<Song>(
    'Insert $count bar${count == 1 ? '' : 's'}',
    (song) => song.copyWith(leadSheet: song.leadSheet.insertBars(at, count)),
  );

  /// Remove [count] bars from [at].
  static Command<Song> removeBars(int at, int count) => FunctionCommand<Song>(
    'Delete $count bar${count == 1 ? '' : 's'}',
    (song) => song.copyWith(leadSheet: song.leadSheet.removeBars(at, count)),
  );

  /// Start a new section at [bar].
  static Command<Song> addSection(Section section) => FunctionCommand<Song>(
    'Add section ${section.name}',
    (song) =>
        song.copyWith(leadSheet: song.leadSheet.withItem(CliSection(section))),
  );

  /// Rename the song.
  static Command<Song> setTitle(String title) => FunctionCommand<Song>(
    'Rename',
    (song) => song.copyWith(title: title),
    mergeKey: 'title',
  );

  /// Set the composer.
  static Command<Song> setComposer(String composer) => FunctionCommand<Song>(
    'Set composer',
    (song) => song.copyWith(composer: composer),
    mergeKey: 'composer',
  );

  /// Set the tempo.
  static Command<Song> setTempo(int tempo) => FunctionCommand<Song>(
    'Set tempo',
    (song) => song.copyWith(tempo: tempo),
    mergeKey: 'tempo',
  );

  /// Set the key without moving the chords — for correcting an import.
  static Command<Song> setKey(KeySignature key) =>
      FunctionCommand<Song>('Set key', (song) => song.copyWith(key: key));

  /// Transpose the whole song, chart and key together.
  static Command<Song> transpose(int semitones) => FunctionCommand<Song>(
    'Transpose ${semitones > 0 ? '+' : ''}$semitones',
    (song) => song.transposed(semitones),
  );

  /// Change the mixer.
  ///
  /// Undoable like every other edit, and saved with the tune: the levels are
  /// part of the arrangement, not a global preference.
  static Command<Song> setMixer(MixerSettings mixer) => FunctionCommand<Song>(
    'Change the mixer',
    (song) => song.copyWith(mixer: mixer),
    mergeKey: 'mixer',
  );

  /// Set the song's tags.
  static Command<Song> setTags(Set<String> tags) =>
      FunctionCommand<Song>('Set tags', (song) => song.copyWith(tags: tags));

  /// Append a part to the arrangement.
  static Command<Song> appendSongPart(SongPart part) => FunctionCommand<Song>(
    'Add ${part.displayName}',
    (song) => song.copyWith(structure: song.structure.withPartAppended(part)),
  );

  /// Remove the arrangement part at [index].
  static Command<Song> removeSongPart(int index) => FunctionCommand<Song>(
    'Remove song part',
    (song) => song.copyWith(structure: song.structure.withPartRemoved(index)),
  );

  /// Replace the arrangement part at [index].
  static Command<Song> replaceSongPart(int index, SongPart part) =>
      FunctionCommand<Song>(
        'Change song part',
        (song) => song.copyWith(
          structure: song.structure.withPartReplaced(index, part),
        ),
      );

  /// Drag an arrangement part into a new place.
  static Command<Song> moveSongPart(int from, int to) => FunctionCommand<Song>(
    'Reorder song parts',
    (song) => song.copyWith(structure: song.structure.withPartMoved(from, to)),
  );

  /// Play every part with a different rhythm.
  ///
  /// Distinct from [rebuildStructure], which throws the arrangement away and
  /// builds a new one: changing the band a tune is played by should not undo
  /// the work of ordering its parts. Per-part parameters are dropped, because
  /// they belong to the rhythm that declared them — a drum "fills" setting
  /// means nothing to a bass player.
  static Command<Song> setRhythm(String rhythmId) => FunctionCommand<Song>(
    'Change rhythm',
    (song) => song.copyWith(
      structure: SongStructure(<SongPart>[
        for (final part in song.structure.songParts)
          part.copyWith(
            rhythmId: rhythmId,
            parameterValues: const <String, Object>{},
          ),
      ]),
    ),
  );

  /// Rebuild the arrangement from the chart: one part per section, once each.
  static Command<Song> rebuildStructure(String rhythmId) =>
      FunctionCommand<Song>(
        'Rebuild arrangement',
        (song) => song.copyWith(
          structure: SongStructure.fromLeadSheet(
            song.leadSheet,
            rhythmId: rhythmId,
          ),
        ),
      );

  /// Replace the whole lead sheet — what an import does.
  static Command<Song> replaceLeadSheet(ChordLeadSheet sheet) =>
      FunctionCommand<Song>(
        'Replace chart',
        (song) => song.copyWith(leadSheet: sheet),
      );
}
