//! `bandstand-ffi` — the flutter_rust_bridge surface for Bandstand.
//!
//! Published as `rust_lib_bandstand` because that is the artifact name the
//! Flutter-side native build expects; see `docs/decisions/0002-rust-workspace-layout.md`.

#[cfg(target_os = "android")]
pub mod android;
pub mod api;
mod decode;
mod engine;
mod player;
mod tone;

mod frb_generated;
