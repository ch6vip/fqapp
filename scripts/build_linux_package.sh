#!/usr/bin/env bash
# Build and package one clean Git revision; never accept a prebuilt bundle.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 NEW_OUTPUT_DIR HEAD_REVISION" >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
revision=$(git -C "$root" rev-parse --verify --end-of-options "$2^{commit}")
[[ $revision == "$(git -C "$root" rev-parse HEAD)" ]]
python "$root/packaging/arch/check_source.py" "$root"
requested=$1
while [[ $requested == */ && $requested != / ]]; do requested=${requested%/}; done
[[ ! -e $requested && ! -L $requested ]] || { echo 'Output already exists' >&2; exit 2; }
output=$(realpath -m -- "$requested")
case "$output/" in "$root/"*|/) echo 'Output must be outside checkout' >&2; exit 2;; esac
[[ ! -e $output && ! -L $output ]]
: "${FLUTTER_ROOT:?Set FLUTTER_ROOT to official Flutter 3.47.9}"
: "${PUB_CACHE:?Set PUB_CACHE to prepared locked dependencies}"
for tool in makepkg patchelf python tar zstd readelf ldd desktop-file-validate; do command -v "$tool" >/dev/null; done
# Atomic reservation refuses existing output, including broken symlinks.
mkdir -m755 -- "$output"
export HOME="$output/home" XDG_CONFIG_HOME="$output/home/config" XDG_DATA_HOME="$output/home/data" XDG_CACHE_HOME="$output/home/cache"
export GNUPGHOME="$output/home/gnupg" DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
mkdir -p -m700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$GNUPGHOME"
export SOURCE_DATE_EPOCH=$(git -C "$root" show -s --format=%ct "$revision")
# Do not allow archive symlinks to redirect build tools outside the export.
git -C "$root" ls-tree -r "$revision" | python -c 'import sys; assert not any(s.startswith(("120000", "160000")) for s in sys.stdin), "Source links/submodules require review"'
git -C "$root" archive --format=tar --prefix=fqapp/ "$revision" | zstd -q -o "$output/fqapp-source.tar.zst"
mkdir "$output/source"
tar --zstd -xf "$output/fqapp-source.tar.zst" -C "$output/source"
source_root="$output/source/fqapp"
export PATH="$FLUTTER_ROOT/bin:$PATH"
python - "$FLUTTER_ROOT" <<'PY'
import json, pathlib, sys
assert json.loads((pathlib.Path(sys.argv[1])/'bin/cache/flutter.version.json').read_text())['frameworkRevision'] == 'c197ca5199e9ee5661e865596c9c07294dfab51c'
PY
[[ $(rustc --version) == 'rustc 1.99.1 '* ]]
(cd "$source_root" && flutter pub get --offline --enforce-lockfile)
# SDK-generated analysis exclusion is not a product build input. Locks must stay exact.
for lock in pubspec.lock rust/Cargo.lock; do cmp "$source_root/$lock" "$root/$lock"; done
(cd "$source_root" && FQAPP_SOURCE_REVISION="$revision" bash packaging/arch/build_release.sh)
bundle="$source_root/build/linux/x64/release/bundle"
[[ $(cat "$bundle/source-commit.txt") == "$revision" ]]
python "$source_root/packaging/arch/prepare_bundle.py" "$bundle" > "$output/elf-report.txt"
desktop-file-validate "$source_root/packaging/arch/com.fqapp.fqapp.desktop"
mkdir "$bundle/licenses"
cp "$source_root/LICENSE" "$bundle/licenses/"
cp -r "$source_root/assets/fonts/"*OFL* "$source_root/assets/licenses" "$bundle/licenses/"
cp "$FLUTTER_ROOT/bin/cache/artifacts/engine/linux-x64/"LICENSE* "$bundle/licenses/"
{
 echo "source_commit=$revision"
 echo "source_tree=$(git -C "$root" rev-parse "$revision^{tree}")"
 echo 'entrypoint=lib/main.dart; status=experimental; not a formal release'
 cat "$FLUTTER_ROOT/bin/cache/flutter.version.json"
 rustc --version
 pacman -Q
} > "$output/build-manifest.txt"
cp "$output/build-manifest.txt" "$bundle/"
mkdir -p "$output/payload/fqapp/build/linux/x64/release"
cp -a "$bundle" "$output/payload/fqapp/build/linux/x64/release/"
cp -r "$source_root/packaging" "$output/payload/fqapp/"
cp "$source_root/LICENSE" "$source_root/LINUX.md" "$output/payload/fqapp/"
tar --zstd -cf "$output/fqapp-bundle.tar.zst" -C "$output/payload" fqapp
python - "$source_root" "$output" "$revision" <<'PY'
import hashlib, pathlib, re, sys
root, out = map(pathlib.Path, sys.argv[1:3])
recipe = (root/'packaging/arch/PKGBUILD').read_text().replace('@REVISION@', sys.argv[3])
version = re.search(r'^version: ([^+\s]+)', (root/'pubspec.yaml').read_text(), re.M)[1]
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', version)
recipe = re.sub(r'^pkgver=.*', 'pkgver='+version, recipe, flags=re.M)
def digest(name):
 with (out/name).open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
(out/'source-PKGBUILD').write_text(recipe.replace('0'*64, digest('fqapp-source.tar.zst')))
recipe = recipe[:recipe.index('\nbuild() {')] + recipe[recipe.index('\npackage() {'):]
recipe = re.sub(r'makedepends=\([\s\S]*?\)\n', '', recipe)
recipe = recipe.replace('fqapp-source.tar.zst','fqapp-bundle.tar.zst').replace('0'*64,digest('fqapp-bundle.tar.zst'))
(out/'PKGBUILD').write_text(recipe)
notices = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and any(s in p.name.lower() for s in ('license','notice','copying','ofl')) and 'build' not in p.parts and '.dart_tool' not in p.parts]
(out/'license-inventory.txt').write_text('Available notices, not a completed rights audit:\n'+'\n'.join(sorted(notices))+'\n')
PY
(cd "$output" && makepkg --nodeps --noconfirm && makepkg --printsrcinfo > .SRCINFO)
(cd "$output" && makepkg -p source-PKGBUILD --verifysource --nodeps --noconfirm --force)
(cd "$output" && sha256sum fqapp-source.tar.zst fqapp-bundle.tar.zst *.pkg.tar.zst build-manifest.txt > SHA256SUMS)
printf 'Experimental package and evidence: %s\n' "$output"
