# Libraries

Pin policy (from Mornye): exact versions (`=x.y.z` in Cargo, no caret for packages with migration hazards in pubspec), one version per dependency across the workspace, Renovate PRs for upgrades. **Shared with Mornye** = the version Mornye pins today, already proven together. **New** = Kalao-only; the major version is chosen here and the exact version is pinned in the PR that adds it, after a licence check (must be GPL-3.0-compatible).

## 1. Toolchains

| Tool | Version | Source |
| --- | --- | --- |
| Flutter (via FVM, `.fvmrc`) | 3.47.8 | Mornye |
| Dart SDK constraint | `^3.10.0` | Mornye |
| Rust (`rust-toolchain.toml`) | 1.99.1, profile minimal, rustfmt + clippy; edition 2024, resolver 3 | Mornye |
| Android Gradle Plugin | 9.5.0 | Mornye |
| Kotlin | 2.4.21, `jvmTarget` 25 (JDK 25) | Mornye |
| Android NDK | 30.0.16248370 | Mornye |
| compileSdk / targetSdk / minSdk | 37 / 37 / 26 | Mornye (minSdk raised from Flutter's default for AAudio) |
| cargo-ndk | latest | new |

## 2. Dart / Flutter (`android/pubspec.yaml`)

| Package | Version | Use | Source |
| --- | --- | --- | --- |
| `flutter_localizations`, `intl` | sdk, `^0.20.3` | l10n | Mornye |
| `flutter_riverpod` | `^3.4.2` | State | Mornye |
| `go_router` | `^18.1.2` | Routing | Mornye |
| `shared_preferences` | `^2.5.6` | Settings | Mornye |
| `flutter_secure_storage` | `10.3.4` (exact) | Stem key, install ID, extension secrets | Mornye |
| `path_provider`, `path` | `^2.1.6`, `^1.9.1` | Paths | Mornye |
| `ffi` | `^2.2.0` | Desktop backend later | Mornye |
| `sqflite` (+ `sqflite_common_ffi` for tests now, desktop later) | `^2.4.5` | Library, history, app-state databases | Mornye |
| `http` | `^1.6.0` | Update checker | Mornye |
| `connectivity_plus` | `^7.3.1` | Offline detection (stems remote, translation) | Mornye |
| `crypto` | `^3.0.8` | SHA-256 (cache keys, update checksums) | Mornye |
| `archive` | `^4.5.2` | Backup bundle reading | Mornye |
| `bonsoir` | `^7.1.5` | mDNS discovery of parties | Mornye |
| `cached_network_image`, `flutter_cache_manager` | `^4.0.6`, `^3.4.6` | Artwork | Mornye |
| `material_symbols_icons`, `dynamic_color`, `material_ui`, `material_3_expressive`, `material_color_utilities` | `^4.2960.0`, `^2.1.0`, `^1.9.0`, `^1.2.0`, `0.13.0` | Theme | Mornye |
| `permission_handler` | `^13.0.1` | Mic, camera, notifications | Mornye |
| `file_picker` | `^13.3.0` | Import audio, lyrics, backups | Mornye |
| `json_annotation` / `json_serializable` + `build_runner` | `^4.12.0` / `^6.15.2`, `^2.17.1` | Models | Mornye |
| `url_launcher` | `^6.3.3` | Ko-fi, release page, extension logins | Mornye |
| `device_info_plus` | `^13.3.0` | Update ABI selection, diagnostics | Mornye |
| `share_plus`, `receive_sharing_intent` | `^13.3.1`, `^1.9.0` | Share backups/logs; open shared files | Mornye |
| `logger` | `^2.7.0` | `AppLogger` | Mornye |
| `synchronized` | `^3.5.0` | Locks around DB writes | Mornye |
| `flutter_local_notifications` | `^22.3.3` | Update and job notifications | Mornye |
| `audio_service` | `^0.18.19` (pub.dev) | Media session, notification, headset buttons | Mornye's version; its fork's patches serve Android Auto, browsing and notification custom actions, which Kalao does not use (decided in M1.4), so the published package is used |
| `audio_session` | `^0.2.4` | Focus, interruptions, routes | Mornye |
| `app_links` | `^7.2.2` | `kalao://ext/<id>/callback` | Mornye |
| `ffmpeg_kit_flutter_new_audio` | `2.5.7` (pub.dev, exact) | One-off conversion at import of formats Symphonia cannot decode (Opus, WMA, APE) | Mornye's version; its fork only patches Windows, so the published package is used (M1.6) |
| `mobile_scanner` | latest major | Scan party QR codes | new |
| `qr_flutter` | latest major | Show party QR codes | new |
| `flutter_lints`, `riverpod_lint`, `analyzer` | `^6.0.0`, `^3.1.9`, `^14.6.0` | Lints | Mornye |
| `flutter_launcher_icons` | `^0.14.4` | Icons | Mornye |
| `integration_test`, `flutter_driver`, `clock` | sdk, `1.1.3` | Tests | Mornye |

Not taken from Mornye: `audioplayers` and its forks, `media_kit*`, `liquid_glass_easy`, `dart_smb2`, `smtc_windows`, `dbus`, `video_player`, `record` (mic capture is native, in `kalao-audio`), `mornye_discord`, `desktop_drop` (until desktop), `timezone`, `volume_controller`, `xml`, `html`, `open_filex`.

## 3. Kotlin (`android/app/build.gradle.kts`)

| Artifact | Version | Use | Source |
| --- | --- | --- | --- |
| `net.java.dev.jna:jna` | `5.19.1@aar` | UniFFI bindings loader | Mornye |
| `org.jetbrains.kotlinx:kotlinx-coroutines-android` | 1.11.0 | `Dispatchers.IO` dispatch | Mornye |
| `androidx.lifecycle:lifecycle-runtime-ktx` | 2.11.0 | Lifecycle | Mornye |
| `androidx.documentfile:documentfile` | 1.1.0 | SAF | Mornye |
| `androidx.activity:activity-ktx` | 1.13.0 | Result APIs | Mornye |
| `com.microsoft.onnxruntime:onnxruntime-android` | latest 1.x | Provides `libonnxruntime.so` (with XNNPACK EP) loaded by `ort` | new |

No `play-services-*` artifacts.

## 4. Rust (`rust_backend/Cargo.toml` `[workspace.dependencies]`)

### Shared with Mornye (exact pins as in Mornye)
`serde 1.0` (derive), `serde_json 1.0` (float_roundtrip, raw_value), `thiserror 2.0`, `uniffi =0.32.2`, `tokio =1.54.1` (rt-multi-thread, net, time, sync, io-util, macros), `tokio-util 0.7`, `futures-util 0.3`, `bytes 1.11`, `http 1.4`, `http-body-util 0.1`, `hyper-util =0.1.21`, `hyper-rustls =0.27.10` (ring, tls12), `rustls 0.23` (ring), `rustls-native-certs =0.8.5`, `rustls-pemfile 2.2`, `async-compression 0.4`, `tower-service 0.3`, `hickory-proto =0.26.3`, `cookie 0.18`, `url 2.5`, `regex =1.13.1`, `scraper =0.29.0` + `html5ever =0.40.1` (extension `html.parse`), `rquickjs =0.14.0`, `base64 0.23`, `sha2 0.11`, `sha1 0.11`, `md-5 0.11`, `hmac 0.13`, `aes-gcm =0.11.1`, `aes =0.9.3`, `zeroize 1.8`, `getrandom 0.4`, `tempfile 3.27`, `zip =9.1.3` (deflate-flate2-zlib-rs), `unicode-normalization =0.1.22`, `unicode-general-category =0.6.0`, `time =0.3.55`, `chrono =0.4.45`, `httpdate =1.0.3`, `cap-std =4.0.3`, `rustix =1.1.6` (patched), `roxmltree =0.21.2` (TTML), `rusqlite =0.41.1` (bundled, modern_sqlite, hooks), `libc =0.2.191`, `image =0.25.10` (cover thumbnails). For `kalao-party` (from Mornye `link`): Mornye's pinned `mdns-sd`, `tokio-tungstenite`, `rcgen` (self-signed TLS), `axum`/`hyper` server stack as used by `link`.

### New in Kalao
| Crate | Major | Crate user | Use |
| --- | --- | --- | --- |
| `symphonia` | 0.5.5 (features mp3, aac, isomp4, alac, flac, vorbis, ogg, wav, pcm) | audio, stems | Decode MP3, AAC/M4A, ALAC, FLAC, Vorbis, WAV; also reads tags and covers for `probeAudio` |
| `cpal` | 0.16 | audio | AAudio output and low-latency input on Android; WASAPI/CoreAudio/ALSA on desktop later |
| `rubato` | 0.16 | audio, stems | Resampling to the device rate / model rate |
| `signalsmith-stretch` (Rust bindings to Signalsmith Stretch, MIT) | =0.1.3 | audio | Key change and tempo without pitch change (ADR-005). Compiles C++ (`cc`) and generates bindings (`bindgen`), so builds need a C++ compiler and libclang; Android links libc++ and libc++abi statically |
| `ringbuf` | 0.4 | audio | Lock-free decoder → callback buffers |
| `flacenc` | latest | stems, audio | Encode stems and recordings to FLAC (pure Rust; decoded back by Symphonia) |
| `ort` | 2.x (`load-dynamic`) | stems | ONNX Runtime; XNNPACK execution provider, CPU fallback (QNN optional) |
| `ndarray` | 0.16 | stems | Tensors for inference |
| `realfft` | 3.x | stems, audio | STFT/iSTFT (models that need spectrograms), pitch analysis |
| `pinyin_pro` | =3.29.4 (MIT) | core::annotate, search keys | Rust port of `pinyin-pro`, the library the POC used: segmentation, polyphones in context, tone marks; the POC's fixtures pass unchanged. Replaces the planned `pinyin` + `jieba-rs` (M1.12) |
| `ferrous-opencc` with OpenCC data (Apache-2.0) | =0.4.0 | core::annotate | Traditional ↔ Simplified (`s2t`, `s2tw`, `s2hk`, `t2s`); dictionaries embedded (about 2 MB) |
| `lindera` with IPADIC (MIT; IPADIC under its own permissive licence) | =6.2.0, `embed-ipadic` | core::annotate | Japanese morphology → kana readings for furigana. The dictionary is downloaded at build time and embedded (about 50 MB per ABI) |
| `wana_kana` | 4.x | core::search_keys (M1), core::annotate (M3.6) | Kana → romaji |
| `ed25519-dalek` | 2.x | extensions | Repository signature verification (if Mornye's repository module lacks it) |
| `freeverb`-style reverb (in-house, ~150 lines) | — | audio | Monitoring reverb; no dependency |
| `clap` | 4.x | ext-cli | `kalao-ext` CLI |

### Stem server (`stem-server/`, own workspace)
`axum`, `tokio`, `sqlx` (postgres, migrate), `redis`, `argon2`, `tower` (limits), `prometheus`; Python worker: `demucs` (MIT), `torch` (CUDA), `redis`, `soundfile`.

## 5. Explicitly avoided
- Rubber Band (GPL/commercial dual licence; Signalsmith is lighter).
- Google Play services, Firebase, Crashlytics, any analytics SDK.
- Built-in scrapers or provider SDKs (Spotify, Genius, Musixmatch…): content comes from extensions only.
- `flutter_rust_bridge` (Mornye pins it only as an override for a transitive dependency; Kalao uses UniFFI + MethodChannel like Mornye's app).
