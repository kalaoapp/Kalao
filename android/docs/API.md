# APIs

Kalao has no account server. The app makes network calls only to the services below. Each one is optional, and the app works offline without them.

| Service | Called by | When |
| --- | --- | --- |
| Third-party sites | `kalao-extensions` host fetch | Only to hosts an installed extension declares (EXTENSIONS.md) |
| MyMemory `api.mymemory.translated.net/get` | `kalao-providers` | Lyric translation (IMPLEMENTATION.md §11) |
| Kalao stem server (below) | `kalao-stems` | Remote stem processing, if the user entered a stem API key |
| GitHub Releases `api.github.com/repos/kalaoapp/Kalao/releases/latest` and its APK assets | `update_checker.dart` / `apk_downloader.dart` | Update check (9.8), at most once a day if enabled; APK download only when the user taps Update |
| Model host (GitHub Releases assets) | `kalao-stems` | Stem model download when the user installs a model |

No request carries a user identifier. The only device-related value sent anywhere is the salted install hash, and only to the stem server. The optional MyMemory contact email is sent only to MyMemory.

## Stem server: `https://<stem-host>/v1`

JSON over HTTPS. Errors use the shape `{ "error": { "code", "message" } }`. Requests carry `Authorization: Bearer <stem API key>` and `X-Kalao-Device: <salted install hash>`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/key` | Validate the key; binds it to the device on first call. 401 unknown/revoked, 409 bound to another device |
| POST | `/jobs` | Multipart audio upload (≤ 100 MB, ≤ 15 min) → `{ jobId }`. 429 if over limits |
| GET | `/jobs/{id}` | `{ status, progress, error? }` (also as SSE with `Accept: text/event-stream`) |
| GET | `/jobs/{id}/stems/{vocals\|instrumental}` | Download the result (FLAC, 44.1 kHz stereo); deleted after both are fetched or after 24 h |
| DELETE | `/jobs/{id}` | Cancel and delete |
| GET | `/metrics` | Prometheus format; requires the operator's admin token (not used by the app) |
