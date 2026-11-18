#!/usr/bin/env bash
# Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
# LGPL-3.0-only. Modified for Kalao.
#
# Stage the Rust library and UniFFI Kotlin bindings for the Android app.
#   host     build kalao-mobile for this machine and generate the Kotlin bindings
#   android  host step, then libkalao_mobile.so for each ABI in KALAO_RUST_ANDROID_ABIS
#            (default arm64-v8a,armeabi-v7a,x86_64)
# Output (rust_backend/target/): bindings/kotlin/, android/jniLibs/<abi>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUST_BACKEND_DIR="$PROJECT_DIR/rust_backend"
PLATFORM="${1:-host}"
# Matches minSdk in android/android/app/build.gradle.kts.
ANDROID_API=26

case "$PLATFORM" in
  host|android) ;;
  *) echo "Usage: bash scripts/build_rust_backend.sh [host|android]" >&2; exit 1 ;;
esac

if [[ "$PLATFORM" == "android" ]]; then
  ANDROID_ABIS_RAW="${KALAO_RUST_ANDROID_ABIS-arm64-v8a,armeabi-v7a,x86_64}"
  IFS=',' read -r -a ANDROID_ABIS <<< "$ANDROID_ABIS_RAW"
  if (( ${#ANDROID_ABIS[@]} == 0 )); then
    echo "Error: KALAO_RUST_ANDROID_ABIS is empty." >&2
    exit 1
  fi
  for ABI in "${ANDROID_ABIS[@]}"; do
    case "$ABI" in
      arm64-v8a|armeabi-v7a|x86_64) ;;
      *) echo "Error: unsupported ABI '$ABI' (use arm64-v8a, armeabi-v7a, x86_64)." >&2; exit 1 ;;
    esac
  done
fi

source "$SCRIPT_DIR/rust_env.sh"
cd "$RUST_BACKEND_DIR"
export CARGO_TARGET_DIR="$RUST_BACKEND_DIR/target"

case "$(uname -s)" in
  Darwin) HOST_LIBRARY="$CARGO_TARGET_DIR/release/libkalao_mobile.dylib"; NDK_HOST="darwin-x86_64"; EXE="" ;;
  Linux) HOST_LIBRARY="$CARGO_TARGET_DIR/release/libkalao_mobile.so"; NDK_HOST="linux-x86_64"; EXE="" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_LIBRARY="$CARGO_TARGET_DIR/release/kalao_mobile.dll"; NDK_HOST="windows-x86_64"; EXE=".cmd" ;;
  *) echo "Error: unsupported host $(uname -s)." >&2; exit 1 ;;
esac

# Build separately from bindgen so the CLI and cargo-metadata features are not
# enabled in the shipped library through Cargo's workspace feature unification.
cargo build --locked --release -p kalao-mobile
# Bindgen discovers crates/mobile/uniffi.toml through Cargo metadata.
cargo run --locked -p kalao-bindgen -- generate \
  --library "$HOST_LIBRARY" \
  --language kotlin \
  --out-dir "$CARGO_TARGET_DIR/bindings/kotlin" \
  --no-format

if [[ "$PLATFORM" == "android" ]]; then
  if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    echo "Error: set ANDROID_NDK_HOME to Android NDK 30.0.16248370." >&2
    exit 1
  fi
  NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/bin"
  NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot"
  if [[ "$NDK_HOST" == "windows-x86_64" ]]; then
    NDK_SYSROOT="$(cygpath -m "$NDK_SYSROOT")"
  fi

  ANDROID_TARGETS=()
  for ABI in "${ANDROID_ABIS[@]}"; do
    case "$ABI" in
      arm64-v8a) TARGET=aarch64-linux-android; CLANG="aarch64-linux-android${ANDROID_API}-clang" ;;
      armeabi-v7a) TARGET=armv7-linux-androideabi; CLANG="armv7a-linux-androideabi${ANDROID_API}-clang" ;;
      x86_64) TARGET=x86_64-linux-android; CLANG="x86_64-linux-android${ANDROID_API}-clang" ;;
    esac
    LINKER="$NDK_BIN/$CLANG$EXE"
    if [[ ! -f "$LINKER" ]]; then
      echo "Error: Android API $ANDROID_API linker was not found: $LINKER" >&2
      exit 1
    fi
    UPPER="$(echo "$TARGET" | tr 'a-z-' 'A-Z_')"
    LOWER="${TARGET//-/_}"
    export "CARGO_TARGET_${UPPER}_LINKER=$LINKER"
    export "CC_${LOWER}=$LINKER"
    # C++ (Signalsmith Stretch): the NDK's clang++, libc++ linked statically
    # so the APK carries no libc++_shared.so, and the NDK headers for bindgen.
    export "CXX_${LOWER}=$NDK_BIN/${CLANG}++$EXE"
    export "CXXSTDLIB_${LOWER}=c++_static"
    export "BINDGEN_EXTRA_CLANG_ARGS_${LOWER}=${BINDGEN_EXTRA_CLANG_ARGS:-} --sysroot=$NDK_SYSROOT"
    export "AR_${LOWER}=$NDK_BIN/llvm-ar"
    ANDROID_TARGETS+=("$TARGET")
  done

  rustup target add "${ANDROID_TARGETS[@]}"
  # Align ELF segments for 16 KB pages and pack relocations; fold only
  # identical functions whose addresses are not significant.
  # libc++_static.a lacks the C++ ABI runtime (std::exception, typeinfo,
  # std::terminate), which lives in libc++abi.a; the NDK's own libc++.a is
  # `INPUT(-lc++_static -lc++abi)`. --no-undefined turns any symbol left
  # unresolved into a link error instead of a dlopen failure on the device.
  export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,--pack-dyn-relocs=android -C link-arg=-Wl,--icf=safe -C link-arg=-lc++abi -C link-arg=-Wl,--no-undefined"
  for i in "${!ANDROID_TARGETS[@]}"; do
    TARGET="${ANDROID_TARGETS[$i]}"
    ABI="${ANDROID_ABIS[$i]}"
    cargo build --locked --release -p kalao-mobile --target "$TARGET"
    mkdir -p "$CARGO_TARGET_DIR/android/jniLibs/$ABI"
    cp "$CARGO_TARGET_DIR/$TARGET/release/libkalao_mobile.so" "$CARGO_TARGET_DIR/android/jniLibs/$ABI/"
  done
  echo "Rust Android libraries are staged in $CARGO_TARGET_DIR/android/jniLibs."
fi

echo "Kotlin bindings are in $CARGO_TARGET_DIR/bindings/kotlin."
