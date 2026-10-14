//! Process-wide monotonic clock shared by the audio thread and the UI.
//!
//! Both sides read the same epoch, so a `(tick, host_time_ns)` pair published by
//! the audio thread can be extrapolated by the UI (see `docs/rules/transport-clock.md`).

use std::sync::OnceLock;
use std::time::Instant;

fn epoch() -> Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    *EPOCH.get_or_init(Instant::now)
}

/// Nanoseconds elapsed since the process-fixed monotonic epoch.
///
/// Wall-clock meaningless; differences are what matter. Saturates rather than
/// wrapping, which for a `u64` of nanoseconds means after ~584 years of uptime.
#[must_use]
pub fn monotonic_now_ns() -> u64 {
    u64::try_from(epoch().elapsed().as_nanos()).unwrap_or(u64::MAX)
}

/// Initialise the epoch eagerly, so the first audio callback does not pay for it.
pub fn init_clock() {
    let _ = epoch();
}
