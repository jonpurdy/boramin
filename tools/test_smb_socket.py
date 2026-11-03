#!/usr/bin/env python3
"""Compile/run the production libsmb2 broken-connection regression on macOS."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
smb = root / 'vendor/AMSMB2/Dependencies/libsmb2'
output = root / 'build/SMBSocketTests'
output.mkdir(parents=True, exist_ok=True)
command = ['xcrun', '--sdk', 'macosx', 'clang', '-g', '-O0',
           '-DHAVE_CONFIG_H=1', '-D_U_=__attribute__((unused))',
           *[f'-I{smb / path}' for path in ['include', 'include/apple', 'include/smb2', 'lib']],
           str(root / 'Tests/SMBSocketTests.c'),
           *map(str, sorted((smb / 'lib').glob('*.c'))),
           '-o', str(output / 'smb-socket-tests')]
with (output / 'build.log').open('w') as log:
    result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit(f'Compilation failed; see {output / "build.log"}')
subprocess.run([str(output / 'smb-socket-tests')], cwd=root, check=True, timeout=20)
