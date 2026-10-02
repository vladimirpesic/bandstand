import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Offers back the edits a crash interrupted (§5.4).
///
/// The editor writes the song it is working on to a journal every few seconds.
/// If the app went away without saving, that journal is newer than the file on
/// disk, and this is where the user gets to decide what to do about it.
///
/// It says what it found and when, and it makes discarding a deliberate act:
/// the whole point of the journal is that a crash costs seconds, and silently
/// dropping the recovery would put the cost back.
class RecoveryBanner extends ConsumerWidget {
  const RecoveryBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recoveries = ref.watch(pendingRecoveriesProvider);
    final pending = recoveries.value ?? const <JournalRecovery>[];
    if (pending.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      children: <Widget>[
        for (final recovery in pending)
          RecoveryRow(
            recovery: recovery,
            onRestore: () => ref
                .read(libraryControllerProvider)
                .restoreRecovery(recovery.song),
            onDiscard: () => ref
                .read(libraryControllerProvider)
                .discardRecovery(recovery.song.id),
          ),
      ],
    );
  }
}

/// One unsaved edit, and the two things that can be done with it.
class RecoveryRow extends StatelessWidget {
  /// Create a row.
  const RecoveryRow({
    required this.recovery,
    required this.onRestore,
    required this.onDiscard,
    super.key,
  });

  /// What was found in the journal.
  final JournalRecovery recovery;

  /// Keep the journalled version.
  final VoidCallback onRestore;

  /// Throw it away.
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saved = recovery.savedModified;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.restore, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Unsaved changes to "${recovery.song.title}"',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  saved == null
                      ? 'This song was never saved.'
                      : 'Edited after the last save.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onTertiaryContainer),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onDiscard, child: const Text('Discard')),
          const SizedBox(width: 8),
          FilledButton(onPressed: onRestore, child: const Text('Restore')),
        ],
      ),
    );
  }
}
