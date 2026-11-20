# Libraries

Pin policy (from Mornye): exact versions (`=x.y.z` in Cargo, no caret for packages with migration hazards in pubspec), one version per dependency across the workspace, Renovate PRs for upgrades. **Mornye** = the version Mornye pins, already proven together. **New** = Kalao-only; the exact version is pinned in the PR that adds it, after a licence check (must be GPL-3.0-compatible). A dependency is added in the milestone that first uses it; the manifests (`android/pubspec.yaml`, `rust_backend/Cargo.toml`, `android/android/app/build.gradle.kts`) are the source of truth.

## 1. Toolchains

| Tool | Version | Source |
| --- | --- | --- |
| Flutter (via FVM, `.fvmrc`) | 3.47.8 | Mornye |
| Dart SDK constraint | `^3.10.0` | Mornye |
| Rust (`rust-toolchain.toml`) | 1.99.1, profile minimal, rustfmt + clippy; edition 2024, resolver 3 | Mornye |
| Android Gradle Plugin | 9.5.0 | Mornye |
| Kotlin | 2.4.21, `jvmTarget` 25 (JDK 25) | Mornye |
| Android NDK | 30.0.16248370 | Mornye |
| compileSdk / targetSdk / minSdk | 37 / 37 / 26 | Mornye (minSdk raised for AAudio) |
| cargo-ndk | latest | new |

## 2. Dart / Flutter (`android/pubspec.yaml`)

### In use

| Package | Version | Use | Source |
| --- | --- | --- | --- |
| `flutter_localizations`, `intl` | sdk, `^0.20.3` | l10n | Mornye |
| `flutter_riverpod` | `^3.4.2` | State | Mornye |
| `go_router` | `^18.1.2` | Routing | Mornye |
| `shared_preferences` | `^2.5.6` | Settings | Mornye |
| `flutter_secure_storage` | `10.3.4` (exact; v11 drops legacy Android readers) | Secrets from M5 | Mornye |
| `path_provider`, `path` | `^2.1.6`, `^1.9.1` | Paths | Mornye |
| `sqflite` (+ `sqflite_common_ffi` in tests) | `^2.4.5` | Library, history, app-state databases | Mornye |
| `file_picker` | `^13.3.0` | Import audio, lyrics, backups, fonts | Mornye |
| `audio_service` | `^0.18.19` (pub.dev) | Media session, notification, headset buttons. Mornye's fork patches Android Auto, browsing and notification custom actions, which Kalao does not use | Mornye's version |
| `audio_session` | `^0.2.4` | Focus, interruptions, becoming-noisy | Mornye |
| `ffmpeg_kit_flutter_new_audio` | `2.5.7` (exact, pub.dev) | One-off conversion at import of formats Symphonia cannot decode (Opus, WMA, APE). Mornye's fork only patches Windows | Mornye's version |
| `dynamic_color`, `material_ui` | `^2.1.0`, `^1.9.0` | Material You | Mornye |
| `url_launcher` | `6.3.3` (exact) | Ko-fi, release page, GitHub issues | Mornye |
| `share_plus` | `13.3.1` (exact) | Share logs | Mornye |
| `http` | `1.6.0` (exact) | Update check and APK download | Mornye |
| `flutter_lints`, `riverpod_lint` | `^6.0.0`, `^3.1.9` | Lints | Mornye |
| `integration_test` | sdk | On-device tests | Mornye |

### Planned

| Package | Version | Use | Milestone |
| --- | --- | --- | --- |
| `ffi` | `^2.2.0` | Desktop backend | M8.7 |
| `connectivity_plus` | `^7.3.1` | Offline detection (stems remote, translation) | M6 |
| `crypto` | `^3.0.8` | SHA-256 cache keys (translation); file hashes use the Rust `hash_file` job | M6 |
| `app_links` | `^7.2.2` | `kalao://ext/<id>/callback` | M5 |
| `cached_network_image`, `flutter_cache_manager` | `^4.0.6`, `^3.4.6` | Artwork | M5 |
| `permission_handler` | `^13.0.1` | Mic, camera, notifications | M7 |
| `flutter_local_notifications` | `^22.3.3` | Job notifications | M6 |
| `synchronized` | `^3.5.0` | Locks around DB writes, if needed | — |
| `bonsoir` | `^7.1.5` | mDNS discovery of parties | M8 |
| `mobile_scanner`, `qr_flutter` | latest major | Party QR codes | M8 |
| `json_annotation` / `json_serializable` + `build_runner` | `^4.12.0` / `^6.15.2`, `^2.17.1` | Only if hand-written models stop scaling | — |

Not taken from Mornye: `audioplayers` and its forks, `media_kit*`, `liquid_glass_easy`, `dart_smb2`, `smtc_windows`, `dbus`, `video_player`, `record` (mic capture will be native, in `kalao-audio`), `mornye_discord`, `desktop_drop` (until desktop), `timezone`, `volume_controller`, `xml`, `html`, `open_filex`, `archive` (backups are read and written in Rust), `device_info_plus` (Kotlin reports `Build.SUPPORTED_ABIS`), `receive_sharing_intent` (`SharedFiles.kt` handles VIEW, SEND and SEND_MULTIPLE), `material_symbols_icons`, `material_3_expressive`, `logger` (`AppLogger` is in-house), `flutter_launcher_icons` (icons are checked in).

## 3. Kotlin (`android/android/app/build.gradle.kts`)

