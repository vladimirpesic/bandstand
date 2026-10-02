import 'package:bandstand/io/bank_download.dart';
import 'package:bandstand/state/bank_download_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The download, at the point of need: under the soundbank picker on the
/// audio screen, when the picker has nothing to pick.
///
/// Unlike the library-screen banner this is always offered — the user is
/// staring at an empty bank dropdown, which is consent enough — and it is
/// the way back in after "never ask again". When the download finishes, the
/// refreshed bank list puts a real entry above these controls and they
/// disappear.
class BankDownloadControls extends ConsumerWidget {
  const BankDownloadControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bankDownloadProvider);
    if (state.phase == BankDownloadPhase.done) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(bankDownloadProvider.notifier);
    return switch (state.phase) {
      BankDownloadPhase.downloading => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LinearProgressIndicator(value: state.fraction),
          const SizedBox(height: 6),
          Text(
            'Downloading ${fluidR3GM.displayName} — ${_mb(state.bytesDone)}'
            '${state.bytesTotal == null ? '' : ' of ${_mb(state.bytesTotal!)}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: controller.cancel,
              child: const Text('Pause'),
            ),
          ),
        ],
      ),
      BankDownloadPhase.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'The download did not finish — what was fetched is kept, and '
            'retrying continues from there.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: controller.start,
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
      // Idle: offer the download, resuming if there is anything to resume —
      // the trailing text is what says so. Button and text sit in a Wrap so
      // a narrow screen puts the details under the button instead of pushing
      // it off the edge.
      BankDownloadPhase.idle => Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          FilledButton.tonalIcon(
            onPressed: controller.start,
            icon: const Icon(Icons.download),
            label: Text(state.isPartial ? 'Resume download' : 'Download'),
          ),
          Text(
            state.isPartial
                ? '${_mb(state.bytesDone)} fetched — resumes where it stopped'
                : '${fluidR3GM.displayName} — ${fluidR3GM.sizeLabel}, free',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      BankDownloadPhase.done => const SizedBox.shrink(),
    };
  }
}

/// `bytes` as megabytes with one decimal; the rounded `148 MB` of the offer
/// label is [RecommendedBank.sizeLabel].
String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
