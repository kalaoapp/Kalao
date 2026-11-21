# Kalao Extensions: Framework and Authoring Guide

> This document is public. Kalao ships no content scrapers. Every lyrics, metadata or audio source is an extension the user installs. Extensions made by the Kalao maintainer are distributed privately and are not part of this repository.

The framework is Mornye's extension system (its `extensions` crate, adapted): a zip package with a root `manifest.json` and `index.js`, run inside an embedded QuickJS sandbox, with network access granted per extension.

## 1. What an extension can do

An extension declares one or more **capabilities** and implements the matching functions:

| Capability | Function(s) | Returns |
| --- | --- | --- |
| `lyrics` | `searchLyrics(query)`, optional `getLyrics(id)` | Candidates `{id, title, artist, album?, durationMs?, format, body?, language?}`; `format` is `plain`, `lrc`, `elrc` (word-timed) or `ttml`. Leave out `body` to serve it from `getLyrics(id)` |
| `metadata` | `searchTracks(query)`, `getTrack(id)` | Tracks `{id, title, artists (or artist), album?, durationMs?, isrc?, language?, artworkUrl?, year?}` |
| `audio` | `resolveAudio(track)` | `{sources: [{url, kind?, headers?, format?}]}` (a list or a single URL also work): up to three sources, `kind` `original` (default), `instrumental` or `vocals`, `format` a file-extension hint such as `mp3` |
| `artwork` | `getArtwork(track)` | Images `[{url, width?, height?}]` (HTTPS) |

`query` is `{ title, artist, album?, durationMs?, isrc?, language? }`; a free-text search from Home sends the text as `title` and an empty `artist`. `track` is a track a metadata extension returned (`id`, `title`, `artists`, …, plus `extensionId`). Results are capped at 50 items; numbers may be floats. Extensions **never** see the user's library, other extensions' data, Kalao's own keys, or local files.

## 2. Package format

A `.kalaoext` file is a zip archive:

```
my-extension.kalaoext
├── manifest.json      # required, at the root, ≤ 1 MiB
├── index.js           # required, at the root (entry point)
├── icon.png           # optional, 256×256
└── lib/…              # optional additional JS modules (imported relatively)
```

Limits (enforced by the loader): ≤ 2048 entries, ≤ 64 MiB extracted, no absolute paths or `..` segments, no symlinks.

## 3. `manifest.json`

```json
{
  "schema": 1,
  "id": "dev.example.lrcfinder",
  "name": "LRC Finder",
  "version": "1.2.0",
  "minKalao": "1.0.0",
  "author": "Example Dev",
  "description": "Synced lyrics from example.org",
  "homepage": "https://example.org",
  "capabilities": ["lyrics"],
  "languages": ["zh", "ja", "en"],
  "network": {
    "hosts": ["api.example.org", "*.cdn.example.org"]
  },
  "settings": [
    { "key": "token", "type": "secret", "label": "API token", "grantsNetwork": "api.example.org" },
    { "key": "preferSynced", "type": "toggle", "label": "Prefer synced", "default": true },
    { "key": "region", "type": "select", "label": "Region", "options": ["jp", "tw", "cn"] },
    { "key": "login", "type": "button", "label": "Log in to example.org", "action": "startLogin" }
  ],
  "auth": { "callbackPath": "callback" },
  "health": [ { "id": "api", "url": "https://api.example.org/ping", "method": "HEAD" } ]
}
```

- `id` is reverse-DNS, unique and immutable. `version` is semver; the runtime refuses downgrades unless the user confirms.
- `network.hosts` is the **complete** list of hosts `fetch` may reach. A `secret` setting with `grantsNetwork` only enables its host once the user has filled it in.
- Setting types: `text`, `secret` (stored encrypted, redacted in logs), `toggle`, `select`, `number`, `button` (calls the named JS function).
- `auth.callbackPath` registers `kalao://ext/<id>/callback` for OAuth or login redirects.
- `health` entries are probed (GET/HEAD) to show status on the extension's page; an answer below 500 counts as working.

## 4. JavaScript API

Extensions are ES modules. Export the functions for your declared capabilities:

```js
// index.js
export async function searchLyrics(query) {
  const res = await kalao.fetch(`https://api.example.org/search?` +
    kalao.url.params({ q: `${query.artist} ${query.title}` }), {
      headers: { Authorization: `Bearer ${kalao.settings.get("token")}` },
      timeoutMs: 8000,
    });
  if (res.status !== 200) return [];
  const items = res.json();
  return items.map(it => ({
    id: String(it.id),
    title: it.title,
    artist: it.artist,
    durationMs: it.duration * 1000,
    format: it.synced ? "lrc" : "plain",   // "plain" | "lrc" | "elrc"
    body: it.lyrics,
    language: it.lang,                       // optional BCP-47
  }));
}

