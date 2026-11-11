# novel-sound on Linux / Arch x86_64 (experimental)

The package is still named `fqapp`. Binary, application ID, data paths and
keyring identity remain fqapp/com.fqapp.fqapp for compatibility. This is an
experimental upstream package, not a formal release. Linux video remains gated;
accounts/WebKit/Java are outside this work.

## Build one revision

Use an Arch x86_64 environment, official Flutter 3.47.9
(framework c197ca5199e9ee5661e865596c9c07294dfab51c), Rust 1.99.1,
base-devel, clang, cmake, ninja, pkgconf, gtk3, libsecret, mpv, libspeechd,
python, patchelf, desktop-file-utils, zstd and git. See
[dependency contract](packaging/arch/DEPENDENCIES.md) for runtime consumers.
Prepare locked dependencies once, then build offline:

```bash
export FLUTTER_ROOT=/path/to/flutter
export PUB_CACHE=/path/to/private/pub-cache
export CARGO_HOME=/path/to/private/cargo
export PATH="$FLUTTER_ROOT/bin:$PATH"
flutter precache --linux
flutter pub get --enforce-lockfile
cargo fetch --manifest-path rust/Cargo.toml --locked
# Commit source changes first; do not restore unrelated changes to pass this gate.
bash scripts/build_linux_package.sh '/var/tmp/novel sound candidate' HEAD
```

The new output directory must be outside the checkout and must not exist.
Tracked modifications and untracked/ignored build inputs are rejected.
The script exports HEAD with git archive into a new directory, builds explicitly
`lib/main.dart`, checks all bundle ELF dependencies and retains the whole layout.
It never accepts a prebuilt bundle or a caller-supplied provenance marker.
The source archive, source-PKGBUILD, package recipe, bundle, package,
SHA256SUMS, ELF report and build-manifest bind the artifacts to that revision.
Checksums identify artifacts, not a trusted signature. Dependencies come from
prepared locked caches; this is repeatable construction, not a claim of
bit-for-bit reproducibility across hosts. The manifest records installed Arch
packages and exact SDK; CI uses a dated Arch snapshot and pinned image/actions.

`makepkg --nodeps` only packages a prepared payload, without host installation.
It does not establish clean-machine dependency satisfaction. To rebuild the
source archive, copy source-PKGBUILD to PKGBUILD beside fqapp-source.tar.zst in a
new directory and run `makepkg` with the same toolchain and prepared caches.

## Install, upgrade, remove

In an Arch test environment with working signed repositories:

```bash
sudo pacman -U /absolute/path/fqapp-1.0.201-1-x86_64.pkg.tar.zst
fqapp
# Upgrade with the newly generated package (same command).
sudo pacman -U /absolute/path/new/fqapp-1.0.201-1-x86_64.pkg.tar.zst
sudo pacman -R fqapp
```

Never run fqapp with sudo. Start your own graphical/D-Bus session with an
unlocked Secret Service provider. Install/configure Speech Dispatcher and voices
if using system speech. Installation does not start services or alter profiles.
Uninstall removes packaged files only, preserving Documents/Hive, application
support, caches, imported books and keyring entries.

Before upgrade or downgrade, close the app and preserve **both** data and the
matching keyring securely. Retain the previous package and source/manifest.
`pacman -U /path/to/previous.pkg.tar.zst` rolls back binaries, not schemas or
keys. Do not assume older binaries can read newer data; use a separate synthetic
profile first, and restore a matching backup only through the documented app
recovery path. Never delete data/keyring to bypass startup errors.

CI uploads one experimental artifact and never publishes a Release. Local
packaging tests, an isolated installation/Xvfb startup, CI execution and physical
Wayland/X11/audio/keyring/schema acceptance are separate evidence. Real hardware,
upgrade/downgrade schemas and licensing remain release gates; see DEVELOPMENT.md.
