#!/usr/bin/env python3
"""Build/run an isolated Mac probe using production Xcode sources and dependencies."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('probe', choices=['software', 'ass', 'external', 'native', 'hardware', 'codecs', 'connections', 'failure', 'browsing', 'cancellation', 'deletion', 'http'])
parser.add_argument('fixtures', nargs='+', help='Fixture paths/arguments passed to the probe')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
folder = root / 'build/AetherSoftwareTests'
folder.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(root/'tools/test_aether_software.py'), '--probe', args.probe], cwd=root, check=True)
log = folder / f'{args.probe}-build.log'
command = ['xcodebuild', '-project', str(folder/'Probe.xcodeproj'), '-scheme', 'BoraMin macOS',
           '-configuration', 'Release', '-destination', 'platform=macOS,arch=arm64',
           '-clonedSourcePackagesDirPath', str(root/'build/AetherPackages'),
           '-derivedDataPath', str(folder/'Derived'), 'build']
print(f'Building {args.probe} probe; log: {log}', flush=True)
with log.open('w') as output:
    result = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
if result.returncode:
    print('\n'.join(log.read_text().splitlines()[-70:]), file=sys.stderr)
    sys.exit(result.returncode)
app = folder/'Derived/Build/Products/Release/BoraMin.app'
subprocess.run([sys.executable, str(root/'tools/verify_media_linkage.py'), str(app)], cwd=root, check=True)
# The generated project/product is shared by modes; run sequentially, not concurrently.
subprocess.run([str(app/'Contents/MacOS/BoraMin'), *args.fixtures], cwd=root, check=True, timeout=240)
