import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A soundbank Bandstand can fetch for itself, pinned to exact bytes.
///
/// The size and the SHA-256 digest are part of the definition, not decoration:
/// every mirror is expected to serve the *same* file, and a download that does
/// not reproduce the digest byte for byte is thrown away no matter which
/// mirror it came from. That is what makes trying mirrors in turn — and
/// resuming a download from one mirror onto another — safe.
class RecommendedBank {
  /// Define a bank.
  const RecommendedBank({
    required this.fileName,
    required this.displayName,
    required this.sizeBytes,
    required this.sha256,
    required this.mirrors,
  });

  /// The file name it is stored under, extension included.
  final String fileName;

  /// What the UI calls it.
  final String displayName;

  /// How many bytes it is, exactly.
  final int sizeBytes;

  /// Its SHA-256 digest, hex, lowercase.
  final String sha256;

  /// Where it can be fetched from, in the order they should be tried.
  final List<Uri> mirrors;

  /// Its size, as a person would say it — the same convention as
  /// `SoundbankFile.sizeLabel`, so the offer and the picker agree about the
  /// same file.
  String get sizeLabel {
    const megabyte = 1024 * 1024;
    return '${(sizeBytes / megabyte).toStringAsFixed(1)} MB';
  }
}

/// The bank Bandstand recommends: Frank Wen's FluidR3 GM.
///
/// 148 MB of General MIDI, MIT-licensed, and the de-facto standard free GM
/// bank — the same bytes the Debian `fluid-soundfont-gm` package installs,
/// so the digest below is stable and third parties can serve them too. It is
/// far too large to bundle in the binary (the sampler maps a bank from a real
/// file, and an APK asset is not one — see `docs/rules/bank-download.md`), so
/// it is fetched on demand into the library's `soundbanks/` folder instead.
///
/// The mirrors, in order:
///
/// 1. The asset of the newest GitHub release — the release workflow attaches
///    this same file to every release, and `releases/latest/download/` is a
///    stable URL that keeps pointing at it as versions roll. Release
///    downloads are unmetered, and they answer `Range` requests properly,
///    which is what resuming needs.
/// 2. The GitHub LFS object on `main` (`soundfonts/FluidR3_GM.sf2`, see
///    `soundfonts/README.md`) — the source copy the release asset is cut
///    from, live one release earlier than the first tag.
///
/// Repointing, adding or reordering a mirror is a one-line change here; the
/// pinned digest does the rest.
final RecommendedBank fluidR3GM = RecommendedBank(
  fileName: 'FluidR3_GM.sf2',
  displayName: 'FluidR3 GM',
  sizeBytes: 148398306,
  sha256: '74594e8f4250680adf590507a306655a299935343583256f3b722c48a1bc1cb0',
  mirrors: <Uri>[
    Uri.parse(
      'https://github.com/vladimirpesic/bandstand/releases/latest/download'
      '/FluidR3_GM.sf2',
    ),
    Uri.parse(
      'https://media.githubusercontent.com/media/vladimirpesic/bandstand/main'
      '/soundfonts/FluidR3_GM.sf2',
    ),
  ],
);

/// How a download is going.
class BankDownloadProgress {
  /// Report progress.
  const BankDownloadProgress({required this.bytesDone, this.bytesTotal});

  /// Bytes safely on disk for this download, including any resumed part.
  final int bytesDone;

  /// How many bytes the whole bank is, or null when the server did not say.
  final int? bytesTotal;

  /// The fraction done, 0 to 1, or null when the total is unknown.
  double? get fraction =>
      bytesTotal == null || bytesTotal == 0 ? null : bytesDone / bytesTotal!;
}

/// How [BankDownloader.download] ended.
enum BankDownloadResult {
  /// The bank was fetched, verified and moved into place.
  downloaded,

  /// A file of that name was already there; nothing was touched.
  alreadyPresent,

  /// The caller asked the download to stop. The part file is kept.
  cancelled,
}

/// Every mirror failed, and what each one said.
class BankDownloadException implements Exception {
  /// Create the exception, one message per mirror.
  BankDownloadException(this.failures);

  /// What went wrong, in the order the mirrors were tried.
  final List<String> failures;

  @override
  String toString() =>
      'The soundbank could not be downloaded:\n'
      '${failures.map((failure) => '· $failure').join('\n')}';
}

/// The mirror served something that cannot be part of the pinned bank.
class _CorruptDownload implements Exception {
  const _CorruptDownload(this.reason);

  final String reason;
}

/// The mirror could not be used, but the bytes already fetched may be fine.
class _MirrorFailed implements Exception {
  const _MirrorFailed(this.reason);

  final String reason;
}

