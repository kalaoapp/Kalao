# Kalao Rust Backend

The Rust workspace is the app's engine. It follows the layout of Mornye's `rust_backend/` (https://github.com/mornyeapp/Mornye, LGPL-3.0-only); files derived from Mornye carry a header saying so. Flutter reaches it through the `com.brinsley.kalao/backend` channel; Kotlin calls it through UniFFI bindings generated from `kalao-mobile`.

The toolchain is pinned in `rust-toolchain.toml` (Rust 1.99.1 with rustfmt and clippy). The workspace uses edition 2024, resolver 3, and denies `unsafe_code`.

## Crate map

Dependencies point downward: `core`, `network` and `audio` depend on no other workspace crate.

| Crate | Package | Depends on | Contents |
| --- | --- | --- | --- |
| `crates/core` | `kalao-core` | none | JSON helpers, text, XML depth check, matching, lyrics (`lrc`, TTML payloads, and `doc`: LRC/eLRC/TTML/plain import, LRC/eLRC export), section markers, annotation (pinyin, furigana and romaji, Chinese variants), search keys, import pairing |
| `crates/audio` | `kalao-audio` | none | Playback engine (Symphonia → rubato → ring buffers → mixer → Signalsmith Stretch → cpal/AAudio) over files or streams (`Media`), gapless loops, clock, `probe_file` |
| `crates/network` | `kalao-network` | none | Mornye's HTTP client, unchanged: per-session allowlist and cookies, redirect checks, DNS, TLS roots, streams |
| `crates/extensions` | `kalao-extensions` | core, network | Extension framework (EXTENSIONS.md): manifest, `.kalaoext` packages, QuickJS runtime and the `kalao` host object, ed25519 repositories, the manager (install, settings, priority, health) and capability calls |
| `crates/ext-cli` | `kalao-ext` | extensions | Extension author CLI: `validate`, `test`, `pack`, `keygen`, `sign`, `index` |
| `crates/mobile` | `kalao-mobile` | core, audio, network, extensions | UniFFI API: `invoke_application` method table, `run_native_data_job`, cancellation registry, player state publisher (`player_subscribe`), log buffer, backup archive codec, extension methods and the stream cache |
| `crates/bindgen` | `kalao-bindgen` | `uniffi` CLI | Generates the Kotlin bindings |

Later milestones add `providers`, `stems`, `party` and `desktop` (see `android/docs/ARCHITECTURE.md`).

## Method table

`kalao-mobile/src/backend.rs` holds every method name Kotlin forwards (`METHODS`, kept sorted; a test checks each name is dispatched). Arguments arrive as JSON text (an object); replies are JSON text. Methods: lifecycle (`initBackend`, `getBackendInfo`, `getLogs`, `clearLogs`, `setLoggingEnabled`), player (`playerLoad` … `playerState`, including key, tempo and loops), import (`probeAudio`, `pairImportFiles`), lyrics (`parseLyrics`, `exportLyrics`, `detectSections`, `annotateLyrics`, `convertChinese`). Native data jobs (`run_native_data_job`): `hash_file`, `importInspect`, `importStore`, `rebuildSearchKeys`, `backupWrite`, `backupInspect`.

## Building

| Command | Result |
| --- | --- |
| `bash scripts/build_rust_backend.sh host` | Release host library and Kotlin bindings in `target/bindings/kotlin/` |
| `bash scripts/build_rust_backend.sh android` | Host step, then `libkalao_mobile.so` in `target/android/jniLibs/<abi>/` (16 KB page aligned) |
| `bash scripts/check_rust_backend.sh` | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` |

Android Gradle runs the android build in its `buildRustBackend` task before `preBuild`, so a normal Flutter build is enough. `KALAO_RUST_ANDROID_ABIS` selects ABIs (default `arm64-v8a,armeabi-v7a,x86_64`); `ANDROID_NDK_HOME` must point to NDK 30.0.16248370. On Windows, `source scripts/rust_env.sh` before running cargo by hand (it points bindgen at the NDK's libclang).
