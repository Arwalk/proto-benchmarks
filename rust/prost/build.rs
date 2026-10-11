//! Code generation for the prost harness:
//!   * prost-build  -> OUT_DIR/bench.rs        (message structs, wire codec)
//!   * pbjson-build -> OUT_DIR/bench.serde.rs  (canonical ProtoJSON serde impls)
//! Also captures the rustc version and the resolved `prost` crate version
//! (from Cargo.lock) as compile-time environment variables.
use std::env;
use std::fs;
use std::path::PathBuf;
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
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let proto = proto_dir.join("bench.proto");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.lock");
    println!("cargo:rerun-if-changed={}", proto.display());
    println!("cargo:rerun-if-env-changed=PROTO_DIR");
    println!("cargo:rerun-if-env-changed=PROTOC");

    // prost-build picks up $PROTOC itself (falls back to `protoc` on PATH).
    let descriptor = out_dir.join("bench_descriptor.bin");
    prost_build::Config::new()
        .file_descriptor_set_path(&descriptor)
        .compile_protos(&[&proto], &[&proto_dir])
        .expect("prost-build failed");

    let descriptor_bytes = fs::read(&descriptor).expect("read descriptor set");
    pbjson_build::Builder::new()
        .register_descriptors(&descriptor_bytes)
        .expect("register descriptors")
        .build(&[".bench"])
        .expect("pbjson-build failed");

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
    let prost_version = lock_version(&lock, "prost").unwrap_or_else(|| "unknown".to_string());
    let pbjson_version = lock_version(&lock, "pbjson").unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=PROST_VERSION={prost_version}");
    println!("cargo:rustc-env=PBJSON_VERSION={pbjson_version}");
}