/// Fetches a [RecommendedBank] into a directory, reliably.
///
/// "Reliably" is a contract, and each clause is a decision:
///
/// * **Nothing partial is ever installed.** Bytes land in
///   `<file name>.part` next to the target, and only a part whose length and
///   SHA-256 both match the pinned values is renamed over the target. The
///   rename happens within one directory, so on every platform Bandstand runs
///   on it is atomic: a bank either appears whole or does not appear.
/// * **An interrupted download costs nothing.** The part file *is* the
///   progress; a later attempt sends `Range: bytes=<part size>-` and appends.
///   Kill the app, lose the network, run out of disk — the bytes already
///   fetched are kept, and resuming onto a *different* mirror is safe because
///   the digest still judges the finished whole.
/// * **A server that ignores or rejects the range is not an error.** A plain
///   `200` restarts from zero and truncates the part; a `416` deletes the
///   stale part and retries the same mirror from the top.
/// * **A crash between the last byte and the rename loses nothing.** A part
///   that is already whole and verifies is renamed into place without any
///   network at all.
/// * **Mirrors are tried in order, each exactly once.** A network failure
///   keeps the part (it may still be worth resuming); corruption — wrong size
///   or wrong digest — deletes it, because those bytes cannot be a prefix of
///   any valid bank.
/// * **A bank already on disk is never overwritten.** If the user put their
///   own `FluidR3_GM.sf2` there by hand, it is theirs, whatever its digest.
/// * **The download is pausable.** [isCancelled] is polled between chunks,
///   and by a watchdog when the server has gone quiet — a stalled mirror
///   sends no chunks to poll between, and "pause" must work precisely then.
///   Cancelling keeps the part file and returns promptly.
///
/// There is deliberately no overall-time timeout: 148 MB over a slow hotel
/// network is an hour well spent. Only the connection has one.
class BankDownloader {
  /// Create a downloader that stores [bank] in [directory].
  BankDownloader({required this.directory, required this.bank});

  /// The directory the bank will live in — the library's `soundbanks/`.
  final Directory directory;

  /// Which bank this downloads.
  final RecommendedBank bank;

  /// Where the bank will be once complete.
  File get targetFile =>
      File('${directory.path}${Platform.pathSeparator}${bank.fileName}');

  /// Where the bytes land while the download is in flight.
  File get partFile =>
      File('${directory.path}${Platform.pathSeparator}${bank.fileName}.part');

