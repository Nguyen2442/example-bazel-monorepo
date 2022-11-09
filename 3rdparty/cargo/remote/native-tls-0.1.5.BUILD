"""
cargo-raze crate build file.

DO NOT EDIT! Replaced on runs of cargo-raze
"""
package(default_visibility = [
  # Public for visibility by "@raze__crate__version//" targets.
  #
  # Prefer access through "//3rdparty/cargo", which limits external
  # visibility to explicit Cargo.toml dependencies.
  "//visibility:public",
])

licenses([
  "notice", # "MIT,Apache-2.0"
])

load(
    "@io_bazel_rules_rust//rust:rust.bzl",
    "rust_library",
    "rust_binary",
    "rust_test",
)


# Unsupported target "google-connect" with type "example" omitted

rust_library(
    name = "native_tls",
    crate_root = "src/lib.rs",
    crate_type = "lib",
    edition = "2015",
    srcs = glob(["**/*.rs"]),
    deps = [
        "@raze__lazy_static__0_2_11//:lazy_static",
        "@raze__openssl__0_9_24//:openssl",
    ],
    rustc_flags = [
        "--cap-lints=allow",
    ],
    version = "0.1.5",
    crate_features = [
    ],
)

# Unsupported target "simple-server" with type "example" omitted