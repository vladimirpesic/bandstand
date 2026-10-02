import 'package:bandstand/io/bank_download.dart';
import 'package:bandstand/state/bank_download_state.dart';
import 'package:bandstand/state/playback_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Offers the recommended soundbank on first run, follows the download
/// through, and stays out of the way once there is any bank at all.
///
/// Shown on the library screen — the app's home — while the machine has no
/// soundbank of any kind: with no bank there is no sound, and a new user has
/// no reason to know that, or what to do about it.
///
/// The offer is explicit rather than automatic, even though it appears on the
/// very first screen: 148 MB is not the app's data to spend without asking,
/// least of all on a metered phone connection. "Download" is one tap; "Not
/// now" costs the same and comes back another day; "Never ask again" is
/// remembered on disk, next to where the bank would have gone.
class BankDownloadBanner extends ConsumerWidget {
  const BankDownloadBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The scanned list, not the folder: a system bank — /usr/share/sounds/sf2
    // on a desktop, one pushed onto a device by hand — means the user can
    // already make sound, and the offer would be noise.
    final banks = ref.watch(soundbanksProvider).value;
    if (banks == null || banks.isNotEmpty) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(bankDownloadProvider);
    final controller = ref.read(bankDownloadProvider.notifier);
    final declined = ref.watch(bankOfferDeclinedProvider).value ?? false;
    if (declined ||
        state.sessionDeclined ||
        state.phase == BankDownloadPhase.done) {
      return const SizedBox.shrink();
    }
    return switch (state.phase) {
      BankDownloadPhase.downloading => _ProgressCard(
        state: state,
        onPause: controller.cancel,
      ),
      BankDownloadPhase.failed => _FailureCard(
        message: state.errorMessage ?? 'Every mirror failed.',
        onRetry: controller.start,
        onDismiss: controller.dismissError,
      ),
      BankDownloadPhase.idle => _OfferCard(
        onDownload: controller.start,
        onNotNow: controller.declineForSession,
        onNever: controller.neverAskAgain,
      ),
      BankDownloadPhase.done => const SizedBox.shrink(),
    };
  }
}

/// The offer itself: what a bank is for, which one, and how big.
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.onDownload,
    required this.onNotNow,
    required this.onNever,
  });

  final VoidCallback onDownload;
  final VoidCallback onNotNow;
  final VoidCallback onNever;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      // The copy goes full width and the answers sit under it, wrapping to a
      // second line when they must: on a phone the three actions next to the
      // text take almost the whole card, which squeezed the text into a strip
      // one word wide and stretched the card over the screen.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.library_music, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'No soundbank yet',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Playing needs one. ${fluidR3GM.displayName} '
                      '(${fluidR3GM.sizeLabel}) is the recommended bank — free, '
                      'MIT-licensed, downloaded once.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onTertiaryContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: <Widget>[
              PopupMenuButton<String>(
                tooltip: 'More options',
                icon: Icon(Icons.more_vert, color: scheme.onTertiaryContainer),
                onSelected: (_) => onNever(),
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'never',
                    child: Text('Never ask again'),
                  ),
                ],
              ),
              TextButton(onPressed: onNotNow, child: const Text('Not now')),
              FilledButton(
                onPressed: onDownload,
                child: const Text('Download'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The download, as it goes: what is on disk out of what is expected.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.state, required this.onPause});

  final BankDownloadViewState state;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = state.bytesTotal;
    final said = total == null
        ? '${_mb(state.bytesDone)} so far'
        : '${_mb(state.bytesDone)} of ${_mb(total)}';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      // Text full width, the pause under it — same phone-width reasoning as
      // the offer card.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.downloading, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Downloading ${fluidR3GM.displayName}…',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: state.fraction),
                    const SizedBox(height: 4),
                    Text(
                      '$said — a pause keeps what is already fetched.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onTertiaryContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(onPressed: onPause, child: const Text('Pause')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The download, when it did not make it: what went wrong, and the way back.
///
/// The part file was kept — retrying continues where the bytes ran out, and
/// the message says so, because "retry" that secretly started over would be
/// a lie at 140 of 148 MB.
class _FailureCard extends StatelessWidget {
  const _FailureCard({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      // Text full width, the two answers under it — same phone-width
      // reasoning as the offer card.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'The soundbank download did not finish.',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$message What was fetched is kept — retrying continues '
                      'from there.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
              const SizedBox(width: 8),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ],
      ),
    );
  }
}

/// `bytes` as megabytes with one decimal — 148398306 bytes is `141.5 MB`,
/// which is what the progress line wants; the rounded `148 MB` is the
/// advertised size and lives on [RecommendedBank.sizeLabel].
String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