  /// Fetch the bank into [directory].
  ///
  /// [onProgress] is called at most about once per megabyte — a 148 MB bank
  /// arrives in thousands of socket chunks, and no progress bar needs that
  /// many rebuilds. [isCancelled] is polled between chunks, and at least
  /// every 250 ms even when the mirror has gone silent.
  Future<BankDownloadResult> download({
    void Function(BankDownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (targetFile.existsSync()) {
      return BankDownloadResult.alreadyPresent;
    }
    await directory.create(recursive: true);
    final recovered = await _recoverFinishedPart();
    if (recovered) {
      return BankDownloadResult.downloaded;
    }
    _deletePartIfLongerThanTheBank();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final failures = <String>[];
    try {
      for (final mirror in bank.mirrors) {
        try {
          return await _fromMirror(
            client,
            mirror,
            onProgress,
            isCancelled ?? () => false,
          );
        } on _CorruptDownload catch (error) {
          // Bytes that cannot belong to the pinned bank would poison a later
          // resume onto a good mirror, so they go.
          _deletePart();
          failures.add('${mirror.host}: ${error.reason}');
        } on _MirrorFailed catch (error) {
          // The part may still be good — keep it for the next mirror, or the
          // next run.
          failures.add('${mirror.host}: ${error.reason}');
        } on IOException catch (error) {
          failures.add('${mirror.host}: $error');
        }
      }
    } finally {
      // Forceful on purpose: a cancelled download leaves its response open,
      // and the socket should not outlive the attempt.
      client.close(force: true);
    }
    throw BankDownloadException(failures);
  }

  /// Rename a part that is already whole and verifies into place.
  ///
  /// The window between the last verified byte and the rename is small but
  /// real — process death in exactly it should not cost the whole download.
  /// Returns true if the bank was thereby completed.
  Future<bool> _recoverFinishedPart() async {
    if (!partFile.existsSync() || partFile.lengthSync() != bank.sizeBytes) {
      return false;
    }
    if (await _sha256Of(partFile) != bank.sha256) {
      _deletePart();
      return false;
    }
    await partFile.rename(targetFile.path);
    return true;
  }

  /// Try one mirror, resuming from the part file if there is one.
  Future<BankDownloadResult> _fromMirror(
    HttpClient client,
    Uri mirror,
    void Function(BankDownloadProgress progress)? onProgress,
    bool Function() isCancelled,
  ) async {
    var resumeFrom = partFile.existsSync() ? partFile.lengthSync() : 0;
    while (true) {
      final request = await client.openUrl('GET', mirror);
      if (resumeFrom > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final response = await request.close();
      final status = response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        if (resumeFrom == 0) {
          throw _MirrorFailed(
            'the server rejected a request it was sent (HTTP $status)',
          );
        }
        // The part cannot be a prefix of what this mirror serves. Drop it and
        // give the same mirror one chance from the top.
        _deletePart();
        resumeFrom = 0;
        continue;
      }
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        await response.drain<void>();
        throw _MirrorFailed('HTTP $status');
      }

      // A 206 means the mirror honoured the range and this response is the
      // tail; a 200 means it ignored it and this response is the whole file,
      // so the part is truncated and written over.
      final appending = status == HttpStatus.partialContent;
      final total = response.contentLength < 0
          ? null
          : appending
          ? resumeFrom + response.contentLength
          : response.contentLength;

      var done = appending ? resumeFrom : 0;
      var reported = done;
      final sink = partFile.openWrite(
        mode: appending ? FileMode.append : FileMode.write,
      );

      // Cancellation cannot wait for the next chunk to arrive: a stalled
      // server sends none, and "pause" must work precisely then. The chunk
      // path reacts between chunks; a timer watches for the silence.
      var cancelled = false;
      Object? thrown;
      var settled = false;
      final finished = Completer<void>();
      void settle() {
        if (!settled) {
          settled = true;
          finished.complete();
        }
      }

      final subscription = response.listen(
        (chunk) {
          if (isCancelled()) {
            cancelled = true;
            settle();
            return;
          }
          sink.add(chunk);
          done += chunk.length;
          if (done - reported >= 1024 * 1024) {
            reported = done;
            onProgress?.call(
              BankDownloadProgress(bytesDone: done, bytesTotal: total),
            );
          }
        },
        onError: (Object error) {
          thrown = error;
          settle();
        },
        onDone: settle,
        cancelOnError: true,
      );
      final watcher = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (isCancelled()) {
          cancelled = true;
          settle();
        }
      });

      await finished.future;
      watcher.cancel();
      await subscription.cancel();
      try {
        await sink.flush();
        await sink.close();
      } on Object catch (error) {
        // A full disk lands here, on close, after every byte seemed fine.
        // The part keeps whatever reached the platter; the next attempt
        // resumes from the file's honest length.
        thrown ??= error;
      }
      if (cancelled) {
        return BankDownloadResult.cancelled;
      }
      final error = thrown;
      if (error != null) {
        throw error;
      }
      onProgress?.call(
        BankDownloadProgress(bytesDone: done, bytesTotal: total),
      );

      // The part must now be exactly the bank, byte for byte.
      final length = partFile.lengthSync();
      if (length != bank.sizeBytes) {
        throw _CorruptDownload(
          'served $length bytes; the bank pinned here is ${bank.sizeBytes}',
        );
      }
      final digest = await _sha256Of(partFile);
      if (digest != bank.sha256) {
        throw _CorruptDownload('the bytes do not match the pinned digest');
      }
      await partFile.rename(targetFile.path);
      return BankDownloadResult.downloaded;
    }
  }

  /// A part longer than the bank can only be garbage; it cannot be a prefix
  /// of the pinned bytes, and asking a server for a range past its end would
  /// only earn a 416.
  void _deletePartIfLongerThanTheBank() {
    if (partFile.existsSync() && partFile.lengthSync() > bank.sizeBytes) {
      _deletePart();
    }
  }

  void _deletePart() {
    if (partFile.existsSync()) {
      partFile.deleteSync();
    }
  }

  /// The file's SHA-256, hex, lowercase — read as a stream, because a bank
  /// is the one file in the library that would rather not be in RAM whole.
  Future<String> _sha256Of(File file) async {
    final digest = await sha256.bind(file.openRead()).last;
    return digest.toString();
  }
}

/// Remembers, next to where the bank would go, that the user has refused the
/// recommended bank for good.
///
/// A dot-file inside the soundbanks folder: `SoundbankLibrary` only ever
/// lists `.sf2` files, so it is invisible to the picker, and it travels with
/// the library if the folder is copied.
abstract final class RecommendedBankChoice {
  static const String _fileName = '.recommended-bank.json';

  /// The file the choice lives in for [directory].
  static File fileFor(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}$_fileName');

  /// Whether the user has declined the offer for good.
  ///
  /// A file that cannot be read or parsed counts as "not declined": the
  /// honest default is to ask once more, not to nag-proof the app by
  /// accident.
  static Future<bool> isDeclined(Directory directory) async {
    try {
      final decoded = jsonDecode(await fileFor(directory).readAsString());
      return decoded is Map && decoded['declined'] == true;
    } on Exception {
      return false;
    }
  }

  /// Record the refusal. Written the way everything in the library is: to a
  /// staging name, then renamed, so a crash cannot leave half a decision.
  static Future<void> markDeclined(Directory directory) async {
    await directory.create(recursive: true);
    final file = fileFor(directory);
    final staging = File('${file.path}.tmp');
    await staging.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(<String, Object?>{'declined': true}),
    );
    await staging.rename(file.path);
  }
}
