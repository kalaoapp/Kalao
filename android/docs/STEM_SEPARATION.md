# Stem Separation

Splits a song into **vocals** and **instrumental**. OG Karaoke mode uses the instrumental, the vocal-guide blend uses both, and scoring uses the vocal stem to extract a reference melody.

## 1. On-device (default, always available)

- **Engine:** `kalao-stems` running ONNX Runtime (`ort`), with the XNNPACK execution provider and a CPU fallback. QNN is an optional extra for Snapdragon devices. NNAPI is not used: Android deprecated it in Android 15.
- **Models:** installed and deleted by the user in the app (§1.2), downloaded from Kalao's GitHub Releases assets, with SHA-256 checked against a catalogue built into the app. Models are not bundled in the APK: each one adds 40–160 MB. The catalogue offers three profiles (candidates in §1.1):
  - *Fast*: Spleeter 2stems (16 kHz variant), for low-end phones.
  - *Balanced*: SCNet, or an MDX-Net vocal model if its weights have a clear licence.
  - *Quality*: Hybrid Transformer Demucs (`htdemucs`, single model, MIT licence) exported to ONNX.
  Models ship as fp16 where supported, fp32 otherwise. int8 quantisation is avoided because it tends to degrade separation quality audibly.
  The final model choice is confirmed at M6 after benchmarking on reference devices (target: at most 1× song length for *Quality* on a mid-range phone, at most 0.3× for *Fast*). Model licences must allow redistribution.
- **Pipeline:**
  1. Decode to 44.1 kHz stereo.
  2. Split into 10 s chunks with 1 s overlap.
  3. Run inference per chunk.
  4. Overlap-add.
  5. Instrumental = mix − vocals (the residual), or the model's own output.
  6. Write the stems as FLAC (44.1 kHz stereo, `flacenc`) to `stems/<sha256>/`. FLAC is lossless and decodes with Symphonia, so no extra codec library is needed; a 4-minute song uses about 25–30 MB per stem.
- **Job handling:** runs in Mornye's `BackgroundWorkService` (kind `stems`), an Android foreground service with a progress notification and a cancel action. A checkpoint after every chunk means the job resumes after process death or a reboot. Only one job runs at a time; the others are queued. It pauses on low battery or thermal throttling (both user-overridable).
- **Cache:** stems are keyed by the audio file's SHA-256, so the same song is never separated twice. They are pinned with downloads and LRU-evicted otherwise.

### 1.1 Model candidates

Sizes, scores and speeds are from published results, not yet measured on Kalao's reference devices; the M6 benchmark replaces them. SDR is vocal SDR on MUSDB18-HQ. Every licence must be verified (code and weights) before a model is added to the release assets.

| Model | Size (fp32) | Vocal SDR | Phone fit | Licence |
| --- | --- | --- | --- | --- |
| HTDemucs v4 (`htdemucs`, single model) | ~80 MB | ~9 dB | Heavy: roughly 1× song length or more on a mid-range CPU | MIT (code and weights) |
| MDX-Net / TFC-TDF (UVR `Kim_Vocal_2`, `UVR-MDX-NET-Inst_HQ_3`, `Voc_FT`) | ~50–65 MB | ~9–10+ dB | Native ONNX, but not much lighter than Demucs | Architecture MIT (kuielab); community weights have no clear licence |
| SCNet | ~40 MB (~10M params) | ~9–10 dB | About half the CPU time of HTDemucs, per the paper | To be checked (repository and weights) |
| HDemucs v3 (`hdemucs_mmi`) | ~160 MB | ~8 dB | No transformer, so a simpler ONNX export; cost similar to v4 | MIT |
| Spleeter 2stems | ~40 MB | ~6.5–7 dB | Very fast, well under 0.3× | MIT |
| Open-Unmix (`umxhq`) | ~35 MB per target | ~6.3 dB | Fast | MIT; `umxl` is CC BY-NC-SA and cannot be used |

- **Quality:** `htdemucs` has a clean licence and matches the remote worker. Its STFT/iSTFT runs in Rust, outside the ONNX graph. `htdemucs_ft` is not used: it costs 4× for about 0.2 dB.
- **Balanced:** SCNet is preferred. The UVR `KARA` MDX-Net variants keep backing vocals in the instrumental, which suits karaoke, but can only ship if their weights' licence is settled.
- **Fast:** Spleeter 2stems is the only candidate likely to meet the 0.3× target on low-end phones. It leaves audible artefacts, and the stock model cuts off at 11 kHz, so the 16 kHz variant is used. A full-size MDX-Net model costs about as much as Demucs and will not meet this target.
- **Not on-device:** BS-RoFormer, Mel-Band RoFormer and MDX23C score 11–13 dB but are hundreds of MB and far slower. They are candidates for the stem server only (§2).

### 1.2 Model management

The user chooses which models are on the device. Nothing is downloaded without an explicit action.

- **Catalogue:** built into the app. Each entry has an id, name, profile, download size, licence, asset URL and SHA-256. Adding or replacing a model needs an app release.
- **Screen:** Settings → Stem separation → Models lists every catalogue entry with its profile, size, licence and state (not installed, downloading, installed), and the total storage used by models.
- **Install:** downloads the asset with progress and a cancel action, resumes a partial download, verifies the SHA-256, then moves the file into `models/`. A failed check deletes the file and reports the error.
- **Delete:** removes the model file. Stems already made with it are kept. A model in use by a running job cannot be deleted until the job ends or is cancelled.
- **Default model:** the user picks one installed model as the default; "Separate" on a song uses it, with a per-song override among installed models. Deleting the default clears the setting.
- **No model installed:** "Separate" opens the Models screen instead of starting a job. Queued jobs whose model was deleted fail with a "model not installed" error and can be retried with another model.

## 2. Remote processing (optional)

Kalao runs a separate stem server (`stem-server/`) with GPU workers. Access uses **personal API keys**. The maintainer gives a key to people who donate, but **the app has no notion of donations**: it just has an optional "Remote stem server API key" field.

### App behaviour
- Settings → Stem separation: `Processing: On-device | Remote (API key)`, a key field, and a "Test key" button.
- On first use, the key is bound to this install. The app generates a random install ID (stored in secure storage) and sends only a salted hash of it.
- Remote job flow: upload the audio (encrypted in transit) → poll or stream progress → download the stems → verify checksums → store them like on-device stems.
- On any failure (network, 401/403 key rejected, 409 bound to another device, 429 rate-limited, server busy), Kalao shows a short notice and falls back to on-device separation. It never blocks the user.

### Stem server
- **Gateway (Rust/axum):** accepts only whitelisted keys (stored as an argon2 hash plus a key prefix for lookup). It binds each key to the first device hash that uses it (**1 device per key**), with an admin-only reset. It also handles per-key rate limits and a concurrent-job cap, upload size and duration limits, and job submit/status/result endpoints.
- **Worker (Python, Docker, GPU):** runs Demucs at the highest quality; BS-RoFormer and Mel-Band RoFormer are candidates for a later upgrade if their licences allow. It pulls jobs from Redis and writes results to temporary storage.
- **Retention:** uploaded audio and results are deleted after download, or after 24 h at most. No audio is kept, and logs contain only job metadata.
- **Key admin:** `stem-admin issue --note "<donor ref>"` prints a key once; `stem-admin revoke|reset-device|list`. The note field must not hold personal data beyond what the maintainer needs.
- **Metrics** (queue depth, GPU temperature, jobs per key) are exposed in Prometheus format on `/metrics`, behind the operator's admin token. There is no in-app admin view.
