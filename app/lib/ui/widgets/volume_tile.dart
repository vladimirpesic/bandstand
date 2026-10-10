import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/state/library.dart';
import 'package:flutter/material.dart';

/// One volume as a row: its number, its human name, and what of it is on
/// this device — the exact row in the library list and in search results,
/// so the two never drift apart.
class VolumeTile extends StatelessWidget {
  /// Create the tile.
  const VolumeTile({
    super.key,
    required this.phase,
    required this.volume,
    required this.onTap,
  });

  /// The library as it stands; only the presence map is read.
  final LibraryReady phase;

  /// The volume to show.
  final LibraryVolume volume;

  /// Where a tap goes.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var present = 0;
    for (final entry in volume.entries) {
      final there = phase.presence[entry.id];
      if (there != null && there != CachePresence.absent) {
        present++;
      }
    }
    final onDevice = present == 0 ? '' : ' · $present on device';
    return ListTile(
      leading: CircleAvatar(
        child: Text(volume.volumeNumber?.toString().padLeft(3, '0') ?? '···'),
      ),
      title: Text(volume.displayName),
      subtitle: Text(
        '${volume.tracks.length} tracks'
        '${volume.book == null ? '' : ' · book'}$onDevice',
      ),
      onTap: onTap,
    );
  }
}
