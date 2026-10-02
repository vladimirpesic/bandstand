import 'dart:async';
import 'dart:io';

import 'package:bandstand/io/bank_download.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/state/playback_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Builds the downloader the controller runs.
///
/// A seam for tests: the production builder points at the real mirrors, and a
/// test can point one at a loopback server serving a few megabytes of known
/// bytes — real HTTP, real files, the whole path — without the network.
typedef BankDownloaderBuilder = BankDownloader Function(Directory directory);

/// Where the recommended bank comes from.
final bankDownloaderProvider = Provider<BankDownloaderBuilder>(
  (ref) =>
      (directory) => BankDownloader(directory: directory, bank: fluidR3GM),
);

/// Whether the user has refused the recommended bank for good, read from the
/// choice file next to where the bank would go.
///
/// Invalidation after [BankDownloadController.neverAskAgain] is what makes
/// the offer leave without a restart.
final bankOfferDeclinedProvider = FutureProvider<bool>((ref) async {
  final library = await ref.watch(songLibraryProvider.future);
  return RecommendedBankChoice.isDeclined(library.soundbanksDirectory);
});

/// What the bank download is doing.
enum BankDownloadPhase {
  /// Nothing running. There may still be a partial download waiting on disk.
  idle,

  /// Fetching, verifying, or moving into place.
  downloading,

  /// The bank is on disk and in the picker.
  done,

  /// Every mirror failed. The partial file, if any, was kept.
  failed,
}

/// What the download UI is showing.
class BankDownloadViewState {
  /// Create a state.
  const BankDownloadViewState({
    this.phase = BankDownloadPhase.idle,
    this.bytesDone = 0,
    this.bytesTotal,
    this.errorMessage,
    this.sessionDeclined = false,
  });

  /// What the download is doing right now.
  final BankDownloadPhase phase;

  /// How many bytes are safely on disk. Between runs this is read from the
  /// part file, so a pause survives the app being killed.
  final int bytesDone;

  /// How many bytes the whole bank is, once anything has reported it.
  final int? bytesTotal;

  /// Why the download failed, or null.
  final String? errorMessage;

  /// Whether the user declined the offer for this run of the app. A session
  /// refusal is not the permanent one — that is `bankOfferDeclinedProvider`.
  final bool sessionDeclined;

  /// Whether a partial download is waiting to be resumed.
  bool get isPartial => phase == BankDownloadPhase.idle && bytesDone > 0;

  /// The fraction done, 0 to 1, or null while the total is unknown.
  double? get fraction =>
      bytesTotal == null || bytesTotal == 0 ? null : bytesDone / bytesTotal!;

  /// A copy with some fields replaced.
  BankDownloadViewState copyWith({
    BankDownloadPhase? phase,
    int? bytesDone,
    int? bytesTotal,
    bool clearBytesTotal = false,
    String? errorMessage,
    bool clearError = false,
    bool? sessionDeclined,
  }) => BankDownloadViewState(
    phase: phase ?? this.phase,
    bytesDone: bytesDone ?? this.bytesDone,
    bytesTotal: clearBytesTotal ? null : (bytesTotal ?? this.bytesTotal),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    sessionDeclined: sessionDeclined ?? this.sessionDeclined,
  );
}

/// Downloads the recommended bank into the library's `soundbanks/` folder.
///
/// The controller is deliberately thin: every decision that matters —
/// resuming, verifying, failing over between mirrors — belongs to
/// [BankDownloader], where it can be tested against a real server. This layer
/// turns results into state, and refreshes the soundbank list when the bank
/// lands so the picker finds it without anybody wiring a callback.
class BankDownloadController extends Notifier<BankDownloadViewState> {
  bool _cancelRequested = false;
  bool _disposed = false;

  @override
  BankDownloadViewState build() {
    ref.onDispose(() {
      // Disposing the provider is the one cancellation nobody presses a
      // button for, and the one that must not leave a socket behind.
      _disposed = true;
      _cancelRequested = true;
    });
    // The truth about a download interrupted by an app kill lives on disk,
    // not in memory: the part file is the progress. Fire-and-forget on
    // purpose — it must not postpone the first frame — and the guards below
    // keep it from overwriting anything if it loses the race with a user
    // who has already tapped.
    unawaited(_announcePartialOnDisk());
    return const BankDownloadViewState();
  }

