import 'package:bandstand/io/importers/ireal_import.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pasting an iReal Pro URL into the library (§5.2).
///
/// The highest-leverage feature in the plan: it is how a library gets populated
/// in an evening rather than a year. It says what it read and what it could
/// not, because an import that quietly loses a tune is worse than one that
/// refuses it.
class ImportDialog extends ConsumerStatefulWidget {
  const ImportDialog({super.key});

  /// Show the dialog, returning how many songs were brought in.
  static Future<int?> show(BuildContext context) => showDialog<int>(
    context: context,
    builder: (context) => const ImportDialog(),
  );

  @override
  ConsumerState<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<ImportDialog> {
  final TextEditingController _url = TextEditingController();
  bool _busy = false;
  String? _error;
  IRealImportResult? _result;

  @override
  void initState() {
    super.initState();
    _pasteFromClipboard();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (mounted && IRealImporter.looksLikeIReal(text)) {
      setState(() => _url.text = text);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      // Routed by content, not by asking. An iReal URL announces itself with
      // its scheme, MusicXML with its document element, and anything else with
      // bar lines in it is a plain text lead sheet (§5.2). Making the user
      // choose would be asking them for something the computer can see.
      final text = _url.text.trim();
      final controller = ref.read(libraryControllerProvider);
      final result = IRealImporter.looksLikeIReal(text)
          ? await controller.importIRealUrl(text)
          : await controller.importText(text);
      if (mounted) {
        setState(() {
          _busy = false;
          _result = result;
        });
      }
    } on IRealScramblingNotSupported catch (error) {
      _fail('$error');
    } on NotAnIRealUrl catch (error) {
      _fail('$error');
    } on Object catch (error) {
      _fail('$error');
    }
  }

  void _fail(String message) {
    if (mounted) {
      setState(() {
        _busy = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Import from iReal Pro'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Paste an irealbook:// URL, a MusicXML document, or a chart '
              'typed as text — Bandstand works out which. One iReal URL can '
              'hold a whole book.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              maxLines: 4,
              minLines: 2,
              autofocus: true,
              // The Import button is gated on this field being non-empty, so
              // the dialog has to rebuild as it is typed into.
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'URL, MusicXML, or a typed chart',
                hintText: 'irealbook://...   or   | Dm7 | G7 | Cmaj7 |',
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            if (result != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                result.songs.isEmpty
                    ? 'Nothing was imported.'
                    : 'Imported ${result.songs.length} '
                          'chart${result.songs.length == 1 ? '' : 's'}'
                          '${result.playlistName == null ? '' : ' from '
                                    '"${result.playlistName}"'}.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (result.problems.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '${result.problems.length} thing'
                  '${result.problems.length == 1 ? '' : 's'} could not be read:',
                  style: TextStyle(color: scheme.error),
                ),
                for (final problem in result.problems.take(6))
                  Text(
                    '• $problem',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
              ],
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).pop(result?.songs.length),
          child: Text(result == null ? 'Cancel' : 'Done'),
        ),
        FilledButton(
          onPressed: _busy || _url.text.trim().isEmpty ? null : _import,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Import'),
        ),
      ],
    );
  }
}
