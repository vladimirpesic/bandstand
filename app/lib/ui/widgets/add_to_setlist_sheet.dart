import 'package:bandstand/io/library/setlists.dart';
import 'package:bandstand/state/setlists.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The `+` beside a downloaded tune: one sheet, two ways in — an
/// existing setlist, or a new one with this tune as its first member.
/// "Favorites" is not listed: its membership is the bookmark itself.
Future<void> showAddToSetlistSheet(
  BuildContext context, {
  required String trackName,
  required String entryId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) =>
      AddToSetlistSheet(trackName: trackName, entryId: entryId),
);

class AddToSetlistSheet extends ConsumerStatefulWidget {
  const AddToSetlistSheet({
    super.key,
    required this.trackName,
    required this.entryId,
  });

  /// The tune being placed, for the header.
  final String trackName;

  /// The tune's entry id — the reference a setlist stores.
  final String entryId;

  @override
  ConsumerState<AddToSetlistSheet> createState() => _AddToSetlistSheetState();
}

class _AddToSetlistSheetState extends ConsumerState<AddToSetlistSheet> {
  final TextEditingController _name = TextEditingController();
  bool _naming = false;
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Say where the tune went (or why it did not), and close the sheet.
  void _finish(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).pop();
  }

  Future<void> _addTo(Setlist setlist) async {
    final problem = await ref
        .read(setlistsProvider.notifier)
        .addEntry(setlist.id, widget.entryId);
    _finish(problem ?? 'Added to "${setlist.name}".');
  }

  Future<void> _createAndAdd() async {
    final problem = await ref
        .read(setlistsProvider.notifier)
        .create(_name.text, entryId: widget.entryId);
    if (!mounted) {
      return;
    }
    if (problem == null) {
      _finish('Added to "${_name.text.trim()}".');
      return;
    }
    // A naming problem stays in the sheet, on the field, where it can be
    // fixed; anything else is said once and the sheet closes.
    if (ref.read(setlistsProvider).problemWithName(_name.text) != null) {
      setState(() => _problem = problem);
    } else {
      _finish(problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final setlists = ref.watch(setlistsProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Add "${widget.trackName}" to…',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (setlists.problem != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'The setlists file cannot be read: ${setlists.problem}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else ...<Widget>[
              Flexible(
                child: setlists.setlists.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No setlists yet — make the first one below.',
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: setlists.setlists.length,
                        itemBuilder: (context, index) {
                          final setlist = setlists.setlists[index];
                          final member = setlist.contains(widget.entryId);
                          return ListTile(
                            leading: const Icon(Icons.queue_music_outlined),
                            title: Text(setlist.name),
                            subtitle: Text(
                              setlist.entryIds.isEmpty
                                  ? 'empty'
                                  : setlist.entryIds.length == 1
                                  ? '1 tune'
                                  : '${setlist.entryIds.length} tunes',
                            ),
                            trailing: member
                                ? const Icon(Icons.check)
                                : const Icon(Icons.add),
                            // A member is shown checked and inert: a tune
                            // cannot be added twice to the same setlist.
                            onTap: member ? null : () => _addTo(setlist),
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              if (!_naming)
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('New setlist…'),
                  onTap: () => setState(() => _naming = true),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _name,
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _createAndAdd(),
                          decoration: InputDecoration(
                            labelText: 'Setlist name',
                            errorText: _problem,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _createAndAdd,
                        icon: const Icon(Icons.add),
                        label: const Text('Create'),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