  /// Let the idle state tell the truth about a part left by an earlier run:
  /// "resume", with the bytes that are already there, instead of a fresh
  /// "download" that quietly resumes anyway.
  Future<void> _announcePartialOnDisk() async {
    try {
      final library = await ref.read(songLibraryProvider.future);
      final part = ref
          .read(bankDownloaderProvider)(library.soundbanksDirectory)
          .partFile;
      final onDisk = part.existsSync() ? part.lengthSync() : 0;
      if (onDisk > 0 &&
          state.phase == BankDownloadPhase.idle &&
          state.bytesDone == 0 &&
          !state.sessionDeclined) {
        _setState(state.copyWith(bytesDone: onDisk));
      }
    } on Object {
      // A library that will not open announces nothing; the offer and the
      // controls still work, and the downloader itself resumes regardless.
    }
  }

  /// Start the download, resuming a partial one if it is there.
  Future<void> start() async {
    if (state.phase == BankDownloadPhase.downloading) {
      return;
    }
    _cancelRequested = false;
    _setState(
      state.copyWith(
        phase: BankDownloadPhase.downloading,
        clearError: true,
        clearBytesTotal: true,
      ),
    );
    try {
      final library = await ref.read(songLibraryProvider.future);
      final downloader = ref.read(bankDownloaderProvider)(
        library.soundbanksDirectory,
      );
      final result = await downloader.download(
        onProgress: (progress) {
          if (_disposed || state.phase != BankDownloadPhase.downloading) {
            return;
          }
          _setState(
            state.copyWith(
              bytesDone: progress.bytesDone,
              bytesTotal: progress.bytesTotal,
              clearBytesTotal: progress.bytesTotal == null,
            ),
          );
        },
        isCancelled: () => _cancelRequested,
      );
      if (_disposed) {
        return;
      }
      if (result == BankDownloadResult.cancelled) {
        // Keep the last progress: it is what tells the next screenful that
        // there is something to resume rather than something to start.
        _setState(state.copyWith(phase: BankDownloadPhase.idle));
      } else {
        // The bank list must not be a stale cache of a folder the app itself
        // just changed.
        ref.invalidate(soundbanksProvider);
        _setState(
          state.copyWith(
            phase: BankDownloadPhase.done,
            bytesDone: state.bytesTotal ?? state.bytesDone,
            clearError: true,
          ),
        );
      }
    } on Object catch (error) {
      if (!_disposed) {
        _setState(
          state.copyWith(
            phase: BankDownloadPhase.failed,
            errorMessage: '$error',
          ),
        );
      }
    }
  }

  /// Ask the running download to stop, keeping what is already fetched.
  void cancel() {
    if (state.phase == BankDownloadPhase.downloading) {
      _cancelRequested = true;
    }
  }

  /// Hide the offer for this run of the app.
  void declineForSession() {
    _setState(state.copyWith(sessionDeclined: true));
  }

  /// Hide the offer for good, on disk.
  ///
  /// Best effort by design: if the choice file cannot be written — a
  /// read-only folder, say — the offer is still gone for this session, and
  /// the download controls on the audio screen remain the way back in.
  Future<void> neverAskAgain() async {
    _setState(state.copyWith(sessionDeclined: true));
    try {
      final library = await ref.read(songLibraryProvider.future);
      await RecommendedBankChoice.markDeclined(library.soundbanksDirectory);
    } on Object {
      // Recorded nowhere on purpose: the session refusal already happened,
      // and a toast about a dot-file is not the user's problem.
    }
    ref.invalidate(bankOfferDeclinedProvider);
  }

  /// Clear the failure, back to idle. Starting again is [start].
  void dismissError() {
    _setState(state.copyWith(phase: BankDownloadPhase.idle, clearError: true));
  }

  void _setState(BankDownloadViewState next) {
    if (!_disposed) {
      state = next;
    }
  }
}

/// The download, for the UI to watch.
final bankDownloadProvider =
    NotifierProvider<BankDownloadController, BankDownloadViewState>(
      BankDownloadController.new,
    );
