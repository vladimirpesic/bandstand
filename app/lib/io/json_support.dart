/// Small readers used by every codec in this layer.
///
/// The point of them is that a malformed file fails with a message naming the
/// field, at load, rather than throwing a `TypeError` three layers down or —
/// worse — reading as a plausible but wrong song.
library;

/// A file that cannot be read.
class SongFormatException implements Exception {
  /// Create a format exception.
  const SongFormatException(this.message, {this.field});

  /// What is wrong, in words.
  final String message;

  /// Which field, if it is about one.
  final String? field;

  @override
  String toString() =>
      field == null ? 'Bad file: $message' : 'Bad file at "$field": $message';
}

/// Read a JSON object, or fail naming [field].
Map<String, Object?> readObject(Object? value, String field) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw SongFormatException('expected an object', field: field);
}

/// Read a JSON list, or fail naming [field].
List<Object?> readList(Object? value, String field) {
  if (value is List) {
    return value;
  }
  throw SongFormatException('expected a list', field: field);
}

/// Read a string, or fail naming [field].
String readString(Object? value, String field) {
  if (value is String) {
    return value;
  }
  throw SongFormatException('expected a string', field: field);
}

/// Read a non-empty string, or fail naming [field].
String readNonEmptyString(Object? value, String field) {
  final text = readString(value, field);
  if (text.trim().isEmpty) {
    throw SongFormatException('must not be empty', field: field);
  }
  return text;
}

/// Read an integer, or fail naming [field].
int readInt(Object? value, String field) {
  if (value is int) {
    return value;
  }
  if (value is double && value == value.roundToDouble()) {
    return value.toInt();
  }
  throw SongFormatException('expected a whole number', field: field);
}

/// Read a number as a double, or fail naming [field].
double readDouble(Object? value, String field) {
  if (value is num && value.isFinite) {
    return value.toDouble();
  }
  throw SongFormatException('expected a number', field: field);
}

/// Read a boolean, or fail naming [field].
bool readBool(Object? value, String field) {
  if (value is bool) {
    return value;
  }
  throw SongFormatException('expected true or false', field: field);
}

/// Read an ISO-8601 timestamp, or fail naming [field].
DateTime readTimestamp(Object? value, String field) {
  final text = readString(value, field);
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    throw SongFormatException('expected an ISO-8601 timestamp', field: field);
  }
  return parsed.toUtc();
}

/// Read a list of strings, or fail naming [field].
List<String> readStringList(Object? value, String field) => <String>[
  for (final entry in readList(value, field)) readString(entry, field),
];

/// Read a string-to-string map, or fail naming [field].
Map<String, String> readStringMap(Object? value, String field) {
  final object = readObject(value, field);
  return <String, String>{
    for (final entry in object.entries)
      entry.key: readString(entry.value, '$field.${entry.key}'),
  };
}

/// Read an enum value by name, or fail naming [field].
T readEnum<T extends Enum>(Object? value, List<T> values, String field) {
  final text = readString(value, field);
  for (final candidate in values) {
    if (candidate.name == text) {
      return candidate;
    }
  }
  throw SongFormatException(
    '"$text" is not one of ${values.map((v) => v.name).join(', ')}',
    field: field,
  );
}
