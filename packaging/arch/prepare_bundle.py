"""Check a trusted, locally built bundle; normalize only its staging copy."""
import pathlib
import subprocess
import sys

bundle = pathlib.Path(sys.argv[1]).resolve(strict=True)
for relative in ('fqapp', 'lib/libfqapi_core.so', 'lib/libflutter_linux_gtk.so',
                 'lib/libapp.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin'):
    if not (bundle / relative).is_file():
        raise SystemExit(f'Missing bundle member: {relative}')
for path in bundle.rglob('*'):
    if path.is_symlink():
        raise SystemExit(f'Bundle symlink requires review: {path}')
    if not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    if b'/home/' in path.read_bytes():
        print(f'DIAGNOSTIC PATH LIMITATION: {path.relative_to(bundle)} contains /home/ strings')
    header = subprocess.check_output(['readelf', '-h', path], text=True)
    if 'Advanced Micro Devices X86-64' not in header:
        raise SystemExit(f'Not an x86_64 ELF: {path}')
    rpath = '$ORIGIN/lib' if path == bundle / 'fqapp' else '$ORIGIN'
    if path.name == 'libdartjni.so':
        raise SystemExit('Unexpected Java plugin: build in an environment without a JDK')
    subprocess.run(['patchelf', '--set-rpath', rpath, path], check=True)
    dynamic = subprocess.check_output(['readelf', '-d', path], text=True)
    assert '/tmp/' not in dynamic and '/home/' not in dynamic, dynamic
    print(path.relative_to(bundle))
    print('\n'.join(line for line in dynamic.splitlines() if 'NEEDED' in line or 'RUNPATH' in line))
    closure = subprocess.check_output(['ldd', path], text=True)
    print(closure)
    if 'not found' in closure:
        raise SystemExit(f'Unresolved ELF closure: {path}')
