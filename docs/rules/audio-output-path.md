# The audio output path

Written per §1 / §15. Implemented by `rust/bandstand-audio-host` and the
renderer in `rust/src/engine.rs`.

## 1. Ownership

Exactly one thread owns the output stream for its whole life: the
`bandstand-audio-engine` thread. It is created once, on first use of the engine,
and takes commands over a bounded channel.

The reason is mechanical rather than stylistic: a `cpal::Stream` is not `Send`
on every backend, so it cannot be parked in a global and touched from whichever
Dart isolate thread happens to call in. A single owner also gives Android the
long-lived object that audio-focus and foreground-service handling will need at
M8.

Opening a stream while one is open closes the old one first, and always in that
order — two live streams on one device is how you get a device-busy error that
looks like a driver bug.

## 2. Choosing a configuration

The user asks for a device, a sample rate and a buffer size. Any of the three
may be unavailable. The rules, in order:

1. **Device.** By name, or the system default when unnamed. A device that
   reports no output configuration is hidden from the list rather than offered
   and made to fail.
2. **Configuration.** Score every configuration the device supports on three
   keys, ascending: whether it covers the requested sample rate (then the
   preferred 48 kHz, then neither); channel layout (stereo, then mono, then
   wider); and whether its sample format is `f32`. Take the minimum. Stereo
   before mono matters — a mono-first choice on a stereo device silently halves
   the output.
3. **Sample rate.** The requested rate if the chosen configuration's range
   covers it, else 48 kHz if that is covered, else the closest end of the range.
4. **Buffer size.** The requested size clamped into the device's supported
   range. A device that does not publish a range gets the backend default, and
   the UI says "backend default" rather than inventing a number.

Defaults when the caller expresses no preference: **48 kHz** and **256 frames**
(5.3 ms), inside the 10 ms desktop target of §3.

## 3. The block

Every block does the same four things, in this order:

1. Compute the **host time** at which the block's first frame will be heard.
   `cpal` reports a callback instant and a playback instant on its own clock;
   only their difference is portable, so the output latency is added to a
   reading of Bandstand's own monotonic clock taken inside the callback. That is
   what makes the published `(tick, host_time)` pair meaningful to Dart, which
   reads the same clock.
2. Zero an `f32` scratch buffer and hand it to the renderer. Mixing always
   happens in `f32` regardless of the device format; conversion is the last
   step.
3. Convert to the device format, **clipping to [-1, 1] and replacing any
   non-finite sample with silence**. A NaN reaching an integer format is a loud
   destructive artefact; on stage, silently clipping is the least bad answer,
   and the dropout counter records that it happened.
4. Increment the block and frame counters, which the UI polls once a second as
   a health readout. Backend errors increment a separate counter; any non-zero
   value means audio was interrupted.

The scratch buffer is allocated when the stream opens, sized at four times the
negotiated buffer. If a backend ever asks for more, it is resized once and stays
large enough afterwards — one allocation on one block, rather than a permanent
risk of a short buffer.

## 4. What the audio thread may not do

No allocation, no locking, no I/O, no panics, no logging. The renderer takes its
parameters through atomics and lock-free cells (see
`docs/rules/transport-clock.md`), and everything it needs is preallocated when
the stream opens.
