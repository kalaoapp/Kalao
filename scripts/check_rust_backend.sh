#!/usr/bin/env bash
# Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
# LGPL-3.0-only. Modified for Kalao.
#
# Run Rust formatting, Clippy and unit tests for the whole workspace.

set -euo pipefail

if (( $# > 0 )); then
  case "$1" in
    --help|-h) echo "Usage: check_rust_backend.sh  (rustfmt, clippy -D warnings, cargo test)"; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/rust_env.sh"
cd "$(dirname "$SCRIPT_DIR")/rust_backend"
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
