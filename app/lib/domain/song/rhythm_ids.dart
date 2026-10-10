// The ids of the rhythms (§6.5) this build ships.
//
// The ids are domain vocabulary — a song part names one, the editor offers
// them — while the patterns that answer to them are loaded in `io` (ADR
// 0006). Keeping the constants here means the model can default to a rhythm
// that actually plays without importing the asset loader.

/// Drums, walking bass and comping piano: the band a new song plays.
const String swingRhythmId = 'swing';

/// The same without the piano, for practising with a rhythm section only.
const String rhythmSectionRhythmId = 'rhythm-section';

/// Bossa nova and samba: the latin band, straight-eighth and root-and-fifth.
const String bossaRhythmId = 'bossa-trio';

/// The latin band without the piano.
const String bossaSectionRhythmId = 'bossa-section';

/// Straight eighths: the modern-jazz and fusion answer, unhung by swing.
const String straightRhythmId = 'straight-eighths';
