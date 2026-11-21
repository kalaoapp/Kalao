# LRCLIB sample extension

A complete Kalao lyrics extension for [LRCLIB](https://lrclib.net), an open lyrics database with no API key. Copy this folder to start your own extension; [EXTENSIONS.md](../../../android/docs/EXTENSIONS.md) describes the manifest and the `kalao` API.

```sh
cd rust_backend
cargo run --locked -p kalao-ext -- validate ../examples/extensions/lrclib
cargo run --locked -p kalao-ext -- test ../examples/extensions/lrclib      # offline, against fixtures/tests.json
cargo run --locked -p kalao-ext -- pack ../examples/extensions/lrclib -o lrclib.kalaoext
```

Open the `.kalaoext` on the phone (or **Extensions → Install from file**) to install it. Packages are build output; do not commit them.
