#!/usr/bin/env bash
# Sourced by the Rust scripts. signalsmith-stretch generates its bindings with
# bindgen, which needs libclang. Linux and macOS hosts have one (CI installs
# libclang-dev); a Windows host without LLVM uses the copy in the Android NDK.

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ -z "${LIBCLANG_PATH:-}" && -n "${ANDROID_NDK_HOME:-}" ]]; then
      KALAO_NDK_LLVM="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64"
      if [[ -f "$KALAO_NDK_LLVM/bin/libclang.dll" ]]; then
        export LIBCLANG_PATH="$KALAO_NDK_LLVM/bin"
        # The NDK's libclang does not find its own builtin headers here.
        for KALAO_CLANG_INCLUDE in "$KALAO_NDK_LLVM"/lib/clang/*/include; do
          export BINDGEN_EXTRA_CLANG_ARGS="${BINDGEN_EXTRA_CLANG_ARGS:-} -isystem $(cygpath -m "$KALAO_CLANG_INCLUDE")"
        done
      fi
    fi
    ;;
esac
