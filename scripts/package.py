#!/usr/bin/env python3
"""Package file contents only: no extended attributes or AppleDouble sidecars."""
from pathlib import Path
import plistlib
import re
import struct
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit('Usage: package.py PATH_TO_FRESH_APP_BUNDLE')
app = Path(sys.argv[1])
bundle_name = 'Codex SubRouter.app'
expected_files = {
    Path('Contents/Info.plist'),
    Path('Contents/MacOS/CodexSubRouter'),
    Path('Contents/Resources/AppIcon.icns'),
    Path('Contents/_CodeSignature/CodeResources'),
}
members = list(app.rglob('*'))
if app.is_symlink() or any(p.is_symlink() for p in members):
    raise SystemExit('Refusing to package symlinks')
actual_files = {p.relative_to(app) for p in members if not p.is_dir()}
if actual_files != expected_files or any(not (app / p).is_file() for p in expected_files):
    raise SystemExit('App bundle does not match the release file list')

info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version):
    raise SystemExit('Invalid release version')
binary = app / 'Contents/MacOS/CodexSubRouter'
with binary.open('rb') as handle:
    magic, cpu = struct.unpack('<II', handle.read(8))
if magic != 0xFEEDFACF or cpu not in (0x0100000C, 0x01000007):
    raise SystemExit('Unsupported executable architecture')
arch = 'arm64' if cpu == 0x0100000C else 'x86_64'
archive = root / 'dist' / f'CodexSubRouter-{version}-{arch}.zip'
archive.parent.mkdir(parents=True, exist_ok=True)
files = [(app / p, Path(bundle_name) / p) for p in sorted(expected_files)]
files += [(root / name, Path(name)) for name in ('README.md', 'LICENSE', 'SECURITY.md')]
with tempfile.TemporaryDirectory(prefix='.release-', dir=archive.parent) as staging:
    candidate = Path(staging) / archive.name
    with zipfile.ZipFile(candidate, 'w', zipfile.ZIP_DEFLATED) as output:
        for source, relative in files:
            if source.is_symlink():
                raise SystemExit('Refusing to package a symlink')
            output.write(source, relative.as_posix())
    with zipfile.ZipFile(candidate) as output:
        if output.testzip() is not None:
            raise SystemExit('Archive verification failed')
    candidate.replace(archive)
print(archive.name)
