import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/rhythm.dart';
import 'package:flutter_test/flutter_test.dart';

/// The voice-aware half of the mixer lookup.
///
/// `channelFor` answers a bare default because the model cannot know what a
/// voice is; `channelForVoice` asks the voice. That difference is the whole
/// reason an imported song's bass stops sounding like a piano.
/// The voice fixture the generator tests used to borrow: acoustic bass.
final RhythmVoice bassVoice = RhythmVoice(
  id: 'bass',
  displayName: 'Bass',
  isDrums: false,
  defaultMidiProgram: 32,
);

void main() {
  test('a voice the mixer has never heard of plays its own program', () {
    final mixer = MixerSettings.empty();
    expect(mixer.channelForVoice(bassVoice).midiProgram, 32);
  });

  test('an explicit channel keeps the last word', () {
    final mixer = MixerSettings.empty().withChannel(
      ChannelSettings(voiceId: bassVoice.id, midiProgram: 4),
    );
    expect(mixer.channelForVoice(bassVoice).midiProgram, 4);
  });

  test('a voice with no instrument of its own defaults to the piano', () {
    final mixer = MixerSettings.empty();
    final plain = RhythmVoice(
      id: 'plain',
      displayName: 'Plain',
      isDrums: false,
    );
    expect(mixer.channelForVoice(plain).midiProgram, 0);
    // And it is a channel for the right voice, not a stray default.
    expect(mixer.channelForVoice(plain).voiceId, 'plain');
  });

  test('a default outside General MIDI is refused at construction', () {
    expect(
      () => RhythmVoice(
        id: 'bad',
        displayName: 'Bad',
        isDrums: false,
        defaultMidiProgram: 128,
      ),
      throwsArgumentError,
    );
  });
}
