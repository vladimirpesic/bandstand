//! The flutter_rust_bridge surface.
//!
//! Deliberately small (§3): everything below is a wrapper over the audio
//! engine. Dart owns the song model, generation, layout and file I/O; Rust owns
//! everything after "here is a list of scheduled events".

pub mod audio;

/// Called once by `RustLib.init()` before any other bridge function.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    bandstand_transport::init_clock();
}
