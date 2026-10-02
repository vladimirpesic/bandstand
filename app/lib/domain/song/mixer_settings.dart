/// What one voice sounds like: level, position, and which instrument.
class ChannelSettings {
  /// Create channel settings.
  ///
  /// Throws [ArgumentError] if the volume is outside `0..1`, the pan outside
  /// `-1..1`, or a MIDI value outside its range.
  ChannelSettings({
    required this.voiceId,
    this.volume = 0.8,
    this.pan = 0,
    this.muted = false,
    this.soloed = false,
    this.midiBank = 0,
    this.midiProgram = 0,
    this.transpose = 0,
  }) {
    if (voiceId.trim().isEmpty) {
      throw ArgumentError.value(voiceId, 'voiceId', 'a channel needs a voice');
    }
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw ArgumentError.value(volume, 'volume', 'must be between 0 and 1');
    }
    if (!pan.isFinite || pan < -1 || pan > 1) {
      throw ArgumentError.value(pan, 'pan', 'must be between -1 and 1');
    }
    if (midiBank < 0 || midiBank > 16383) {
      throw ArgumentError.value(midiBank, 'midiBank', 'must be 0–16383');
    }
    if (midiProgram < 0 || midiProgram > 127) {
      throw ArgumentError.value(midiProgram, 'midiProgram', 'must be 0–127');
    }
    if (transpose < -48 || transpose > 48) {
      throw ArgumentError.value(
        transpose,
        'transpose',
        'must be within four octaves',
      );
    }
  }

  /// Which rhythm voice these settings are for.
  final String voiceId;

  /// Linear gain, 0–1.
  final double volume;

  /// Stereo position, −1 hard left to +1 hard right.
  final double pan;

  /// Whether the voice is silenced.
  final bool muted;

  /// Whether the voice is soloed. Solo on any channel silences every channel
  /// that is not soloed.
  final bool soloed;

  /// MIDI bank select.
  final int midiBank;

  /// MIDI program.
  final int midiProgram;

  /// Semitones to shift this voice by — an octave down for a bass patch that
  /// sounds high, for instance.
  final int transpose;

  /// A copy with some fields replaced.
  ChannelSettings copyWith({
    String? voiceId,
    double? volume,
    double? pan,
    bool? muted,
    bool? soloed,
    int? midiBank,
    int? midiProgram,
    int? transpose,
  }) => ChannelSettings(
    voiceId: voiceId ?? this.voiceId,
    volume: volume ?? this.volume,
    pan: pan ?? this.pan,
    muted: muted ?? this.muted,
    soloed: soloed ?? this.soloed,
    midiBank: midiBank ?? this.midiBank,
    midiProgram: midiProgram ?? this.midiProgram,
    transpose: transpose ?? this.transpose,
  );

  @override
  String toString() =>
      '$voiceId vol ${volume.toStringAsFixed(2)}'
      '${muted ? ' muted' : ''}${soloed ? ' solo' : ''}';

  @override
  bool operator ==(Object other) =>
      other is ChannelSettings &&
      other.voiceId == voiceId &&
      other.volume == volume &&
      other.pan == pan &&
      other.muted == muted &&
      other.soloed == soloed &&
      other.midiBank == midiBank &&
      other.midiProgram == midiProgram &&
      other.transpose == transpose;

  @override
  int get hashCode => Object.hash(
    voiceId,
    volume,
    pan,
    muted,
    soloed,
    midiBank,
    midiProgram,
    transpose,
  );
}

/// The song's mixer: one [ChannelSettings] per voice, plus a master level.
class MixerSettings {
  MixerSettings._(Map<String, ChannelSettings> channels, this.masterVolume)
    : channels = Map<String, ChannelSettings>.unmodifiable(channels);

  /// Create mixer settings.
  ///
  /// Throws [ArgumentError] if the master volume is outside `0..1`.
  factory MixerSettings({
    Iterable<ChannelSettings> channels = const <ChannelSettings>[],
    double masterVolume = 0.8,
  }) {
    if (!masterVolume.isFinite || masterVolume < 0 || masterVolume > 1) {
      throw ArgumentError.value(
        masterVolume,
        'masterVolume',
        'must be between 0 and 1',
      );
    }
    return MixerSettings._(<String, ChannelSettings>{
      for (final channel in channels) channel.voiceId: channel,
    }, masterVolume);
  }

  /// Nothing set: every voice at its default when it appears.
  factory MixerSettings.empty() => MixerSettings();

  /// Settings by voice id.
  final Map<String, ChannelSettings> channels;

  /// Overall level, 0–1.
  final double masterVolume;

  /// Whether any channel is soloed.
  bool get hasSolo => channels.values.any((channel) => channel.soloed);

  /// The settings for [voiceId], creating defaults if the voice is new.
  ChannelSettings channelFor(String voiceId) =>
      channels[voiceId] ?? ChannelSettings(voiceId: voiceId);

  /// Whether [voiceId] is heard, taking solo into account.
  ///
  /// Solo anywhere silences everything not soloed — which is what a mixer does
  /// and what a musician expects when they hit solo on the bass.
  bool isAudible(String voiceId) {
    final channel = channelFor(voiceId);
    if (channel.muted) {
      return false;
    }
    return !hasSolo || channel.soloed;
  }

  /// The level [voiceId] is heard at, master included, or zero if inaudible.
  double effectiveVolume(String voiceId) =>
      isAudible(voiceId) ? channelFor(voiceId).volume * masterVolume : 0;

  /// A copy with one channel replaced.
  MixerSettings withChannel(ChannelSettings channel) => MixerSettings(
    channels: <ChannelSettings>[
      for (final existing in channels.values)
        if (existing.voiceId != channel.voiceId) existing,
      channel,
    ],
    masterVolume: masterVolume,
  );

  /// A copy with a different master level.
  MixerSettings withMasterVolume(double volume) =>
      MixerSettings(channels: channels.values, masterVolume: volume);

  /// A copy with every solo cleared.
  MixerSettings withoutSolos() => MixerSettings(
    channels: <ChannelSettings>[
      for (final channel in channels.values) channel.copyWith(soloed: false),
    ],
    masterVolume: masterVolume,
  );

  @override
  String toString() =>
      'MixerSettings(${channels.length} channels, master $masterVolume)';

  @override
  bool operator ==(Object other) {
    if (other is! MixerSettings ||
        other.masterVolume != masterVolume ||
        other.channels.length != channels.length) {
      return false;
    }
    for (final entry in channels.entries) {
      if (other.channels[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(masterVolume, Object.hashAllUnordered(channels.values));
}
