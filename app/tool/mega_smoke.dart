import 'dart:io';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:bandstand/io/mega/mega_client.dart';
import 'package:http/http.dart' as http;

/// One live round trip against the real MEGA folder, from the link in the
/// repo root's `.env` (ADR 0013; the link is a bearer secret — it is read
/// here and never printed).
///
///     cd app && dart run tool/mega_smoke.dart
Future<void> main() async {
  final link = _linkFromEnv();
  if (link == null) {
    stderr.writeln('no MEGA_FOLDER_LINK in .env or the environment');
    exit(2);
  }

  final client = MegaFolderClient(
    MegaFolderLink.parse(link),
    httpClient: http.Client(),
  );
  stdout.writeln('fetching the node tree…');
  final manifest = await LibraryManifest.fetch(client);
  final files = manifest.allEntries.toList();
  final totalBytes = files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
  stdout.writeln('library: ${manifest.rootName}');
  stdout.writeln('volumes: ${manifest.volumes.length}');
  stdout.writeln('files: ${files.length} (${totalBytes / 1000 / 1000} MB)');

  // The smallest file is the cheapest proof that the whole pipe — keys,
  // attributes, CTR, the chunk MAC — matches what MEGA actually serves.
  final smallest = files.reduce((a, b) => a.sizeBytes <= b.sizeBytes ? a : b);
  stdout.writeln(
    'downloading the smallest file: ${smallest.name} '
    '(${smallest.sizeBytes} bytes)…',
  );
  final download = await client.openFile(smallest.id);
  final received = <int>[];
  await for (final chunk in download.plaintext) {
    received.addAll(chunk);
    download.mac.add(chunk);
  }
  if (received.length != smallest.sizeBytes) {
    stderr.writeln(
      'size mismatch: node said ${smallest.sizeBytes}, got ${received.length}',
    );
    exit(1);
  }
  final metaMac = megaBase64Encode(download.mac.condense());
  if (metaMac != download.key.metaMacBase64) {
    stderr.writeln(
      'meta-MAC mismatch: computed $metaMac, key says '
      '${download.key.metaMacBase64}',
    );
    exit(1);
  }
  stdout.writeln('verified: ${received.length} bytes, meta-MAC matches');
  exit(0);
}

String? _linkFromEnv() {
  final fromEnvironment = Platform.environment['MEGA_FOLDER_LINK'];
  if (fromEnvironment != null && fromEnvironment.trim().isNotEmpty) {
    return fromEnvironment.trim();
  }
  final file = File('../.env');
  if (!file.existsSync()) {
    return null;
  }
  for (final line in file.readAsLinesSync()) {
    final match = RegExp(r'^\s*MEGA_FOLDER_LINK\s*=\s*(.+)$').firstMatch(line);
    if (match != null) {
      return match.group(1)!.trim();
    }
  }
  return null;
}