export async function startLogin() {
  await kalao.auth.openBrowser("https://example.org/oauth?redirect=" +
    encodeURIComponent(kalao.auth.callbackUrl()));
  const { query } = await kalao.auth.waitForCallback({ timeoutMs: 120000 });
  kalao.settings.set("token", query.code);
}
```

Host object `kalao`:

| API | Purpose |
| --- | --- |
| `kalao.fetch(url, {method, headers, body, timeoutMs})` | HTTPS only, to hosts in the allowlist (an object `body` is sent as JSON); returns `{status, ok, url, headers, header(name), text(), json(), bytes()}`. Cookies are kept per extension while the app runs |
| `kalao.settings.get/set(key)` | Manifest-declared settings only, checked against their type. A `secret` you set (a login token) goes to the device's secure storage |
| `kalao.storage.get/set/remove(key)` | Private JSON key-value store (≤ 5 MiB per extension) |
| `kalao.auth.callbackUrl() / openBrowser(url) / waitForCallback({timeoutMs})` | Login flows (needs `auth.callbackPath`; the page must be HTTPS). `waitForCallback` resolves to `{url, query}` |
| `kalao.html.parse(text)` | `select(css)` / `selectFirst(css)` → elements with `text()`, `html()`, `outerHtml()`, `attr(name)`, `attrs()`, `select(css)`, run in Rust |
| `kalao.crypto.*` | `sha1/sha256/md5(data, {encoding})` → hex; `hmac(alg, key, data)` → hex; `aes.gcmEncrypt/gcmDecrypt({key, iv, data, aad?})` (base64, 16- or 32-byte key, 12-byte IV); `base64.encode/decode/toBytes` |
| `kalao.log.debug/info/warn/error`, `console.*` | Shown in the extension's debug log (tokens and secret values redacted) |
| `kalao.url.params(obj)` · `kalao.time.now()` | Utilities |

`index.js` may import other modules of the package with relative paths (`./lib/x.js`); nothing else can be imported. There is **no** filesystem access, child process, `eval` or `Function` constructor, or access to other extensions. The `kalao` object is frozen.

## 5. Sandbox and limits

- Each extension runs in its own QuickJS runtime on a Rust worker thread.
- Limits: 64 MiB heap, 10 s per call (6 s for each extension in a search, 3 minutes for a button action, which may wait for a login), 16 MiB per response, 8 MiB per result. Calls to one extension run one at a time; different extensions run in parallel. A call that runs out of time or memory stops the runtime; the next call starts a fresh one.
- Every fetch is checked against the allowlist before it is sent and after every redirect; HTTPS is required (HTTP only for `localhost` in developer mode), and private network addresses are refused.
- Return values are validated against the capability schema. Invalid results are dropped and logged, and do not crash the app.
- Three failures in a row mark the extension *degraded*: it is skipped in fallback chains for ten minutes, or until a health check passes or it is switched off and on.

## 6. How Kalao uses results

- **Lyrics:** all enabled `lyrics` extensions are queried in parallel. Candidates are scored on match quality (title, artist, duration within ±3 s) and format (`elrc` > `lrc` > `plain`), with the user's priority order as the tie-break. The best candidate is normalised (section markers, brackets, whitespace) and annotated by Kalao, not by the extension.
- **Metadata and artwork** are merged across extensions (the same song by ISRC, else by title and artist); the copy from the extension highest in the user's order is kept and gaps are filled from the others.
- **Audio:** `resolveAudio` URLs are streamed or downloaded by Kalao through the extension's own network session (so the URLs must be on its allowlist); the extension never handles audio bytes. Range requests let playback seek before the download finishes.

## 7. Distribution

- **File:** open a `.kalaoext` to install it. Kalao shows the name, author, capabilities, hosts and a SHA-256 fingerprint, says whether a trusted repository lists exactly this package, and asks for confirmation. The package must load and export its capabilities' functions.
- **Repository:** add a repository URL that serves `index.json`:

```json
{
  "name": "Example Repo",
  "publicKey": "ed25519:BASE64...",
  "extensions": [
    { "id": "dev.example.lrcfinder", "version": "1.2.0",
      "url": "https://example.org/ext/lrcfinder-1.2.0.kalaoext",
      "sha256": "…", "signature": "ed25519:…", "minKalao": "1.0.0" }
  ]
}
```

  Package URLs may be relative to `index.json`. Each package's SHA-256 must match and its signature (ed25519 over the package bytes) must verify against the repository key the user trusted when adding the repo (the key's fingerprint is shown then). A key change blocks installs until the repository is removed and added again. Updates are checked once a day and installed only when the user taps Update. Packages are downloaded up to 16 MiB.

## 8. Developing an extension

1. Copy the public sample `examples/extensions/lrclib/` (an LRCLIB lyrics provider).
2. Turn on **Extensions → Developer mode**, which allows HTTP to `localhost` and **Load from folder**: the folder is packed and installed, and loading it again reloads it.
3. Use `kalao-ext` (`rust_backend/crates/ext-cli`; `cargo run --locked -p kalao-ext -- <command>`):
   - `validate <folder|package>`: checks the manifest and package and loads it, reporting its exports.
   - `test <folder> [--fixtures tests.json]`: runs calls offline against recorded responses (`fixtures/tests.json` by default) and checks the results as Kalao would. The file holds `fixtures` (`{method?, url, status?, headers?, body | bodyJson | bodyBase64}`, matched by method and exact URL; hosts outside the allowlist fail as on a device), optional `settings`, and `calls` (`{name?, function, argument, expect?: {items?, minItems?, first?}}`).
   - `pack <folder> [-o out.kalaoext]`: a reproducible package (hidden files and `fixtures/` left out).
   - `keygen -o secret.key`, `sign <package> --key secret.key`, `index <folder of packages> --key secret.key --name <name>`: the repository's key, signatures and a signed `index.json`.
4. Respect the terms of the sites you access. Extensions are the author's responsibility.
