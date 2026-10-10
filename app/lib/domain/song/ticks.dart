/// The resolution the whole app counts ticks at.
///
/// Every tick in Bandstand — the generated sequence, the tempo map, the
/// playhead, a practice loop's bounds — is counted at this resolution, and they
/// are compared against each other constantly. Four copies of the literal
/// `960` used to sit in four files that had to agree; they did, but nothing
/// said so, and raising one of them for finer swing placement would have
/// silently broken tick arithmetic everywhere else with no compile-time or
/// test-time signal.
///
/// 960 divides by 2, 3, 4, 5, 6 and 8, so eighth-note triplets, sixteenths and
/// quintuplets all land on whole ticks.
const int kTicksPerQuarter = 960;
