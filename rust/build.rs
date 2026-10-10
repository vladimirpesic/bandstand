// flutter_rust_bridge's attribute macros (`#[flutter_rust_bridge::frb(init)]`,
// `#[frb(sync)]` in src/api/) expand to code guarded by `cfg(frb_expand)`, so
// every build would otherwise raise `unexpected_cfgs` warnings from rustc —
// promoted to errors by `just rust-check`'s `clippy -D warnings`.
//
// The usual registration is `[lints.rust] unexpected_cfgs.check-cfg` in
// Cargo.toml, but that manifest form is rejected by the Cargo.toml schema the
// Even Better TOML editor extension validates against. This build-script
// directive is the same registration in plain Rust, and it is honoured in
// every context cargo is invoked from — `cargo`, `cargo clippy`, and the
// cargokit-driven Flutter builds.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(frb_expand)");
    println!("cargo::rerun-if-changed=build.rs");
}
