//! Code generation for the rust-protobuf harness:
//!   protobuf-codegen (protoc backend) -> OUT_DIR/protos/{mod.rs,bench.rs}
//! Also captures the rustc version and the resolved `protobuf` crate version
//! (from Cargo.lock) as compile-time environment variables.
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn lock_version(lock: &str, krate: &str) -> Option<String> {
    let mut in_pkg = false;
    for line in lock.lines() {
        let line = line.trim();
        if line == "[[package]]" {
            in_pkg = false;
        } else if line == format!("name = \"{krate}\"") {
            in_pkg = true;
        } else if in_pkg && line.starts_with("version = ") {
            return Some(line.trim_start_matches("version = ").trim_matches('"').to_string());
        }
    }
    None
}

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let proto_dir = env::var_os("PROTO_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest_dir.join("..").join("..").join("proto"));
    let proto = proto_dir.join("bench.proto");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.lock");
    println!("cargo:rerun-if-changed={}", proto.display());
    println!("cargo:rerun-if-env-changed=PROTO_DIR");
    println!("cargo:rerun-if-env-changed=PROTOC");

    let mut codegen = protobuf_codegen::Codegen::new();
    codegen.protoc();
    if let Some(protoc) = env::var_os("PROTOC") {
        codegen.protoc_path(Path::new(&protoc));
    }
    codegen
        .includes([&proto_dir])
        .input(&proto)
        .cargo_out_dir("protos")
        .run_from_script();

    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let rustc_version = Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "rustc (unknown)".to_string());
    println!("cargo:rustc-env=RUSTC_VERSION={rustc_version}");

    let lock = fs::read_to_string(manifest_dir.join("Cargo.lock")).unwrap_or_default();
    let protobuf_version = lock_version(&lock, "protobuf").unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=PROTOBUF_VERSION={protobuf_version}");
}
