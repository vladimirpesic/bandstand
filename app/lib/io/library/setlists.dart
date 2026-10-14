import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bandstand/io/atomic_write.dart';
import 'package:bandstand/io/json_support.dart';

/// The one setlist the app owns rather than stores: the name of the
/// default, derived setlist, and therefore a name no user setlist may
/// take (in any casing).
const String favoritesSetName = 'Favorites';

/// One setlist the user made: a name and the tracks it holds, as entry
/// ids — the MEGA node handles the manifest reconciles by (§4), stable
/// across renames of file or folder. A setlist is references, never
/// copies: deleting one deletes the list, and the library is untouched.
class Setlist {
  /// Create the list.
  const Setlist({required this.id, required this.name, required this.entryIds});

  /// A fresh, empty list with a new id and the given name.
  ///
  /// The name is only checked where the whole collection can see its
  /// siblings — [Setlists.problemWithName].
  factory Setlist.named(String name) =>
      Setlist(id: newSetlistId(), name: name, entryIds: const <String>[]);

  /// A new setlist id: creation time first, so ids sort by age, then
  /// enough entropy that two made in the same microsecond cannot meet.
  static String newSetlistId() {
    final random = Random.secure();
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final noise = List<int>.generate(
      6,
      (_) => random.nextInt(36),
    ).map((digit) => digit.toRadixString(36)).join();
    return 's$time$noise';
  }

  /// The list's own id, stable across renames.
  final String id;

  /// The list's name, trimmed and non-empty.
  final String name;

  /// The member entry ids, in the order they were added. Unique by
  /// construction — [withEntryAdded] is the only way in, and it refuses
  /// a duplicate — so one tune can never appear twice.
  final List<String> entryIds;

  /// Whether [entryId] is a member.
  bool contains(String entryId) => entryIds.contains(entryId);

  /// The list with [entryId] appended — unless it is already a member,
  /// in which case this is the same list: duplication is impossible.
  Setlist withEntryAdded(String entryId) => contains(entryId)
      ? this
      : Setlist(id: id, name: name, entryIds: <String>[...entryIds, entryId]);

  /// The list without [entryId]; the same list when it was never a
  /// member.
  Setlist withEntryRemoved(String entryId) => !contains(entryId)
      ? this
      : Setlist(
          id: id,
          name: name,
          entryIds: <String>[...entryIds..remove(entryId)],
        );

  @override
  bool operator ==(Object other) =>
      other is Setlist &&
      other.id == id &&
      other.name == name &&
      _idListEquals(other.entryIds, entryIds);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(entryIds));

  @override
  String toString() => 'Setlist($id, $name, ${entryIds.length} tunes)';
}

/// The setlists the user has made, persisted as one JSON file in the
/// app's support directory.
///
/// "Favorites" is not in here and never can be: it is every bookmarked
/// track, derived live from the mirror's saved flags — nothing to store,
/// nothing to drift out of sync with the bookmark icon.
class Setlists {
  /// Create the value. [problem] is non-null only when the file on disk
  /// could not be read — then the list is empty and every change is
  /// refused until the file is fixed, because a write over an unread
  /// file is silent data loss (§2's discipline, applied to setlists).
  const Setlists({this.setlists = const <Setlist>[], this.problem});

  /// The file's name inside the support directory.
  static const String fileName = 'setlists.json';

  /// The one version there has ever been.
  static const int _version = 1;

  /// The setlists, in creation order.
  final List<Setlist> setlists;

  /// Why the file could not be read, when it could not.
  final String? problem;

  /// Whether any change may be made right now.
  bool get isWritable => problem == null;

  /// Parse the file, or throw naming what is wrong.
  ///
  /// A missing file is not an error — it is the first run, and no
  /// setlists is the answer. The shape is validated the way every file
  /// here is: a bad field fails with its name, at load.
  static Setlists load(File file) {
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      return const Setlists();
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const JsonFormatException(
        'the setlists file is not JSON; fix or remove it to start over',
      );
    }
    final object = readObject(decoded, 'setlists');
    final version = object['version'];
    if (version != null && readInt(version, 'setlists.version') != _version) {
      throw JsonFormatException(
        'unknown setlists file version $version',
        field: 'setlists.version',
      );
    }
    final raw = object['setlists'] ?? const <Object?>[];
    final lists = readList(raw, 'setlists.setlists');
    return Setlists(
      setlists: <Setlist>[
        for (final entry in lists)
          _setlistFromJson(entry, 'setlists.setlists[]'),
      ],
    );
  }

  static Setlist _setlistFromJson(Object? json, String field) {
    final object = readObject(json, field);
    // A hand-edited duplicate entry id is dropped at load, not written
    // back on the next save — first in wins, silently, because there is
    // nothing better to do with an anonymous extra.
    final ids = readStringList(object['entryIds'], '$field.entryIds');
    final seen = <String>{};
    return Setlist(
      id: readNonEmptyString(object['id'], '$field.id'),
      name: readNonEmptyString(object['name'], '$field.name'),
      entryIds: <String>[
        for (final id in ids)
          if (seen.add(id)) id,
      ],
    );
  }

  /// Write to [file], atomically, indented — the same discipline as
  /// every file this layer owns.
  Future<void> saveTo(File file) async {
    await file.parent.create(recursive: true);
    await writeAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'version': _version,
        'setlists': <Object?>[
          for (final setlist in setlists)
            <String, Object?>{
              'id': setlist.id,
              'name': setlist.name,
              'entryIds': setlist.entryIds,
            },
        ],
      }),
    );
  }

  /// The list with this id, when there is one.
  Setlist? byId(String id) {
    for (final setlist in setlists) {
      if (setlist.id == id) {
        return setlist;
      }
    }
    return null;
  }

  /// Why [candidate] cannot be a setlist name here, in words for a
  /// dialog; null when it can. Names are trimmed; they cannot be empty,
  /// cannot repeat (in any casing), and cannot take the default's name.
  String? problemWithName(String candidate, {String? exceptId}) {
    final name = candidate.trim();
    if (name.isEmpty) {
      return 'Give the setlist a name.';
    }
    if (name.toLowerCase() == favoritesSetName.toLowerCase()) {
      return '"$favoritesSetName" is the bookmarked tracks; '
          'it needs no setlist of its own.';
    }
    for (final setlist in setlists) {
      if (setlist.id != exceptId &&
          setlist.name.toLowerCase() == name.toLowerCase()) {
        return 'There is already a setlist called "$name".';
      }
    }
    return null;
  }

  /// The collection with [setlist] replacing the list of the same id, or
  /// appended when there is none. Callers validate the name first —
  /// [problemWithName] — so this stays a pure splice.
  Setlists withSetlist(Setlist setlist) {
    final next = <Setlist>[];
    var replaced = false;
    for (final existing in setlists) {
      if (existing.id == setlist.id) {
        next.add(setlist);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) {
      next.add(setlist);
    }
    return Setlists(setlists: next, problem: problem);
  }

  /// The collection without the list of this id; unchanged when there
  /// is none. The tracks it pointed at are, as always, untouched.
  Setlists withoutSetlist(String id) => Setlists(
    setlists: <Setlist>[
      for (final setlist in setlists)
        if (setlist.id != id) setlist,
    ],
    problem: problem,
  );

  @override
  bool operator ==(Object other) =>
      other is Setlists && _idListEquals(other.setlists, setlists);

  @override
  int get hashCode => Object.hashAll(setlists);

  @override
  String toString() =>
      'Setlists(${setlists.length} lists'
      '${problem == null ? '' : ', unreadable'})';
}

bool _idListEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
