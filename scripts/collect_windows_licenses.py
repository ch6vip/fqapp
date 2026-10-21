"""Copy dependency licenses into the portable bundle without copying caches/data."""
import json
import pathlib
import re
import shutil
import urllib.parse
import urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
bundle = root / 'build/windows/x64/runner/Release'
destination = bundle / 'licenses'
destination.mkdir(exist_ok=True)
config_file = root / '.dart_tool/package_config.json'
packages = json.loads(config_file.read_text(encoding='utf8'))['packages']
for package in packages:
    uri = urllib.parse.urlsplit(package['rootUri'])
    package_root = (pathlib.Path(urllib.request.url2pathname(uri.path)) if uri.scheme == 'file'
                    else (config_file.parent / urllib.parse.unquote(package['rootUri'])).resolve())
    if not package_root.is_dir():
        continue
    if package['name'] == 'flutter':
        sdk_license = package_root.parents[1] / 'LICENSE'
        if sdk_license.is_file():
            shutil.copy2(sdk_license, destination / 'Flutter-LICENSE.txt')
    for file in package_root.iterdir():
        if file.is_file() and re.match(r'^(LICENSE|COPYING|COPYRIGHT)([._-].*)?$', file.name, re.I):
            shutil.copy2(file, destination / f"{package['name']}-{file.name}.txt")
for source, name in [(root / 'LICENSE', 'fqapp-GPL-3.0.txt'),
                     (root / 'build/windows/x64/packages/Microsoft.Web.WebView2/LICENSE.txt', 'WebView2-LICENSE.txt')]:
    if source.is_file():
        shutil.copy2(source, destination / name)
header = root / 'build/windows/x64/libmpv/include/client.h'
if header.is_file():
    notice = header.read_text(encoding='utf8').split('*/', 1)[0] + '*/\n'
    (destination / 'libmpv-notice.txt').write_text(notice, encoding='utf8')
print(f'Collected {len(list(destination.iterdir()))} license files')
