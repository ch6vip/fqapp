// fqapi_core - the Rust native core for the fqapp Android client.
//
// NOTE: flutter_rust_bridge must be able to find its generated module
// declaration in this file; it is declared explicitly below so code generation
// is a no-op on lib.rs. Keep this file free of inner (`//!`) crate docs: the
// generator inserts its declaration as the first line, and an inner doc comment
// after an item is a compile error (E0753).
//
// Layering:
//   api       - flutter_rust_bridge surface (transport for the Flutter app)
//   dispatch  - the single request dispatcher shared by FFI and loopback HTTP
//   endpoints - route table and business handlers
//   upstream  - signed HTTP access, device rotation, DH/CM key exchange
//   device    - persistent device pool + registration
//   sign      - request signing primitives
//
// See docs/migration/rust-migration-contracts.md for the behaviour contract and
// docs/rust-migration-progress.md for the current verification state.

pub mod api;
pub mod config;
pub mod core_log;
pub mod crypto;
pub mod device;
pub mod dispatch;
pub mod endpoints;
pub mod error;
pub mod filter;
pub mod json;
pub mod server;
pub mod sign;
pub mod static_files;
pub mod timeutil;
pub mod upstream;

mod frb_generated;
