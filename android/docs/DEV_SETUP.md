# Development Setup (Windows host)

Toolchain versions match Mornye (LIBRARIES.md §1).

## Install
1. **FVM** (`dart pub global activate fvm`, the installer, or Scoop `extras/fvm`), then `fvm install` in `android/` (reads `.fvmrc`, Flutter 3.47.8). Use `fvm flutter …` for every command. Without Windows Developer Mode `fvm install` cannot create its symlink; link the SDK with a junction instead: `New-Item -ItemType Junction -Path .fvm\versions\3.47.8 -Target $env:FVM_CACHE_PATH\versions\3.47.8`.
2. **Android Studio** → SDK Manager: Android SDK Platform 37, Build-Tools, Command-line Tools, **NDK 30.0.16248370**, CMake. Set `ANDROID_HOME` and `ANDROID_NDK_HOME`. Accept licences: `fvm flutter doctor --android-licenses`.
3. **JDK 25** (Kotlin `jvmTarget` 25, as Mornye); set `JAVA_HOME`.
4. **Rust** Android targets and tools (the toolchain is pinned by `rust_backend/rust-toolchain.toml`):
   ```sh
   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
   cargo install cargo-ndk
   ```
   On Linux hosts the host build of `kalao-audio` (cpal) needs ALSA headers: `sudo apt-get install libasound2-dev pkg-config`. On Windows, Gradle's `buildRustBackend` runs Git Bash by full path (a `bash.exe` on PATH outside System32, or `bin\bash.exe` beside Git's `cmd\git.exe`), because Windows searches System32, where WSL's `bash.exe` lives, before PATH; `~/.cargo/bin` must be on PATH. Without Git Bash, build the Rust library first with `bash scripts/build_rust_backend.sh android` and run Gradle with `-x buildRustBackend`.
5. **libclang and a C++ compiler** for `signalsmith-stretch` (bindgen + cc). Linux: `sudo apt-get install libclang-dev` (g++ is usually present). Windows: MSVC Build Tools for the host build; `scripts/rust_env.sh` (sourced by the Rust scripts) points bindgen at the NDK's `libclang.dll` when `LIBCLANG_PATH` is unset. To run cargo by hand on Windows, `source scripts/rust_env.sh` first. The Android build uses the NDK's clang++, links libc++ statically (`libc++_static.a` plus `libc++abi.a`, which holds the C++ ABI runtime), and links with `--no-undefined`, so an unresolved native symbol fails the build instead of the app's launch.
6. **Git Bash** for `scripts/*.sh` and **Python 3** for `scripts/check_backend_apk.py` (as in Mornye).

## Everyday commands (run from `karaoke/`)
```sh
bash scripts/build_rust_backend.sh host        # host library + Kotlin bindings (kalao-bindgen)
bash scripts/build_rust_backend.sh android     # then libkalao_mobile.so per ABI (KALAO_RUST_ANDROID_ABIS selects ABIs)
bash scripts/check_rust_backend.sh             # cargo fmt --check, clippy -D warnings, cargo test (all --locked)
cd android && fvm flutter run                  # Gradle's buildRustBackend runs the android build before preBuild
cd android && fvm flutter analyze && fvm flutter test
cd android && fvm flutter test integration_test
gradle -p android/android :app:testDebugUnitTest   # Kotlin tests incl. MainActivityRoutingTest
```

## Pushing workflow changes
The GitHub CLI token needs the `workflow` scope to push files under `.github/workflows/`: run `gh auth refresh -h github.com -s workflow` once.

## Releases
- Tag `vX.Y.Z` → `release.yml` builds per-ABI and universal APKs, signs them (V1–V4) with the release key from CI secrets, audits the Rust payloads, and publishes a GitHub Release with SHA-256 checksums and a `git-cliff` changelog. The update checker reads that release.

## Conventions
- Rust: `cargo fmt`, `clippy -D warnings`, `thiserror` errors, no `unwrap` outside tests, `unsafe_code = "deny"` workspace-wide (the desktop C ABI crate will be the audited exception); `--locked` everywhere.
- Dart: `dart format`, `flutter analyze` clean with Mornye's `analysis_options.yaml` and `riverpod_lint`; no business logic in widgets or providers; backend calls only through `PlatformBridge`.
- Kotlin: a new native method is added to `nativeBackendMethods` and the `when` in the same change (the routing test enforces it).
- Copied Mornye files keep the attribution header (MORNYE_REUSE.md §1).
- Small commits; CI must pass.