| Artifact | Version | Use |
| --- | --- | --- |
| `net.java.dev.jna:jna` | `5.19.1@aar` | UniFFI bindings loader |
| `org.jetbrains.kotlinx:kotlinx-coroutines-android` | 1.11.0 | `Dispatchers.IO` dispatch |
| `androidx.lifecycle:lifecycle-runtime-ktx` | 2.11.0 | Lifecycle |
| `androidx.activity:activity-ktx` | 1.13.0 | Activity result APIs (SAF pickers) |
| `androidx.core:core-ktx` | 1.17.0 | `FileProvider` for the update installer |
| `junit:junit` (test) | 4.13.2 | `MainActivityRoutingTest` |
| `com.microsoft.onnxruntime:onnxruntime-android` *(M6)* | latest 1.x | `libonnxruntime.so` (XNNPACK EP) loaded by `ort` |

No `play-services-*` artifacts. `androidx.documentfile` is not used: `DocumentsContract` covers the backup folder.

## 4. Rust (`rust_backend/Cargo.toml` `[workspace.dependencies]`)

### In use

| Crate | Version | Used by | Use |
| --- | --- | --- | --- |
| `serde`, `serde_json` | 1.0 (derive; float_roundtrip, raw_value) | core, mobile, audio, network | JSON method table |
| `thiserror` | 2.0 | mobile, audio | Error enums |
| `uniffi` | =0.32.2 | mobile, bindgen | Kotlin bindings |
| `sha2` | 0.11 | mobile | File hashes, backup checksums |
| `base64` | 0.23 | core | Payload decoding |
| `regex`, `unicode-normalization`, `unicode-general-category` | =1.13.1, =0.1.22, =0.6.0 | core | Lyrics parsing, matching |
| `roxmltree` | =0.21.2 | core | TTML |
| `chrono` | =0.4.45 | mobile | Log timestamps |
| `zip` | =9.1.3 (deflate-flate2-zlib-rs) | mobile | `.kalaobackup` archives |
| `symphonia` | 0.5.5 (mp3, aac, isomp4, alac, flac, vorbis, ogg, wav, pcm) | audio | Decoding; tags and covers for `probeAudio` |
| `cpal` | 0.16 | audio | AAudio output (input from M7) |
| `rubato` | 0.16 | audio | Resampling to the device rate |
| `ringbuf` | 0.4 | audio | Lock-free decoder → callback buffers |
| `signalsmith-stretch` (MIT) | =0.1.3 | audio | Key and tempo (ADR-005). Compiles C++ (`cc`) and generates bindings (`bindgen`), so builds need a C++ compiler and libclang; Android links libc++ and libc++abi statically |
| `pinyin_pro` (MIT) | =3.29.4 | core | Rust port of `pinyin-pro`, the POC's library: segmentation, polyphones in context, tone marks |
| `wana_kana` | 4 | core | Kana → romaji |
| `lindera` with IPADIC | =6.2.0 (`embed-ipadic`) | core | Japanese readings; the dictionary is downloaded at build time and embedded (about 50 MB per ABI) |
| `ferrous-opencc` with OpenCC data (Apache-2.0) | =0.4.0 | core | Traditional ↔ Simplified; dictionaries embedded (about 2 MB) |
| `tokio`, `hyper-util`, `hyper-rustls`, `rustls`, `rustls-pemfile`, `http`, `http-body-util`, `bytes`, `futures-util`, `tokio-util`, `async-compression`, `tower-service`, `hickory-proto`, `cookie`, `url` | Mornye's pins | network | HTTP stack of `kalao-network`, which nothing links yet (M5). `rustls-native-certs` and `rustls-platform-verifier` are declared in the workspace but used by no crate |

### Planned

| Crate | Version | Crate user | Use | Milestone |
| --- | --- | --- | --- | --- |
| `rquickjs`, `scraper` + `html5ever`, `aes-gcm`, `aes`, `hmac`, `sha1`, `md-5`, `zeroize`, `getrandom`, `cap-std`, `time`, `httpdate`, `tempfile` | Mornye's pins | extensions | Extension runtime and host APIs | M5 |
| `ed25519-dalek` | 2.x | extensions | Repository signatures (if Mornye's repository module lacks it) | M5 |
| `clap` | 4.x | ext-cli | `kalao-ext` CLI | M5 |
| `rusqlite` | =0.41.1 (bundled) | mobile | Only if a data job needs to read a database snapshot | — |
| `image` | =0.25.10 | mobile | Cover thumbnails, if artwork search needs them | M5 |
| `ort` | 2.x (`load-dynamic`) | stems | ONNX Runtime; XNNPACK, CPU fallback | M6 |
| `ndarray` | 0.16 | stems | Tensors | M6 |
| `realfft` | 3.x | stems, audio | STFT/iSTFT, pitch analysis | M6, M7 |
| `flacenc` | latest | stems, audio | FLAC stems and recordings (pure Rust) | M6, M8 |
| `freeverb`-style reverb | in-house | audio | Monitoring reverb | M7 |
| `mdns-sd`, `tokio-tungstenite`, `rcgen`, `axum` | Mornye's pins (`link`) | party | LAN party host | M8 |

The vendored `rustix` patch (Android < 30 `statx` SIGSYS fix) is added with the first crate that depends on `rustix`.

### Stem server (`stem-server/`, own workspace, M6.6)
`axum`, `tokio`, `sqlx` (postgres, migrate), `redis`, `argon2`, `tower` (limits), `prometheus`; Python worker: `demucs` (MIT), `torch` (CUDA), `redis`, `soundfile`.

## 5. Explicitly avoided
- Rubber Band (GPL/commercial dual licence; Signalsmith is lighter).
- Google Play services, Firebase, Crashlytics, any analytics SDK.
- Built-in scrapers or provider SDKs (Spotify, Genius, Musixmatch…): content comes from extensions only.
- `flutter_rust_bridge` (Kalao uses UniFFI + MethodChannel like Mornye's app).
