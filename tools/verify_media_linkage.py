#!/usr/bin/env python3
"""Check that engine and legacy FFmpeg cannot silently share the app's symbols."""
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
mac = (app / 'Contents').is_dir()
contents = app / 'Contents' if mac else app
with (contents / 'Info.plist').open('rb') as stream:
    name = plistlib.load(stream)['CFBundleExecutable']
binary = contents / 'MacOS' / name if mac else contents / name
legacy = contents / 'Frameworks/BoraMinMedia.framework/BoraMinMedia'
def run(*args):
    return subprocess.check_output(args, text=True)
# Xcode's Debug launcher loads the application code from a separate dylib.
debug_binary = binary.with_name(f'{name}.debug.dylib')
if debug_binary.exists() and debug_binary.name in run('otool', '-L', str(binary)):
    binary = debug_binary
exports = run('nm', '-gU', str(legacy))
for line in exports.splitlines():
    symbol = line.split()[-1]
    if not symbol.startswith('_media_'):
        raise SystemExit(f'Unexpected legacy framework export: {symbol}')
bindings = run('nm', '-m', str(binary))
for symbol, library in [('_avcodec_version', 'AetherLibavcodec'),
                        ('_avformat_version', 'AetherLibavformat'),
                        ('_media_open_io', 'BoraMinMedia')]:
    matching = [line for line in bindings.splitlines() if f' {symbol} ' in line]
    if not matching or not all('(undefined)' in line and f'(from {library})' in line for line in matching):
        raise SystemExit(f'Wrong binding for {symbol}: {matching}')
loads = run('otool', '-L', str(legacy))
if '@rpath/BoraMinMedia.framework/' not in loads or 'AetherLib' in loads:
    raise SystemExit('Legacy framework has unexpected install name or engine dependency')
print('PASS: private legacy symbols and separate engine FFmpeg bindings:', app.name)
