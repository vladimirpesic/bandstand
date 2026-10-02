import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';

import 'chart_view.dart';

/// Turns the transport's playhead into a place on the written page.
///
/// The transport counts ticks along the *flattened* sequence; the chart draws
/// the *written* page. `SongChordSequence.sourceBars` is the map between them
/// (§4.5), and this is the only place it is applied.
class PlaybackCursorResolver {
  /// Create a resolver for [song].
  PlaybackCursorResolver(Song song) : sequence = SongChordSequence.of(song);

  /// The flattened sequence the transport is playing.
  final SongChordSequence sequence;

  /// Where the cursor should be, given a reading of the playhead.
  ///
  /// Returns [ChartCursor.hidden] when the transport is stopped or has run past
  /// the end of the song — a cursor parked on the last bar of a finished tune
  /// is a lie.
  ChartCursor resolve(PlayheadReading reading) {
    if (reading.state == TransportState.stopped || sequence.bars.isEmpty) {
      return ChartCursor.hidden;
    }
    final quarters = quartersFor(reading);
    final bar = sequence.barAtQuarters(quarters);
    if (bar == null) {
      return ChartCursor.hidden;
    }
    final through = (quarters - bar.startQuarters) / bar.durationQuarters;
    return ChartCursor(
      sourceBar: bar.sourceBar,
      beatFraction: through.clamp(0.0, 1.0),
    );
  }

  /// How far into the song a playhead reading is, in quarter notes.
  double quartersFor(PlayheadReading reading) =>
      reading.ppq == 0 ? 0 : reading.tick / reading.ppq;
}
