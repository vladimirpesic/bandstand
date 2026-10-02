/// Pitch, harmony, meter and position — the layer everything else depends on
/// (§4.1, §4.2).
///
/// Nothing here imports Flutter, and nothing here does file I/O. The chord-type
/// and scale tables are data (ADR 0006); `lib/io/harmony_assets.dart` loads them
/// and installs them into [Harmony].
library;

export 'chord_rendering_info.dart';
export 'chord_symbol.dart';
export 'chord_type.dart';
export 'chord_type_database.dart';
export 'degree.dart';
export 'ext_chord_symbol.dart';
export 'harmony_registry.dart';
export 'instrument_transposition.dart';
export 'key_signature.dart';
export 'nashville.dart';
export 'natural.dart';
export 'note.dart';
export 'pitch_spelling.dart';
export 'position.dart';
export 'scale.dart';
export 'spelling_preference.dart';
export 'time_signature.dart';
