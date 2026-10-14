//! The flutter_rust_bridge surface.
//!
//! Deliberately small (§3): everything below is a wrapper over the audio
//! engine. Dart owns the library, the setlists and the player's policy; Rust
//! owns the devices, the decoder, the mixer and the transport.

pub mod audio;

/// Called once by `RustLib.init()` before any other bridge function.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    bandstand_transport::init_clock();
}
